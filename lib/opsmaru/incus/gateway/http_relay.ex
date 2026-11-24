if Code.ensure_loaded?(Plug.Conn) do
  defmodule Opsmaru.Incus.Gateway.HTTPRelay do
    @moduledoc false
    # Streamed native HTTP relay for one admitted exchange.
    #
    # One fresh backend connection per exchange, never pooled, retried or
    # redirected. Request bodies are read from the caller in bounded chunks and
    # streamed to the backend; response bodies are streamed back in Mint's
    # active-once mode, so each chunk is delivered (Cowboy acknowledges it)
    # before the next backend read. The exchange records whether request bytes
    # may have reached the backend: failures after that point report
    # `:uncertain` for mutations and are never retried.

    alias Opsmaru.Incus.Gateway.{Exchange, Failure, Headers, Identity, Lease}
    alias Opsmaru.Incus.Transport

    @safe ~w(GET HEAD)

    def relay(conn, gateway, request, admitted) do
      monitor = Process.monitor(admitted.admission)
      lease = Lease.start(gateway, request, admitted, interrupter(conn))

      state = %{
        gateway: gateway,
        lease: lease,
        identity: request.method == "GET" and request.path == "/1.0",
        request: request,
        method: request.method,
        admission: admitted.admission,
        monitor: monitor,
        deadline: now() + gateway.max_lifetime,
        image_upload: admitted.image_peer and match?(%{route: :upload}, request.image),
        first: nil,
        exchange: exchange(conn),
        sent_outcome: if(request.method in @safe, do: :sent, else: :uncertain)
      }

      try do
        case Headers.request(
               conn.req_headers,
               gateway.max_header_bytes,
               gateway.max_request_bytes,
               unsized_body?(conn)
             ) do
          {:ok, headers, body} ->
            with {:ok, state} <- identity(state),
                 {:ok, conn, state} <- image_upload(conn, body, state) do
              connect(conn, request, headers, body, state)
            else
              {:error, failure} -> fail(conn, failure)
              {:error, conn, failure} -> fail(conn, failure)
            end

          {:error, failure} ->
            fail(conn, failure)
        end
      after
        Lease.stop(lease)
        Process.demonitor(monitor, [:flush])
      end
    end

    defp identity(%{identity: true} = state) do
      case Identity.load(state.gateway, state.request) do
        {:ok, identity} -> {:ok, %{state | identity: identity}}
        error -> error
      end
    end

    defp identity(state), do: {:ok, state}

    # A server peer admitted by its image secret alone may only deliver the
    # image. The pinned v7.0.1 incusd picks the action of `POST /1.0/images`
    # from the body, whatever the content type: a body that starts with a JSON
    # object (after JSON whitespace) is an image request, which can make the
    # backend fetch from a server or URL the peer chooses, publish an instance
    # or mint a token. Anything else is taken as the image itself. So the first
    # body byte is checked before any backend connection opens (the backend
    # consumes the one-time secret as soon as it sees the request head). Image
    # files and the multipart form start with neither whitespace nor `{`.
    defp image_upload(conn, _body, %{image_upload: false} = state), do: {:ok, conn, state}

    defp image_upload(conn, :none, _state), do: {:error, conn, not_image()}

    defp image_upload(conn, body, state) do
      case read_chunk(conn, state, :not_sent) do
        {:ok, :more, "", conn} ->
          image_upload(conn, body, state)

        {:ok, status, <<byte, _::binary>> = data, conn} when byte not in ~c" \t\r\n{" ->
          {:ok, conn, %{state | first: {status, data}}}

        {:ok, _status, _data, conn} ->
          {:error, conn, not_image()}

        {:error, conn, failure} ->
          {:error, conn, failure}
      end
    end

    defp not_image,
      do:
        Failure.new(403, "An image secret admits only the image upload itself", :not_sent,
          reason: :unauthorized
        )

    @doc false
    def interrupter(conn) do
      exchange = exchange(conn)
      kill = kill(conn)

      fn reason ->
        Exchange.interrupt(exchange, reason)
        kill.()
      end
    end

    defp kill(%Plug.Conn{adapter: {Plug.Cowboy.Conn, %{pid: pid, version: version}}})
         when version in [:"HTTP/1.1", :"HTTP/1.0"],
         do: fn -> Process.exit(pid, :kill) end

    defp kill(_), do: fn -> :ok end

    @exchange :opsmaru_incus_gateway_exchange

    @doc false
    # The exchange observed for this Plug request, or an inert one.
    def exchange(%Plug.Conn{private: private}),
      do: Map.get(private, @exchange) || Exchange.inert()

    @doc false
    def put_exchange(conn, exchange), do: Plug.Conn.put_private(conn, @exchange, exchange)

    defp unsized_body?(%Plug.Conn{adapter: {Plug.Cowboy.Conn, req}}) do
      Function.capture(:cowboy_req, :has_body, 1).(req) and
        Function.capture(:cowboy_req, :body_length, 1).(req) == :undefined
    end

    defp unsized_body?(_), do: false

    # Admission can stop while the host callbacks run; its slot is then gone,
    # so no backend connection is opened for it.
    defp connect(conn, request, headers, body, state) do
      connection = state.gateway.connection

      with :ok <- live(state),
           {:ok, socket} <-
             open(connection, min(state.deadline, now() + connection.timeout)) do
        try do
          exchange(conn, socket, request, headers, body, state)
        after
          Mint.HTTP.close(socket)
        end
      else
        {:error, :backend} ->
          fail(conn, Failure.new(502, "Backend is unavailable", :not_sent, reason: :backend))

        {:error, reason} ->
          fail(conn, interrupted(reason, :not_sent))
      end
    end

    defp open(connection, deadline) do
      case Transport.open(connection, deadline) do
        {:ok, socket} -> {:ok, socket}
        {:error, _} -> {:error, :backend}
      end
    end

    defp exchange(conn, socket, request, headers, body, state) do
      target =
        if request.query == "", do: request.path, else: request.path <> "?" <> request.query

      headers = backend_headers(state.gateway.connection, headers)
      mint_body = if body == :none, do: nil, else: :stream

      # Last check before request bytes may reach the backend.
      with :ok <- live(state),
           {:ok, socket, ref} <-
             Mint.HTTP.request(socket, request.method, target, headers, mint_body) do
        Exchange.sent(state.exchange, state.sent_outcome)

        case send_body(conn, socket, ref, body, state) do
          {:ok, conn, socket} -> respond(conn, socket, ref, state)
          {:error, conn, failure} -> fail(conn, failure)
        end
      else
        {:error, reason} when reason in [:admission, :lifetime, :revoked] ->
          fail(conn, interrupted(reason, :not_sent))

        {:error, _, _} ->
          fail(
            conn,
            Failure.new(502, "Backend request failed", state.sent_outcome, reason: :backend)
          )
      end
    end

    # The connection's own require_authenticated flag replaces any caller copy;
    # the connection also sets the backend host.
    defp backend_headers(%{require_authenticated: true} = connection, headers),
      do:
        Transport.request_headers(
          connection,
          Enum.reject(headers, fn {name, _} -> name == "x-incus-authenticated" end)
        )

    defp backend_headers(connection, headers), do: Transport.request_headers(connection, headers)

    # An image peer's first chunk was already read and checked.
    defp send_body(conn, socket, ref, body, %{first: {status, data}} = state),
      do: forward(conn, socket, ref, body, state, 0, status, data)

    defp send_body(conn, socket, ref, body, state), do: upload(conn, socket, ref, body, state, 0)

    defp upload(conn, socket, _ref, :none, _state, _sent), do: {:ok, conn, socket}

    defp upload(conn, socket, ref, body, state, sent) do
      case read_chunk(conn, state, state.sent_outcome) do
        {:ok, status, data, conn} -> forward(conn, socket, ref, body, state, sent, status, data)
        {:error, conn, failure} -> {:error, conn, failure}
      end
    end

    defp read_chunk(conn, state, outcome) do
      gateway = state.gateway

      with :ok <- live(state),
           {status, data, conn} when status in [:ok, :more] <-
             Plug.Conn.read_body(conn,
               length: gateway.max_chunk_bytes,
               read_length: gateway.max_chunk_bytes,
               read_timeout: min(gateway.idle_timeout, remaining(state.deadline))
             ) do
        # Counted when read, so a checked image chunk is counted once.
        Exchange.request_bytes(state.exchange, byte_size(data))
        {:ok, status, data, conn}
      else
        {:error, reason} when reason in [:admission, :lifetime, :revoked] ->
          {:error, conn, interrupted(reason, outcome)}

        _ ->
          {:error, conn,
           Failure.new(408, "Request body was not received", outcome, reason: :idle)}
      end
    end

    defp forward(conn, socket, ref, body, state, sent, status, data) do
      sent = sent + byte_size(data)

      if sent > state.gateway.max_request_bytes do
        {:error, conn,
         Failure.new(413, "Request body exceeds the gateway limit", state.sent_outcome,
           reason: :limit
         )}
      else
        case stream_body(socket, ref, data) do
          {:ok, socket} when status == :more ->
            upload(conn, socket, ref, body, state, sent)

          {:ok, socket} ->
            finish_upload(conn, socket, ref, body, sent, state)

          :error ->
            {:error, conn,
             Failure.new(502, "Backend request failed", state.sent_outcome, reason: :backend)}
        end
      end
    end

    defp finish_upload(conn, socket, ref, body, sent, state) do
      complete = match?(:chunked, body) or body == {:length, sent}

      with true <- complete,
           {:ok, socket} <- Mint.HTTP.stream_request_body(socket, ref, :eof) do
        {:ok, conn, socket}
      else
        _ ->
          {:error, conn,
           Failure.new(400, "Request body was incomplete", state.sent_outcome,
             reason: :invalid_request
           )}
      end
    end

    defp stream_body(socket, _ref, ""), do: {:ok, socket}

    defp stream_body(socket, ref, data) do
      case Mint.HTTP.stream_request_body(socket, ref, data) do
        {:ok, socket} -> {:ok, socket}
        {:error, _, _} -> :error
      end
    end

    defp respond(conn, socket, ref, state) do
      case Mint.HTTP.set_mode(socket, :active) do
        {:ok, socket} ->
          head(conn, socket, ref, state, nil)

        {:error, _} ->
          fail(
            conn,
            Failure.new(502, "Backend response failed", state.sent_outcome, reason: :backend)
          )
      end
    end

    # Before the response is committed: wait for the final status and headers.
    defp head(conn, socket, ref, state, status) do
      case await(socket, state) do
        {:ok, socket, responses} -> head_responses(conn, socket, ref, state, status, responses)
        {:error, reason} -> fail(conn, interrupted(reason, state.sent_outcome))
      end
    end

    defp head_responses(conn, socket, ref, state, status, [response | rest]) do
      case response do
        {:status, ^ref, status} ->
          head_responses(conn, socket, ref, state, status, rest)

        {:headers, ^ref, _} when status in 100..199 and status != 101 ->
          head_responses(conn, socket, ref, state, nil, rest)

        {:headers, ^ref, headers} when status in 200..599 ->
          commit(conn, socket, ref, state, status, headers, rest)

        {:headers, ^ref, headers} ->
          fail(
            conn,
            Failure.new(
              502,
              "Backend sent an invalid response",
              state.sent_outcome,
              reason: :backend,
              operation: operation(headers)
            )
          )

        _ ->
          fail(
            conn,
            Failure.new(502, "Backend sent an invalid response", state.sent_outcome,
              reason: :backend
            )
          )
      end
    end

    defp head_responses(conn, socket, ref, state, status, []),
      do: head(conn, socket, ref, state, status)

    defp commit(conn, socket, ref, state, status, headers, rest) do
      case Headers.response(headers) do
        {:ok, headers} ->
          if is_map(state.identity) and status == 200 do
            identity_body(conn, socket, ref, state, headers, [], 0, rest)
          else
            conn = Plug.Conn.send_chunked(%{conn | resp_headers: headers}, status)
            body_responses(conn, socket, ref, state, 0, rest)
          end

        :error ->
          fail(
            conn,
            Failure.new(
              502,
              "Backend sent an invalid response header",
              state.sent_outcome,
              reason: :backend,
              operation: operation(headers)
            )
          )
      end
    end

    # GET /1.0 is the sole buffered backend body. Errors remain native streams.
    defp identity_body(conn, socket, ref, state, headers, chunks, bytes, []) do
      case await(socket, state) do
        {:ok, socket, responses} ->
          identity_body(conn, socket, ref, state, headers, chunks, bytes, responses)

        {:error, reason} ->
          fail(conn, interrupted(reason, state.sent_outcome))
      end
    end

    defp identity_body(conn, socket, ref, state, headers, chunks, bytes, [response | rest]) do
      limit = min(state.gateway.max_identity_bytes, state.gateway.max_response_bytes)

      case response do
        {:data, ^ref, data} when bytes + byte_size(data) <= limit ->
          case live(state) do
            :ok ->
              identity_body(
                conn,
                socket,
                ref,
                state,
                headers,
                [data | chunks],
                bytes + byte_size(data),
                rest
              )

            {:error, reason} ->
              fail(conn, interrupted(reason, state.sent_outcome))
          end

        {:headers, ^ref, trailers} ->
          case Headers.trailers(trailers) do
            {:ok, _} ->
              identity_body(conn, socket, ref, state, headers, chunks, bytes, rest)

            :error ->
              fail(
                conn,
                Failure.new(502, "Invalid backend identity trailer", state.sent_outcome,
                  reason: :backend
                )
              )
          end

        {:done, ^ref} ->
          finish_identity(conn, state, headers, chunks, limit)

        _ ->
          fail(
            conn,
            Failure.new(502, "Invalid or oversized backend identity", state.sent_outcome,
              reason: :backend
            )
          )
      end
    end

    defp finish_identity(conn, state, headers, chunks, limit) do
      with :ok <- live(state),
           false <- List.keymember?(headers, "content-encoding", 0),
           {:ok, body} <-
             Identity.rewrite(IO.iodata_to_binary(Enum.reverse(chunks)), state.identity, limit),
           :ok <- live(state) do
        # The old length and validators describe different bytes after mediation.
        headers =
          Enum.reject(headers, fn {name, _} ->
            name in ~w(content-length etag content-md5 digest)
          end)

        %{conn | resp_headers: headers} |> Plug.Conn.send_resp(200, body)
      else
        _ ->
          fail(
            conn,
            Failure.new(502, "Invalid or oversized backend identity", state.sent_outcome,
              reason: :backend
            )
          )
      end
    end

    # After the response is committed: stream body, trailers and completion.
    defp body(conn, socket, ref, state, bytes) do
      case await(socket, state) do
        {:ok, socket, responses} -> body_responses(conn, socket, ref, state, bytes, responses)
        {:error, reason} -> abort(conn, state, reason)
      end
    end

    defp body_responses(conn, socket, ref, state, bytes, [response | rest]) do
      case response do
        {:data, ^ref, data} ->
          bytes = bytes + byte_size(data)

          # A busy stream never idles, so its lifetime is checked per chunk.
          with {:ok, _} <- within(bytes, state.gateway.max_response_bytes),
               :ok <- live(state) do
            case Plug.Conn.chunk(conn, data) do
              {:ok, conn} ->
                Exchange.response_bytes(state.exchange, byte_size(data))
                body_responses(conn, socket, ref, state, bytes, rest)

              {:error, _} ->
                Exchange.interrupt(state.exchange, :caller_closed)
                conn
            end
          else
            {:error, reason} -> abort(conn, state, reason)
          end

        {:headers, ^ref, trailers} ->
          trailers(conn, trailers)
          body_responses(conn, socket, ref, state, bytes, rest)

        {:done, ^ref} ->
          conn

        _ ->
          abort(conn, state, :backend)
      end
    end

    defp body_responses(conn, socket, ref, state, bytes, []),
      do: body(conn, socket, ref, state, bytes)

    # Plug has no trailer API; Cowboy forwards them when the caller sent
    # `TE: trailers` and otherwise drops them. Other adapters drop them.
    defp trailers(%Plug.Conn{adapter: {Plug.Cowboy.Conn, req}}, trailers) do
      case Headers.trailers(trailers) do
        {:ok, []} ->
          :ok

        {:ok, trailers} ->
          map =
            Enum.reduce(trailers, %{}, fn {name, value}, map ->
              Map.update(map, name, value, &(&1 <> ", " <> value))
            end)

          Function.capture(:cowboy_req, :stream_trailers, 2).(map, req)

        :error ->
          :ok
      end
    end

    defp trailers(_, _), do: :ok

    # Admission loss and the lifetime deadline take priority over backend data
    # that is already queued.
    defp await(socket, state) do
      with :ok <- live(state), do: receive_backend(socket, state)
    end

    defp receive_backend(socket, state) do
      raw = Mint.HTTP.get_socket(socket)
      monitor = state.monitor
      lease_pid = state.lease.pid
      timeout = min(state.gateway.idle_timeout, remaining(state.deadline))

      receive do
        {tag, ^raw, _} = message when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
          stream(socket, message)

        {tag, ^raw} = message when tag in [:tcp_closed, :ssl_closed] ->
          stream(socket, message)

        {:DOWN, ^monitor, :process, _, _} ->
          {:error, :admission}

        {:gateway_stopped, ^lease_pid, reason} when reason in [:admission, :revoked] ->
          {:error, reason}
      after
        timeout -> {:error, if(remaining(state.deadline) == 0, do: :lifetime, else: :idle)}
      end
    end

    defp stream(socket, message) do
      case Mint.HTTP.stream(socket, message) do
        {:ok, socket, responses} -> {:ok, socket, responses}
        {:error, _, _, _} -> {:error, :backend}
        :unknown -> {:error, :backend}
      end
    end

    # The DOWN message of an admission that was already exiting when it was
    # monitored can arrive late; `Process.alive?/1` is false once it exits.
    defp live(state) do
      monitor = state.monitor

      receive do
        {:DOWN, ^monitor, :process, _, _} -> {:error, :admission}
      after
        0 ->
          cond do
            not Process.alive?(state.admission) -> {:error, :admission}
            not Lease.valid?(state.lease) -> {:error, :revoked}
            remaining(state.deadline) == 0 -> {:error, :lifetime}
            true -> :ok
          end
      end
    end

    defp interrupted(:revoked, outcome),
      do: Failure.new(403, "Authorization expired or revoked", outcome, reason: :revoked)

    defp interrupted(:admission, outcome),
      do: Failure.new(503, "Gateway admission stopped", outcome, reason: :admission)

    defp interrupted(reason, outcome) when reason in [:idle, :lifetime],
      do: Failure.new(504, "Backend response timed out", outcome, reason: reason)

    defp interrupted(_, outcome),
      do: Failure.new(502, "Backend response failed", outcome, reason: :backend)

    defp operation(headers) do
      case List.keyfind(headers, "location", 0) do
        {"location", "/1.0/operations/" <> _ = location} -> location
        _ -> nil
      end
    end

    @doc false
    def fail(conn, failure) do
      {status, headers, body} = Failure.encode(failure)

      conn =
        %{conn | resp_headers: headers}
        |> Plug.Conn.send_resp(status, body)

      Exchange.finish(exchange(conn), failure)
      conn
    end

    # A committed response cannot become an error response. End it so the
    # caller cannot mistake a truncated body for a complete one.
    defp abort(conn, state, reason) do
      Exchange.interrupt(state.exchange, reason)
      abort(conn)
    end

    defp abort(%Plug.Conn{adapter: {Plug.Cowboy.Conn, %{pid: pid, version: version}}})
         when version in [:"HTTP/1.1", :"HTTP/1.0"] do
      # Cowboy would otherwise send the final chunk. Ending the connection
      # process (it serves one exchange at a time on HTTP/1.x) closes the
      # socket first; this linked request process then exits.
      Process.exit(pid, :kill)
      exit(:gateway_stream_aborted)
    end

    defp abort(_conn), do: exit(:gateway_stream_aborted)

    defp within(bytes, maximum), do: if(bytes > maximum, do: {:error, :limit}, else: {:ok, bytes})

    defp now, do: System.monotonic_time(:millisecond)
    defp remaining(deadline), do: max(0, deadline - now())
  end
end
