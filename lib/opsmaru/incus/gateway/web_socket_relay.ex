if Code.ensure_loaded?(Plug.Conn) and Code.ensure_loaded?(:cowboy_websocket) do
  defmodule Opsmaru.Incus.Gateway.WebSocketRelay do
    @moduledoc false
    # One owner-bound backend connection, passive reads and one acknowledged
    # frontend batch. Never replay HTTP, acquire a replacement grant or DELETE
    # a native operation. Lease and watchdog interrupt blocked socket I/O.
    use GenServer
    alias Opsmaru.Incus.Gateway.{Admission, Failure, Headers, Lease, Policy, UpgradeResponse}
    alias Opsmaru.Incus.{Redaction, Transport}

    def open(gateway, request, admitted, owner, headers) do
      args = {gateway, request, admitted, owner, self(), headers}

      case GenServer.start(__MODULE__, args, timeout: gateway.connection.timeout + 100) do
        {:ok, pid} ->
          case GenServer.call(pid, :response_headers) do
            {:ok, response_headers} -> {:ok, pid, response_headers}
            error -> error
          end

        {:error, {:http, status, headers, body}} ->
          {:http, status, headers, body}

        {:error, %Failure{} = failure} ->
          {:error, failure}

        _ ->
          {:error, Failure.new(502, "Backend WebSocket negotiation failed", :sent)}
      end
    catch
      :exit, _ -> {:error, Failure.new(502, "Backend WebSocket negotiation ended", :sent)}
    end

    def commit(pid), do: call(pid, :commit)
    def attach(pid), do: call(pid, {:attach, self()})
    def ack(pid), do: GenServer.cast(pid, :ack)
    def send_frame(pid, frame), do: call(pid, {:frame, frame})
    def close(pid, frame \\ :close), do: call(pid, {:close, frame})

    defp call(pid, message) do
      GenServer.call(pid, message, :infinity)
    catch
      :exit, _ -> :closed
    end

    @impl true
    def init({gateway, request, admitted, owner, handshake_owner, headers}) do
      case Admission.transfer(admitted.slot, self()) do
        {:ok, slot} ->
          admitted = %{admitted | slot: slot}
          lease = Lease.start(gateway, request, admitted, fn -> Process.exit(owner, :kill) end)
          clock = :atomics.new(1, signed: true)
          :atomics.put(clock, 1, now())
          deadline = now() + gateway.max_lifetime

          watchdog =
            watch(
              owner,
              handshake_owner,
              clock,
              gateway.idle_timeout,
              deadline,
              min(50, div(gateway.recheck_interval, 4))
            )

          state = %{
            gateway: gateway,
            request: request,
            admitted: admitted,
            owner: owner,
            monitor: Process.monitor(owner),
            lease: lease,
            watchdog: watchdog,
            clock: clock,
            deadline: deadline,
            conn: nil,
            socket: nil,
            ref: nil,
            response_headers: [],
            pending: nil,
            attached: false,
            received: 0,
            written: 0,
            writer: nil,
            writer_monitor: nil,
            write_queue: :queue.new(),
            queued_bytes: 0,
            writing: nil,
            closing: nil
          }

          case negotiate(state, headers) do
            {:ok, state} ->
              {:ok, start_writer(state)}

            {:error, failure, state} ->
              cleanup(state)
              {:stop, failure}
          end

        _ ->
          {:stop, Failure.new(503, "Gateway admission ended", :not_sent)}
      end
    end

    defp negotiate(state, headers) do
      connection = state.gateway.connection
      deadline = min(state.deadline, now() + min(connection.timeout, state.gateway.idle_timeout))

      with :ok <- live(state),
           {:ok, conn} <- Transport.open(connection, deadline) do
        target =
          state.request.path <>
            if(state.request.query == "", do: "", else: "?" <> state.request.query)

        scheme = if connection.transport == :https, do: :wss, else: :ws
        headers = Enum.reject(headers, fn {name, _} -> name == "x-incus-authenticated" end)

        with :ok <- live(state),
             {:ok, conn, ref} <-
               Mint.WebSocket.upgrade(
                 scheme,
                 conn,
                 target,
                 Transport.request_headers(connection, headers)
               ),
             {:ok, conn, status, response, initial} <-
               UpgradeResponse.receive_response(
                 conn,
                 ref,
                 deadline,
                 min(
                   state.gateway.max_response_bytes,
                   min(connection.max_response_bytes, 1_048_576)
                 )
               ),
             {:ok, forwarded} <- Headers.response(response),
             :ok <- live(state) do
          state = %{state | conn: conn, ref: ref}

          forwarded =
            Enum.reject(forwarded, fn {name, _} ->
              name in ["sec-websocket-accept", "content-length"]
            end)

          if status != 101 do
            body = IO.iodata_to_binary(Enum.reverse(initial))
            {:error, {:http, status, forwarded, body}, state}
          else
            accepted(state, status, response, initial, forwarded)
          end
        else
          _ -> {:error, failure("Backend WebSocket negotiation failed"), %{state | conn: conn}}
        end
      else
        _ -> {:error, Failure.new(502, "Backend is unavailable", :not_sent), state}
      end
    end

    defp accepted(state, status, response, initial, forwarded) do
      with false <- List.keymember?(response, "sec-websocket-protocol", 0),
           false <- List.keymember?(response, "sec-websocket-extensions", 0),
           {:ok, conn, socket} <-
             Mint.WebSocket.new(state.conn, state.ref, status, response, mode: :passive) do
        state = %{state | conn: conn, socket: socket, response_headers: forwarded}

        case decode(state, IO.iodata_to_binary(Enum.reverse(initial))) do
          {:ok, state, frames} -> {:ok, %{state | pending: frames}}
          _ -> {:error, failure("Backend WebSocket frames exceed the limit"), state}
        end
      else
        _ -> {:error, failure("Backend WebSocket negotiation failed"), state}
      end
    end

    @impl true
    def handle_call(:response_headers, _, state) do
      if live(state) == :ok,
        do: {:reply, {:ok, state.response_headers}, state},
        else: {:stop, :normal, {:error, failure("Gateway authorization ended")}, state}
    end

    def handle_call(:commit, _, state) do
      if live(state) == :ok do
        ref = make_ref()
        send(state.watchdog, {:committed, self(), ref})

        receive do
          {^ref, :committed} -> {:reply, :ok, state}
        after
          100 -> {:stop, :normal, :closed, state}
        end
      else
        {:stop, :normal, :closed, state}
      end
    end

    def handle_call({:attach, owner}, _, %{owner: owner} = state) do
      if live(state) == :ok do
        ref = make_ref()
        send(state.watchdog, {:attached, self(), ref})

        receive do
          {^ref, :attached} ->
            send(self(), :deliver)
            {:reply, :ok, %{state | attached: true}}
        after
          100 -> {:stop, :normal, :closed, state}
        end
      else
        {:stop, :normal, :closed, state}
      end
    end

    def handle_call({:frame, frame}, _, state) do
      size = frame_size(frame)

      if live(state) == :ok and size <= state.gateway.connection.max_response_bytes and
           state.written + size <= state.gateway.max_request_bytes do
        case enqueue(state, frame) do
          {:ok, state} ->
            touch(state)
            {:reply, :ok, %{state | written: state.written + size}}

          _ ->
            stop_reply(state, "Gateway WebSocket queue exceeded")
        end
      else
        stop_reply(state, "Gateway WebSocket limit reached")
      end
    end

    def handle_call({:close, frame}, from, state) do
      case enqueue(state, frame) do
        {:ok, state} -> {:noreply, %{state | closing: from}}
        _ -> {:stop, :normal, :ok, state}
      end
    end

    @impl true
    def handle_cast(:ack, state) do
      send(self(), :read)
      {:noreply, %{state | pending: nil}}
    end

    @impl true
    def handle_info({:gateway_ws_written, writer, result}, %{writer: writer} = state) do
      if result == :ok do
        state = %{state | writing: nil}

        case :queue.out(state.write_queue) do
          {{:value, frame}, queue} ->
            state = %{
              state
              | write_queue: queue,
                queued_bytes: state.queued_bytes - frame_size(frame)
            }

            {:noreply, dispatch_write(state, frame)}

          {:empty, _} when not is_nil(state.closing) ->
            GenServer.reply(state.closing, :ok)
            {:stop, :normal, state}

          {:empty, _} ->
            {:noreply, state}
        end
      else
        stop(state, 1011, "Backend WebSocket write failed")
      end
    end

    def handle_info(:deliver, %{pending: frames} = state) when is_list(frames) do
      if frames == [] do
        send(self(), :read)
        {:noreply, %{state | pending: nil}}
      else
        send(state.owner, {:gateway_ws_frames, self(), frames})
        {:noreply, state}
      end
    end

    def handle_info(:read, %{pending: nil} = state) do
      if live(state) == :ok do
        read(state)
      else
        stop(state, 1008, "Gateway authorization ended")
      end
    end

    def handle_info(:read, state), do: {:noreply, state}

    def handle_info({:gateway_stopped, _, _}, state),
      do: stop(state, 1008, "Gateway authorization ended")

    def handle_info({:DOWN, ref, :process, owner, _}, %{monitor: ref, owner: owner} = state),
      do: {:stop, :normal, state}

    def handle_info(
          {:DOWN, ref, :process, writer, _},
          %{writer_monitor: ref, writer: writer} = state
        ),
        do: stop(state, 1011, "Backend WebSocket writer ended")

    def handle_info(_, state), do: {:noreply, state}

    defp read(state) do
      case Mint.WebSocket.recv(state.conn, 0, 20) do
        {:ok, conn, responses} ->
          state = %{state | conn: conn}
          bytes = for {:data, _, data} <- responses, into: <<>>, do: data

          case decode(state, bytes) do
            {:ok, state, frames} ->
              if byte_size(bytes) > 0, do: touch(state)
              send(self(), :deliver)
              {:noreply, %{state | pending: frames}}

            _ ->
              stop(state, 1009, "Gateway WebSocket limit or framing error")
          end

        {:error, conn, reason, _}
        when reason == :timeout or reason == %Mint.TransportError{reason: :timeout} ->
          send(self(), :read)
          {:noreply, %{state | conn: conn}}

        _ ->
          stop(state, 1011, "Backend WebSocket ended")
      end
    end

    defp decode(state, bytes) do
      limit = state.gateway.connection.max_response_bytes

      with true <- state.received + byte_size(bytes) <= state.gateway.max_response_bytes,
           true <- byte_size(state.socket.buffer) + byte_size(bytes) <= limit + 65_536,
           {:ok, socket, frames} <- Mint.WebSocket.decode(state.socket, bytes),
           true <-
             :erlang.external_size(socket.fragment) + byte_size(socket.buffer) <= limit + 512,
           true <- length(frames) <= state.gateway.connection.queue_limit,
           true <- Enum.all?(frames, &(frame_size(&1) <= limit)) do
        state = %{state | socket: socket, received: state.received + byte_size(bytes)}
        controls(state, frames, [])
      else
        _ -> :error
      end
    end

    defp controls(state, [], frames), do: {:ok, state, Enum.reverse(frames)}

    defp controls(state, [{:ping, payload} | tail], frames) do
      case enqueue(state, {:pong, payload}) do
        {:ok, state} -> controls(state, tail, frames)
        _ -> :error
      end
    end

    defp controls(state, [{:pong, _} | tail], frames), do: controls(state, tail, frames)
    defp controls(_state, [{:error, _} | _], _), do: :error

    defp controls(state, [{:close, nil, _} | _], frames),
      do: {:ok, state, Enum.reverse([:close | frames])}

    defp controls(state, [{:close, code, reason} | _], frames),
      do: {:ok, state, Enum.reverse([{:close, code, reason} | frames])}

    defp controls(state, [frame | tail], frames), do: controls(state, tail, [frame | frames])

    defp enqueue(%{writer: nil} = state, frame), do: encode(state, frame)
    defp enqueue(%{writing: nil} = state, frame), do: {:ok, dispatch_write(state, frame)}

    defp enqueue(state, frame) do
      if :queue.len(state.write_queue) < state.gateway.connection.queue_limit and
           state.queued_bytes + frame_size(frame) <= state.gateway.connection.max_response_bytes do
        {:ok,
         %{
           state
           | write_queue: :queue.in(frame, state.write_queue),
             queued_bytes: state.queued_bytes + frame_size(frame)
         }}
      else
        :error
      end
    end

    defp dispatch_write(state, frame) do
      send(state.writer, {:write, frame})
      %{state | writing: frame_size(frame)}
    end

    defp start_writer(state) do
      relay = self()

      {writer, monitor} =
        spawn_monitor(fn ->
          Transport.watch_owner(relay)
          writer_loop(state, relay)
        end)

      %{state | writer: writer, writer_monitor: monitor}
    end

    defp writer_loop(state, relay) do
      receive do
        {:write, frame} ->
          case encode(state, frame) do
            {:ok, state} ->
              send(relay, {:gateway_ws_written, self(), :ok})
              writer_loop(state, relay)

            _ ->
              send(relay, {:gateway_ws_written, self(), :error})
          end
      end
    end

    defp encode(%{conn: nil}, _), do: :error

    defp encode(state, frame) do
      with :ok <- write_budget(state),
           {:ok, socket, bytes} <- Mint.WebSocket.encode(state.socket, frame),
           {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, bytes) do
        {:ok, %{state | conn: conn, socket: socket}}
      else
        _ -> :error
      end
    end

    defp write_budget(state) do
      timeout = min(state.gateway.idle_timeout, state.deadline - now())

      if timeout > 0 do
        options = [send_timeout: timeout, send_timeout_close: true]
        socket = Mint.HTTP.get_socket(state.conn)

        if state.gateway.connection.transport == :unix,
          do: :inet.setopts(socket, options),
          else: :ssl.setopts(socket, options)
      else
        :error
      end
    end

    defp watch(owner, handshake_owner, clock, idle, deadline, grace) do
      relay = self()

      spawn(fn ->
        handoff = {Process.monitor(handshake_owner), false, deadline, grace}

        watchdog(
          relay,
          owner,
          Process.monitor(relay),
          Process.monitor(owner),
          handoff,
          clock,
          idle,
          deadline
        )
      end)
    end

    defp watchdog(
           relay,
           owner,
           relay_ref,
           owner_ref,
           {handshake_ref, committed, handoff_deadline, grace} = handoff,
           clock,
           idle,
           deadline
         ) do
      left = min(min(deadline, handoff_deadline) - now(), :atomics.get(clock, 1) + idle - now())

      if left <= 0 do
        send(owner, {:gateway_ws_close, relay, 1008, "Gateway WebSocket deadline"})
        Process.exit(relay, :kill)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _} -> :ok
        after
          grace -> Process.exit(owner, :kill)
        end
      else
        receive do
          {:committed, sender, ref} ->
            send(sender, {ref, :committed})
            handoff = {handshake_ref, true, min(deadline, now() + 1_000), grace}
            watchdog(relay, owner, relay_ref, owner_ref, handoff, clock, idle, deadline)

          {:attached, sender, ref} ->
            if handshake_ref, do: Process.demonitor(handshake_ref, [:flush])
            send(sender, {ref, :attached})

            watchdog(
              relay,
              owner,
              relay_ref,
              owner_ref,
              {nil, true, deadline, grace},
              clock,
              idle,
              deadline
            )

          {:DOWN, ^handshake_ref, :process, _, :normal} when committed ->
            watchdog(
              relay,
              owner,
              relay_ref,
              owner_ref,
              {nil, true, handoff_deadline, grace},
              clock,
              idle,
              deadline
            )

          {:DOWN, ^handshake_ref, :process, _, _} when not is_nil(handshake_ref) ->
            Process.exit(relay, :kill)
            Process.exit(owner, :kill)

          {:DOWN, ^relay_ref, :process, ^relay, _} ->
            finish_front(owner, owner_ref, grace)

          {:DOWN, ^owner_ref, :process, ^owner, _} ->
            Process.exit(relay, :kill)
        after
          min(left, 25) ->
            watchdog(relay, owner, relay_ref, owner_ref, handoff, clock, idle, deadline)
        end
      end
    end

    defp finish_front(owner, owner_ref, grace) do
      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _} -> :ok
      after
        grace -> Process.exit(owner, :kill)
      end
    end

    defp live(state) do
      with true <- now() < state.deadline,
           :ok <- Lease.check(state.lease),
           :ok <- Policy.recheck(state.gateway, state.request, state.admitted.grant),
           do: :ok,
           else: (_ -> :error)
    end

    defp touch(state), do: :atomics.put(state.clock, 1, now())

    defp frame_size({kind, payload}) when kind in [:text, :binary, :ping, :pong],
      do: byte_size(payload)

    defp frame_size({:close, _, reason}), do: byte_size(reason)
    defp frame_size(:close), do: 0
    defp frame_size(_), do: 1_099_511_627_777
    defp failure(message), do: Failure.new(502, message, :sent)

    defp stop(state, code, reason) do
      send(state.owner, {:gateway_ws_close, self(), code, reason})
      {:stop, :normal, state}
    end

    defp stop_reply(state, reason) do
      send(state.owner, {:gateway_ws_close, self(), 1011, reason})
      {:stop, :normal, :closed, state}
    end

    @impl true
    def terminate(_, state), do: cleanup(state)

    defp cleanup(state) do
      if state.attached,
        do:
          spawn(fn ->
            finish_front(
              state.owner,
              Process.monitor(state.owner),
              min(50, div(state.gateway.recheck_interval, 4))
            )
          end)

      if state.writer, do: Process.exit(state.writer, :kill)
      if state.conn, do: Mint.HTTP.close(state.conn)
      Lease.stop(state.lease)
      Process.exit(state.watchdog, :kill)
      Policy.release(state.admitted)
    end

    @impl true
    def format_status(status), do: Redaction.status(status, :private_gateway_websocket)
    defp now, do: System.monotonic_time(:millisecond)
  end
end
