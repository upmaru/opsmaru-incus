if Code.ensure_loaded?(Plug.Conn) do
  defmodule Opsmaru.Incus.Gateway.Local do
    @moduledoc false
    alias Opsmaru.Incus.Gateway.{Failure, Headers, HTTPRelay, Identity, Lease, Policy}

    def serve(conn, gateway, request, admitted) do
      lease = Lease.start(gateway, request, admitted, HTTPRelay.interrupter(conn))

      try do
        dispatch(conn, gateway, request, admitted, lease)
      after
        Lease.stop(lease)
      end
    end

    def local?(request) do
      (request.method == "GET" and request.path == "/") or certificates?(request.path)
    end

    def certificates?(path) do
      decoded = URI.decode(path)
      decoded == "/1.0/certificates" or String.starts_with?(decoded, "/1.0/certificates/")
    end

    defp dispatch(conn, gateway, request, admitted, lease) do
      with {:ok, _, framing} <-
             Headers.request(
               conn.req_headers,
               gateway.max_header_bytes,
               min(gateway.max_identity_bytes, gateway.max_request_bytes),
               unsized_body?(conn)
             ),
           :ok <- live(lease) do
        if certificates?(request.path) do
          certificates(conn, gateway, request, admitted, framing, lease)
        else
          discovery(conn, gateway, request, framing, lease)
        end
      else
        {:error, failure} -> HTTPRelay.fail(conn, failure)
      end
    end

    defp discovery(conn, gateway, request, :none, lease) do
      with {:ok, identity} <- Identity.load(gateway, request),
           :ok <- live(lease) do
        respond(conn, gateway, Identity.discovery(request.path, identity), [], lease)
      else
        {:error, failure} -> HTTPRelay.fail(conn, failure)
      end
    end

    defp discovery(conn, _, _, _, _),
      do: HTTPRelay.fail(conn, Failure.new(400, "Discovery does not accept a body", :not_sent))

    defp certificates(conn, gateway, request, admitted, framing, lease) do
      with {:ok, action, fingerprint} <- action(request),
           {:ok, body, conn} <- read(conn, gateway, framing, lease),
           :ok <- claims(body),
           {:ok, if_match} <- precondition(conn),
           :ok <- live(lease) do
        input = %{fingerprint: fingerprint, body: body, if_match: if_match}
        outcome = if action in [:create, :update, :delete], do: :uncertain, else: :not_sent

        result =
          Policy.callback(
            fn ->
              result =
                gateway.host.certificates(
                  action,
                  request,
                  admitted.grant,
                  input,
                  gateway.host_config
                )

              prepare_certificate(gateway, result)
            end,
            gateway.callback_timeout
          )

        case {result, live(lease)} do
          {_, {:error, failure}} ->
            HTTPRelay.fail(conn, %{failure | outcome: outcome})

          {{:ok, {:ok, body, headers}}, :ok} ->
            send_json(conn, body, headers, lease, outcome)

          {{:ok, {:invalid, status}}, :ok} ->
            HTTPRelay.fail(
              conn,
              Failure.new(status, "Invalid certificate policy response", outcome)
            )

          {{:ok, {:error, status}}, :ok} ->
            HTTPRelay.fail(
              conn,
              Failure.new(status, "Certificate policy denied the request", :not_sent)
            )

          _ ->
            HTTPRelay.fail(conn, Failure.new(403, "Certificate policy did not complete", outcome))
        end
      else
        {:error, %Failure{} = failure} -> HTTPRelay.fail(conn, failure)
      end
    end

    defp unsized_body?(%Plug.Conn{adapter: {Plug.Cowboy.Conn, req}}),
      do: :cowboy_req.has_body(req) and :cowboy_req.body_length(req) == :undefined

    defp unsized_body?(_), do: false

    defp action(%{method: method, path: path}) do
      case {method, String.split(path, "/")} do
        {"GET", ["", "1.0", "certificates"]} ->
          {:ok, :list, nil}

        {"POST", ["", "1.0", "certificates"]} ->
          {:ok, :create, nil}

        {method, ["", "1.0", "certificates", fingerprint]}
        when method in ["GET", "PUT", "DELETE"] ->
          if Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
            do:
              {:ok, %{"GET" => :get, "PUT" => :update, "DELETE" => :delete}[method], fingerprint},
            else: {:error, Failure.new(400, "Invalid certificate fingerprint", :not_sent)}

        _ ->
          {:error, Failure.new(405, "Certificate action is not supported", :not_sent)}
      end
    end

    defp read(conn, _, :none, lease) do
      with :ok <- live(lease), do: {:ok, %{}, conn}
    end

    defp read(conn, gateway, _, lease) do
      deadline = System.monotonic_time(:millisecond) + gateway.max_lifetime
      read_body(conn, gateway, deadline, [], 0, lease)
    end

    defp read_body(conn, gateway, deadline, chunks, size, lease) do
      with :ok <- live(lease) do
        read_live_body(conn, gateway, deadline, chunks, size, lease)
      end
    end

    defp read_live_body(conn, gateway, deadline, chunks, size, lease) do
      timeout = min(gateway.idle_timeout, max(1, deadline - System.monotonic_time(:millisecond)))

      case Plug.Conn.read_body(conn,
             length:
               min(
                 gateway.max_chunk_bytes,
                 max(1, min(gateway.max_identity_bytes, gateway.max_request_bytes))
               ),
             read_timeout: timeout
           ) do
        {status, data, conn} when status in [:ok, :more] ->
          with :ok <- live(lease) do
            accumulate(conn, gateway, deadline, chunks, size, lease, status, data)
          end

        _ ->
          {:error, Failure.new(400, "Invalid certificate body", :not_sent)}
      end
    end

    defp accumulate(conn, gateway, deadline, chunks, size, lease, status, data) do
      size = size + byte_size(data)

      cond do
        size > min(gateway.max_identity_bytes, gateway.max_request_bytes) ->
          {:error, Failure.new(413, "Certificate body exceeds the gateway limit", :not_sent)}

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, Failure.new(408, "Certificate body timed out", :not_sent)}

        status == :more ->
          read_body(conn, gateway, deadline, [data | chunks], size, lease)

        true ->
          decode_body(conn, Enum.reverse([data | chunks]))
      end
    end

    defp decode_body(conn, chunks) do
      case Jason.decode(IO.iodata_to_binary(chunks)) do
        {:ok, body} when is_map(body) -> {:ok, body, conn}
        _ -> {:error, Failure.new(400, "Invalid certificate body", :not_sent)}
      end
    end

    defp claims(body) do
      allowed = ~w(certificate name type restricted projects trust_token token description)

      if Map.keys(body) -- allowed == [] and Map.get(body, "restricted", false) == false and
           Map.get(body, "projects", []) in [nil, []] and
           Map.get(body, "type", "client") == "client" and
           Map.get(body, "token", false) == false,
         do: :ok,
         else:
           {:error,
            Failure.new(400, "Certificate claims are not enforceable by this gateway", :not_sent)}
    end

    defp precondition(conn) do
      case Plug.Conn.get_req_header(conn, "if-match") do
        [] -> {:ok, nil}
        [etag] -> {:ok, etag}
        _ -> {:error, Failure.new(400, "Ambiguous certificate precondition", :not_sent)}
      end
    end

    # Validation and encoding are inside the same killable callback budget.
    defp prepare_certificate(gateway, {:ok, metadata, headers}) when is_list(headers) do
      with true <- :erlang.external_size(metadata) <= gateway.max_identity_bytes,
           true <- :erlang.external_size(headers) <= gateway.max_header_bytes,
           :ok <- response_claims(metadata),
           {:ok, headers} <- Headers.response(headers),
           true <- Enum.all?(headers, fn {key, _} -> key in ["etag", "location"] end),
           {:ok, body} <- Jason.encode(Identity.envelope(metadata)),
           true <- byte_size(body) <= min(gateway.max_identity_bytes, gateway.max_response_bytes) do
        {:ok, body, headers}
      else
        _ -> {:invalid, 502}
      end
    end

    defp prepare_certificate(_, {:error, status}) when status in 400..599, do: {:error, status}
    defp prepare_certificate(_, _), do: {:invalid, 502}

    defp response_claims(metadata) when is_map(metadata) do
      if Map.get(metadata, "restricted", false) == false and
           Map.get(metadata, "projects", []) in [nil, []], do: :ok, else: :error
    end

    defp response_claims(metadata) when is_list(metadata) do
      if Enum.all?(metadata, &(response_claims(&1) == :ok)), do: :ok, else: :error
    end

    defp response_claims(_), do: :ok

    defp respond(conn, gateway, envelope, headers, lease) do
      case live(lease) do
        :ok -> respond_live(conn, gateway, envelope, headers, lease)
        {:error, failure} -> HTTPRelay.fail(conn, failure)
      end
    end

    defp respond_live(conn, gateway, envelope, headers, lease) do
      body = Jason.encode!(envelope)

      if byte_size(body) <= min(gateway.max_identity_bytes, gateway.max_response_bytes) and
           :erlang.external_size(headers) <= gateway.max_header_bytes do
        send_json(conn, body, headers, lease)
      else
        HTTPRelay.fail(
          conn,
          Failure.new(502, "Identity response exceeds the gateway limit", :not_sent)
        )
      end
    end

    defp send_json(conn, body, headers, lease, outcome \\ :not_sent) do
      case live(lease) do
        :ok ->
          %{conn | resp_headers: [{"content-type", "application/json"} | headers]}
          |> Plug.Conn.send_resp(200, body)

        {:error, failure} ->
          HTTPRelay.fail(conn, %{failure | outcome: outcome})
      end
    end

    defp live(lease) do
      case Lease.check(lease) do
        :ok ->
          :ok

        {:error, :admission} ->
          {:error, Failure.new(503, "Gateway admission stopped", :not_sent)}

        {:error, :revoked} ->
          {:error, Failure.new(403, "Authorization expired or revoked", :not_sent)}
      end
    end
  end
end
