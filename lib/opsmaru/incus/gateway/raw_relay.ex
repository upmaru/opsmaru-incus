if Code.ensure_loaded?(:cowboy_req) do
  defmodule Opsmaru.Incus.Gateway.RawRelay do
    @moduledoc false
    alias Opsmaru.Incus.Gateway.{Exchange, Failure, Headers, Lease, Policy, UpgradeResponse}
    alias Opsmaru.Incus.{Redaction, Transport}

    # The actor owns the slot, lease and backend before negotiation and keeps
    # them throughout takeover. Neither the HTTP worker nor the connection
    # process can accidentally release or inherit another request's resources.
    # `exchange` is owned by the caller until `handoff/1` succeeds and the
    # caller transfers it; from then on this actor reports its end.
    def start(gateway, request, holder, validate, exchange \\ Exchange.inert()) do
      caller = self()
      ref = make_ref()
      deadline = now() + gateway.max_lifetime
      dispatch = :atomics.new(1, [])

      {pid, monitor} =
        spawn_monitor(fn ->
          init(caller, ref, gateway, request, holder, validate, {dispatch, exchange})
        end)

      receive do
        {^ref, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^pid, _} ->
          {:error,
           failure(
             if(now() >= deadline, do: 504, else: 502),
             dispatch_outcome(dispatch),
             if(now() >= deadline, do: :lifetime, else: :backend)
           )}
      after
        gateway.max_lifetime + 100 ->
          Process.exit(pid, :kill)
          {:error, failure(504, dispatch_outcome(dispatch), :lifetime)}
      end
    end

    def handoff(pid) do
      ref = make_ref()
      monitor = Process.monitor(pid)
      send(pid, {:handoff, self(), ref})

      receive do
        {^ref, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, _, _} ->
          {:error, failure(503, :sent, :not_ready)}
      after
        30_100 ->
          Process.demonitor(monitor, [:flush])
          Process.exit(pid, :kill)
          {:error, failure(504, :sent, :lifetime)}
      end
    end

    def attach(pid, client, transport, buffer) do
      ref = make_ref()
      send(pid, {:attach, self(), ref, client, transport, buffer})

      receive do
        {^ref, result} -> result
      after
        5_000 -> {:error, :handoff}
      end
    end

    defp init(caller, ref, gateway, request, holder, validate, {dispatch, exchange}) do
      caller_monitor = Process.monitor(caller)
      holder_monitor = Process.monitor(holder)
      # This watcher also interrupts connect/handshake or a blocked write.
      deadline = now() + gateway.max_lifetime
      watcher = watch(caller, holder, deadline, exchange)

      case Policy.admit(gateway, request) do
        {:ok, admitted} ->
          Exchange.admitted(exchange, admitted.admitted_as)

          lease =
            Lease.start(gateway, request, admitted, fn reason ->
              Exchange.interrupt(exchange, reason)
              Process.exit(holder, :kill)
            end)

          try do
            with {:ok, protocol, headers} <- validate.(),
                 :ok <- Lease.check(lease),
                 {:ok, backend} <- open(gateway, deadline) do
              try do
                case handshake(
                       backend,
                       gateway,
                       request,
                       protocol,
                       headers,
                       deadline,
                       {dispatch, exchange}
                     ) do
                  {:ok, response, initial} ->
                    send(caller, {ref, {:ok, self(), {:upgrade, response}}})

                    state = %{
                      gateway: gateway,
                      request: request,
                      admitted: admitted,
                      lease: lease,
                      backend: backend,
                      backend_buffer: initial,
                      caller: caller,
                      caller_monitor: caller_monitor,
                      holder: holder,
                      holder_monitor: holder_monitor,
                      watcher: watcher,
                      deadline: deadline,
                      exchange: exchange
                    }

                    await_handoff(state)

                  {:response, status, response_headers, body} ->
                    send(
                      caller,
                      {ref, {:ok, self(), {:response, status, response_headers, body}}}
                    )

                  {:error, error} ->
                    send(caller, {ref, {:error, normalize_failure(error)}})
                end
              after
                close(backend)
              end
            else
              {:error, error} -> send(caller, {ref, {:error, normalize_failure(error)}})
            end
          after
            Lease.stop(lease)
            Policy.release(admitted)
            Process.exit(watcher, :kill)
          end

        {:error, error} ->
          send(caller, {ref, {:error, normalize_failure(error)}})
          Process.exit(watcher, :kill)
      end
    end

    defp watch(caller, holder, deadline, exchange) do
      actor = self()

      spawn(fn ->
        actor_ref = Process.monitor(actor)
        caller_ref = Process.monitor(caller)
        holder_ref = Process.monitor(holder)
        watch_loop(actor, actor_ref, caller_ref, holder_ref, {deadline, exchange})
      end)
    end

    defp watch_loop(actor, actor_ref, caller_ref, holder_ref, {deadline, exchange} = limit) do
      receive do
        {:DOWN, ^actor_ref, :process, _, _} ->
          :ok

        {:DOWN, ^caller_ref, :process, _, _} ->
          Process.exit(actor, :kill)

        {:DOWN, ^holder_ref, :process, _, _} ->
          Process.exit(actor, :kill)

        {:handoff, ref} ->
          Process.demonitor(caller_ref, [:flush])
          send(actor, {ref, :handoff_ready})
          watch_loop(actor, actor_ref, nil, holder_ref, limit)
      after
        max(0, deadline - now()) ->
          Exchange.interrupt(exchange, :lifetime)
          Process.exit(actor, :kill)
      end
    end

    defp open(gateway, deadline) do
      case Transport.open(
             gateway.connection,
             min(deadline, now() + min(gateway.connection.timeout, gateway.idle_timeout))
           ) do
        {:ok, conn} ->
          transport = if gateway.connection.transport == :unix, do: :gen_tcp, else: :ssl
          socket = Mint.HTTP.get_socket(conn)
          {:ok, %{conn: conn, transport: transport, socket: socket}}

        _ ->
          {:error, failure(502, :not_sent, :backend)}
      end
    end

    defp handshake(backend, gateway, request, protocol, headers, deadline, {dispatch, exchange}) do
      target = request.path <> if(request.query == "", do: "", else: "?" <> request.query)

      headers =
        Transport.request_headers(
          gateway.connection,
          Enum.reject(headers, fn {name, _} -> name == "x-incus-authenticated" end) ++
            [{"connection", "Upgrade"}, {"upgrade", protocol}]
        )

      deadline = min(deadline, now() + min(gateway.connection.timeout, gateway.idle_timeout))

      # The upgrade request may reach the backend from here.
      :atomics.put(dispatch, 1, 1)
      Exchange.sent(exchange, :sent)

      with {:ok, conn, ref} <- Mint.HTTP.request(backend.conn, "GET", target, headers, nil),
           {:ok, _, status, response, data} <-
             UpgradeResponse.receive_response(
               conn,
               ref,
               deadline,
               gateway.max_response_bytes,
               gateway.max_header_bytes
             ),
           {:ok, safe} <- Headers.response(response),
           true <- header_budget?(response, gateway.max_header_bytes) do
        body = IO.iodata_to_binary(Enum.reverse(data))

        cond do
          status == 101 and valid_response?(response, protocol) ->
            {:ok, safe ++ [{"connection", "Upgrade"}, {"upgrade", protocol}], body}

          status == 101 ->
            {:error, failure(502, :sent, :backend)}

          true ->
            {:response, status, safe, body}
        end
      else
        _ ->
          {:error,
           failure(
             if(now() >= deadline, do: 504, else: 502),
             :sent,
             if(now() >= deadline, do: :lifetime, else: :backend)
           )}
      end
    end

    defp header_budget?(headers, maximum) do
      Enum.reduce(headers, 0, fn {k, v}, n -> n + byte_size(k) + byte_size(v) + 4 end) <= maximum
    end

    defp valid_response?(headers, protocol) do
      upgrades = for {"upgrade", value} <- headers, do: value

      connection =
        for {"connection", value} <- headers,
            token <- String.split(value, ","),
            do: token |> String.trim() |> String.downcase()

      upgrades == [protocol] and "upgrade" in connection and
        Enum.all?(connection, &Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9a-z]+\z/, &1)) and
        not Enum.any?(headers, fn {name, _} ->
          name in ["content-length", "transfer-encoding", "trailer"]
        end)
    end

    defp await_handoff(state) do
      receive do
        {:handoff, caller, ref} when caller == state.caller ->
          result =
            with :ok <- Lease.check(state.lease),
                 do: Policy.recheck(state.gateway, state.request, state.admitted.grant)

          if result == :ok do
            Process.demonitor(state.caller_monitor, [:flush])
            handoff_ref = make_ref()
            send(state.watcher, {:handoff, handoff_ref})

            receive do
              {^handoff_ref, :handoff_ready} ->
                send(caller, {ref, :ok})
                await_socket(state)
                Exchange.finish(state.exchange, :ended)
            after
              max(0, state.deadline - now()) -> :ok
            end
          else
            send(caller, {ref, {:error, normalize_failure(elem(result, 1), :sent)}})
          end

        {:gateway_stopped, _, _} ->
          :ok

        {:DOWN, _, :process, _, _} ->
          :ok
      after
        min(
          max(0, state.deadline - now()),
          min(state.gateway.connection.timeout, state.gateway.idle_timeout)
        ) ->
          :ok
      end
    end

    defp await_socket(state) do
      receive do
        {:attach, holder, ref, client, transport, buffer} when holder == state.holder ->
          send(holder, {ref, :ok})
          run(state, client, transport, buffer)

        {:gateway_stopped, _, reason} ->
          interrupt(state, reason)

        {:DOWN, _, :process, _, _} ->
          interrupt(state, :killed)
      after
        min(
          max(0, state.deadline - now()),
          min(state.gateway.connection.timeout, state.gateway.idle_timeout)
        ) ->
          interrupt(state, if(now() >= state.deadline, do: :lifetime, else: :idle))
      end
    end

    defp run(state, client, transport, buffer) do
      backend = state.backend
      frontend = %{socket: client, transport: transport}
      writers = %{to_backend: writer(backend, state), to_client: writer(frontend, state)}

      try do
        :ok =
          setopts(backend,
            active: false,
            exit_on_close: false,
            buffer: state.gateway.max_chunk_bytes
          )

        :ok =
          setopts(frontend,
            active: false,
            exit_on_close: false,
            buffer: state.gateway.max_chunk_bytes
          )

        state =
          Map.merge(state, %{
            frontend: frontend,
            writers: writers,
            pending: MapSet.new(),
            client_closed: false,
            backend_closed: false,
            received: 0,
            written: 0,
            last_activity: now(),
            drain_deadline: nil
          })

        with :ok <- Lease.check(state.lease),
             {:ok, state} <- enqueue(state, :to_backend, buffer),
             {:ok, state} <- enqueue(state, :to_client, state.backend_buffer) do
          state = if buffer == "", do: arm(state, :to_backend), else: state
          state = if state.backend_buffer == "", do: arm(state, :to_client), else: state
          relay(state)
        else
          {:error, reason} -> interrupt(state, reason)
          :error -> interrupt(state, :limit)
        end
      after
        Enum.each(writers, fn {_, writer} -> Process.exit(writer, :kill) end)
        transport.close(client)
      end
    end

    defp writer(destination, state) do
      actor = self()

      {writer, _monitor} =
        spawn_monitor(fn ->
          monitor = Process.monitor(actor)
          write_loop(actor, monitor, destination, state)
        end)

      writer
    end

    defp write_loop(actor, monitor, destination, state) do
      receive do
        {:write, direction, bytes} ->
          result = write_chunks(destination, direction, bytes, state)
          send(actor, {:written, direction, result})
          write_loop(actor, monitor, destination, state)

        {:shutdown, direction} ->
          result = destination.transport.shutdown(destination.socket, :write)
          send(actor, {:shutdown, direction, result})
          write_loop(actor, monitor, destination, state)

        {:DOWN, ^monitor, :process, _, _} ->
          :ok
      end
    end

    defp write_chunks(_, _, <<>>, _), do: :ok

    defp write_chunks(destination, direction, bytes, state) do
      count = min(byte_size(bytes), state.gateway.max_chunk_bytes)
      <<chunk::binary-size(count), rest::binary>> = bytes
      timeout = min(state.gateway.idle_timeout, max(0, state.deadline - now()))

      with true <- timeout > 0,
           :ok <- setopts(destination, send_timeout: timeout, send_timeout_close: true),
           :ok <- destination.transport.send(destination.socket, chunk) do
        # Bytes reach the caller only once written; request bytes count on read.
        if direction == :to_client, do: Exchange.response_bytes(state.exchange, count)
        write_chunks(destination, direction, rest, state)
      else
        _ -> {:error, :write}
      end
    end

    defp relay(state) do
      lease = Lease.check(state.lease)

      cond do
        state.client_closed and state.backend_closed and MapSet.size(state.pending) == 0 -> :ok
        lease != :ok -> interrupt(state, elem(lease, 1))
        remaining(state) <= 0 -> interrupt(state, expired(state))
        true -> receive_data(state)
      end
    end

    defp receive_data(state) do
      client = state.frontend.socket
      backend = state.backend.socket

      receive do
        {tag, ^client, bytes} when tag in [:tcp, :ssl] ->
          receive_bytes(state, :to_backend, bytes)

        {tag, ^backend, bytes} when tag in [:tcp, :ssl] ->
          receive_bytes(state, :to_client, bytes)

        {:written, direction, :ok} ->
          state = %{
            state
            | pending: MapSet.delete(state.pending, direction),
              last_activity: now()
          }

          relay(arm(state, direction))

        {:written, direction, _} ->
          interrupt(state, side(direction))

        {:shutdown, direction, _} ->
          relay(%{state | pending: MapSet.delete(state.pending, {:shutdown, direction})})

        {tag, ^client} when tag in [:tcp_closed, :ssl_closed] ->
          relay(eof(state, :to_backend, tag))

        {tag, ^backend} when tag in [:tcp_closed, :ssl_closed] ->
          relay(eof(state, :to_client, tag))

        {tag, ^client, _} when tag in [:tcp_error, :ssl_error] ->
          interrupt(state, :caller_closed)

        {tag, _, _} when tag in [:tcp_error, :ssl_error] ->
          interrupt(state, :backend)

        {:gateway_stopped, _, reason} ->
          interrupt(state, reason)

        {:DOWN, _, :process, _, _} ->
          interrupt(state, :killed)
      after
        remaining(state) -> interrupt(state, expired(state))
      end
    end

    defp receive_bytes(state, direction, bytes) do
      case enqueue(state, direction, bytes) do
        {:ok, state} -> relay(state)
        :error -> interrupt(state, :limit)
      end
    end

    defp enqueue(state, _, <<>>), do: {:ok, state}

    defp enqueue(state, direction, bytes) do
      # Bytes read from the caller count even when a limit refuses them.
      if direction == :to_backend,
        do: Exchange.request_bytes(state.exchange, byte_size(bytes))

      {key, maximum} =
        if direction == :to_backend,
          do: {:written, state.gateway.max_request_bytes},
          else: {:received, state.gateway.max_response_bytes}

      total = Map.fetch!(state, key) + byte_size(bytes)

      if total <= maximum and not MapSet.member?(state.pending, direction) do
        send(Map.fetch!(state.writers, direction), {:write, direction, bytes})

        {:ok,
         state
         |> Map.put(key, total)
         |> Map.put(:pending, MapSet.put(state.pending, direction))
         |> Map.put(:last_activity, now())}
      else
        :error
      end
    end

    defp arm(state, :to_backend) do
      if not state.client_closed, do: setopts(state.frontend, active: :once)
      state
    end

    defp arm(state, :to_client) do
      if not state.backend_closed, do: setopts(state.backend, active: :once)
      state
    end

    defp eof(state, direction, tag) do
      send(Map.fetch!(state.writers, direction), {:shutdown, direction})

      state = %{
        state
        | pending: MapSet.put(state.pending, {:shutdown, direction}),
          drain_deadline:
            state.drain_deadline ||
              now() + min(state.gateway.connection.timeout, state.gateway.idle_timeout)
      }

      state =
        if direction == :to_backend,
          do: %{state | client_closed: true},
          else: %{state | backend_closed: true}

      # TLS close_notify closes both halves in OTP. Unix/TCP keeps the opposite
      # direction available until its EOF or the finite drain deadline.
      if tag == :ssl_closed, do: %{state | client_closed: true, backend_closed: true}, else: state
    end

    defp interrupt(state, reason) do
      Exchange.interrupt(state.exchange, reason)
      :ok
    end

    # A failed write names the side that could not be written.
    defp side(:to_client), do: :caller_closed
    defp side(:to_backend), do: :backend

    defp expired(state), do: if(now() >= state.deadline, do: :lifetime, else: :idle)

    defp remaining(state) do
      deadlines =
        [state.deadline, state.last_activity + state.gateway.idle_timeout, state.drain_deadline]
        |> Enum.reject(&is_nil/1)

      max(0, Enum.min(deadlines) - now())
    end

    defp setopts(%{transport: :gen_tcp, socket: socket}, opts), do: :inet.setopts(socket, opts)

    defp setopts(%{transport: transport, socket: socket}, opts),
      do: transport.setopts(socket, opts)

    defp close(backend), do: backend.transport.close(backend.socket)

    defp dispatch_outcome(dispatch),
      do: if(:atomics.get(dispatch, 1) == 0, do: :not_sent, else: :sent)

    defp normalize_failure(error, outcome \\ :not_sent)
    defp normalize_failure(%Failure{} = failure, :not_sent), do: failure
    defp normalize_failure(%Failure{} = failure, outcome), do: %{failure | outcome: outcome}
    defp normalize_failure(_, outcome), do: failure(503, outcome, :not_ready)

    defp failure(status, outcome, reason),
      do: Failure.new(status, "Native raw upgrade failed", outcome, reason: reason)

    defp now, do: System.monotonic_time(:millisecond)
    def format_status(status), do: Redaction.status(status, :private_gateway_raw_relay)
  end
end
