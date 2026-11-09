if Code.ensure_loaded?(Plug.Conn) do
  defmodule Opsmaru.Incus.Gateway.Plug do
    @moduledoc """
    Mountable Plug relaying native Incus HTTP and optional WebSockets through host policy.

    Mount it for the canonical native routes, before any body parser:

        # Phoenix router: one root discovery route plus the /1.0 tree.
        get "/", Opsmaru.Incus.Gateway.Plug, gateway: {MyHost.Gateway, :fetch, []}
        forward "/1.0", Opsmaru.Incus.Gateway.Plug, gateway: {MyHost.Gateway, :fetch, []}

    `:gateway` is either an `Opsmaru.Incus.Gateway` or an `{module, function,
    args}` returning one at request time; prefer the MFA so runtime
    configuration and the admission pid are never compiled into the router.

    Routing uses the original encoded `request_path` and raw `query_string`, so
    `forward` does not change what the backend receives. Only `/`, `/1.0` and
    `/1.0/*` are relayed; other paths fail with a native `404` and no backend
    contact. If a body parser already consumed the request, the gateway
    refuses it with `500` rather than relaying a reconstructed body.

    Every request goes through `Opsmaru.Incus.Gateway.Policy` (admission,
    readiness, authorization, expiry/revocation) before a backend socket opens.
    Discovery and certificate trust use bounded host callbacks; authenticated
    GET `/1.0` buffers/replaces public identity. WebSockets use the optional
    native WebSocket adapter when available; raw SFTP/NBD requires the host's
    same-listener Cowboy gateway handler. Missing adapters fail with `501`.
    See `docs/gateway.md` for the verified protocol and mounting contract.

    Response streaming is tested with Plug.Cowboy. When a response that has
    already started cannot be completed (backend loss, deadline, budget,
    revocation), the gateway ends the caller's HTTP/1.x connection without a
    final chunk, so the caller sees a truncated response rather than a complete
    one. On HTTP/2 it resets the stream.
    """

    @behaviour Plug

    alias Opsmaru.Incus.Gateway
    alias Opsmaru.Incus.Gateway.{Failure, HTTPRelay, Local, Policy, WebSocket}

    @impl true
    def init(opts) do
      case Keyword.fetch(opts, :gateway) do
        {:ok, %Gateway{} = gateway} ->
          {:static, gateway}

        {:ok, {module, function, args}}
        when is_atom(module) and is_atom(function) and is_list(args) ->
          {:dynamic, {module, function, args}}

        _ ->
          raise ArgumentError,
                "gateway must be an Opsmaru.Incus.Gateway or {module, function, args}"
      end
    end

    @impl true
    def call(conn, source) do
      case resolve(source) do
        {:ok, gateway} -> serve(conn, gateway)
        :error -> HTTPRelay.fail(conn, Failure.new(503, "Gateway is not configured", :not_sent))
      end
    end

    defp resolve({:static, gateway}), do: {:ok, gateway}

    defp resolve({:dynamic, {module, function, args}}) do
      case apply(module, function, args) do
        %Gateway{} = gateway -> {:ok, gateway}
        _ -> :error
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end

    defp serve(conn, gateway) do
      with :ok <- unread_body(conn),
           {:ok, authorization} <- authorization(conn),
           {:ok, request} <- Policy.request(fields(conn, authorization)),
           {:ok, admitted} <- Policy.admit(gateway, request) do
        try do
          cond do
            request.protocol == :websocket ->
              websocket(conn, gateway, request, admitted)

            request.protocol == :raw ->
              HTTPRelay.fail(
                conn,
                Failure.new(501, "Raw upgrades require the Cowboy gateway handler", :not_sent)
              )

            Local.local?(request) or admitted.anonymous ->
              Local.serve(conn, gateway, request, admitted)

            true ->
              HTTPRelay.relay(conn, gateway, request, admitted)
          end
        after
          Policy.release(admitted)
        end
      else
        {:error, %Failure{} = failure} -> HTTPRelay.fail(conn, failure)
      end
    end

    defp websocket(conn, gateway, request, admitted),
      do: Function.capture(WebSocket, :upgrade, 4).(conn, gateway, request, admitted)

    defp fields(conn, authorization) do
      peer = Plug.Conn.get_peer_data(conn)

      %{
        protocol: protocol(conn),
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        peer: %{address: peer.address, port: peer.port, certificate: peer.ssl_cert},
        authorization: authorization
      }
    end

    defp protocol(conn) do
      case Plug.Conn.get_req_header(conn, "upgrade") do
        [] ->
          :http

        values ->
          tokens =
            for value <- values,
                token <- String.split(value, ","),
                do: token |> String.trim() |> String.downcase()

          if tokens == ["websocket"], do: :websocket, else: :raw
      end
    end

    defp authorization(conn) do
      case Plug.Conn.get_req_header(conn, "authorization") do
        [] -> {:ok, nil}
        [value] -> {:ok, value}
        _ -> {:error, Failure.new(400, "Ambiguous authorization", :not_sent)}
      end
    end

    defp unread_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: :ok

    defp unread_body(_),
      do:
        {:error,
         Failure.new(500, "Gateway must be mounted before request body parsing", :not_sent)}
  end
end
