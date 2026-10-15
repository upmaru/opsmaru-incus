defmodule Opsmaru.Incus.WebSocket do
  @moduledoc """
  Bounded owner-monitored native WebSocket channel. Messages are pulled, never
  accumulated in the caller mailbox. Overflow, framing failures and deadlines
  are visible; local closure never implies backend cancellation.
  """
  use GenServer
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Context, Error, HTTP, Response, Transport, Upgrade}
  alias Opsmaru.Incus.HTTP.Response, as: HTTPResponse
  defstruct [:pid, :ref]

  def open(client, path, opts \\ []) do
    with :ok <- options(opts),
         :ok <- Context.authorize(client.context, client.connection),
         {:ok, path} <- Incus.request_path(client.connection, path) do
      ref = make_ref()

      channel_args =
        {client.connection, path, self(), ref, Keyword.get(opts, :headers, []),
         client.context.identity}

      case GenServer.start(__MODULE__, channel_args, timeout: client.connection.timeout + 100) do
        {:ok, pid} ->
          {:ok, %__MODULE__{pid: pid, ref: ref}}

        {:error, %Error{} = error} ->
          response =
            if match?(%Response{}, error.response),
              do: %{
                error.response
                | connection: client.connection,
                  identity: client.context.identity
              },
              else: error.response

          {:error, %{error | response: response}}

        {:error, kind} when kind in [:overflow, :frame_limit, :invalid_frame] ->
          {:error, %Error{kind: kind}}

        _ ->
          {:error, %Error{kind: :websocket_upgrade}}
      end
    else
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  def recv(channel, timeout \\ 5_000) when is_integer(timeout) and timeout in 1..3_600_000,
    do: call(channel, {:recv, timeout}, timeout + 100)

  def send_frame(channel, frame), do: call(channel, {:send, frame}, 3_600_100)
  def close(channel), do: call(channel, :close, 5_000)

  @doc false
  def close_owned(channels) do
    deadline = now() + 100
    requests = Enum.map(channels, &{&1.pid, :gen_server.send_request(&1.pid, :close)})

    # Send all graceful closes first. A blocked write must not give each channel
    # a fresh timeout or keep an owner's local resources alive indefinitely.
    for {pid, request} <- requests do
      :gen_server.wait_response(request, max(0, deadline - now()))
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end

    :ok
  end

  @doc "Native DoWebsocket handshake metadata while the local channel is alive."
  def upgrade_response(channel), do: call(channel, :upgrade_response, 5_000)

  defp options(opts) do
    if Keyword.keyword?(opts) and length(opts) <= 1 and Keyword.keys(opts) -- [:headers] == [] and
         HTTP.valid_headers?(Keyword.get(opts, :headers, [])) and
         Enum.all?(Keyword.get(opts, :headers, []), fn {name, _} ->
           not String.starts_with?(name, "sec-websocket-")
         end), do: :ok, else: {:error, :invalid_websocket_options}
  end

  defp call(channel, message, timeout) do
    GenServer.call(channel.pid, message, timeout)
  catch
    :exit, _ -> {:error, %Error{kind: :channel_closed}}
  end

  @impl true
  def init({connection, path, owner, ref, request_headers, identity}) do
    Transport.watch_owner(owner, connection.request_context)
    deadline = now() + connection.timeout

    case Transport.open(connection, deadline) do
      {:ok, conn} ->
        scheme = if connection.transport == :unix, do: :ws, else: :wss

        result =
          with {:ok, conn, request} <-
                 Mint.WebSocket.upgrade(
                   scheme,
                   conn,
                   path,
                   Transport.request_headers(connection, request_headers)
                 ),
               {:ok, conn, status, headers, initial} <-
                 Upgrade.receive_response(conn, request, deadline, connection.max_response_bytes),
               :ok <- accepted_upgrade(status, headers, initial),
               {:ok, conn, websocket} <-
                 Mint.WebSocket.new(conn, request, status, headers, mode: :passive) do
            state = %{
              connection: connection,
              conn: conn,
              websocket: websocket,
              request: request,
              owner: owner,
              ref: ref,
              monitor: Process.monitor(owner),
              deadline: now() + connection.stream_timeout,
              timer: Process.send_after(self(), :lifetime, connection.stream_timeout),
              queue: :queue.new(),
              queued: 0,
              pending: nil,
              received: 0,
              written: 0,
              closed: false,
              upgrade_response: %HTTPResponse{
                status: status,
                headers: headers,
                body: nil,
                connection: connection,
                identity: identity
              }
            }

            case decode(state, IO.iodata_to_binary(Enum.reverse(initial))) do
              {:ok, state} -> rearm(state)
              error -> error
            end
          end

        case result do
          {:ok, state} ->
            {:ok, state}

          {:error, kind} ->
            Mint.HTTP.close(conn)
            {:stop, kind}

          _ ->
            Mint.HTTP.close(conn)
            {:stop, :upgrade_failed}
        end

      _ ->
        {:stop, :connection_failed}
    end
  rescue
    _ -> {:stop, :upgrade_failed}
  end

  defp accepted_upgrade(101, _, _), do: :ok

  defp accepted_upgrade(status, headers, data),
    do: Upgrade.rejected(status, headers, data, :websocket_upgrade)

  @impl true
  def handle_call(:upgrade_response, _, state), do: {:reply, {:ok, state.upgrade_response}, state}

  def handle_call({:recv, _}, _, %{closed: true, queued: 0} = state), do: {:reply, :eof, state}

  def handle_call({:recv, _}, _, %{pending: pending} = state) when not is_nil(pending),
    do: {:reply, {:error, %Error{kind: :reader_busy}}, state}

  def handle_call({:recv, timeout}, from, state) do
    case :queue.out(state.queue) do
      {{:value, frame}, queue} ->
        {:reply, {:ok, frame}, %{state | queue: queue, queued: state.queued - 1}}

      {:empty, _} ->
        tag = make_ref()

        timer =
          Process.send_after(self(), {:read_timeout, tag}, min(timeout, state.connection.timeout))

        {:noreply, %{state | pending: {from, tag, timer}}}
    end
  end

  def handle_call({:send, _}, _, %{closed: true} = state),
    do: {:reply, {:error, %Error{kind: :channel_closed}}, state}

  def handle_call({:send, frame}, _, state) do
    size = frame_size(frame)

    if size <= state.connection.max_response_bytes and
         state.written + size <= state.connection.max_stream_bytes do
      case encode(state, frame) do
        {:ok, state} -> {:reply, :ok, %{state | written: state.written + size}}
        {:error, kind} -> stop_error_reply(state, kind)
      end
    else
      stop_error_reply(state, :frame_limit)
    end
  end

  def handle_call(:close, _, state) do
    encode(state, :close)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(:lifetime, state), do: stop_error(state, :deadline)

  def handle_info({:read_timeout, tag}, %{pending: {from, tag, _}} = state) do
    GenServer.reply(from, {:error, %Error{kind: :deadline}})
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({:read_timeout, _}, state), do: {:noreply, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        result =
          Enum.reduce_while(responses, {:ok, %{state | conn: conn}}, fn
            {:data, _, bytes}, {:ok, state} ->
              case decode(state, bytes) do
                {:ok, state} -> {:cont, {:ok, state}}
                error -> {:halt, error}
              end

            {:done, _}, {:ok, %{closed: true} = state} ->
              {:cont, {:ok, state}}

            {:done, _}, _ ->
              {:halt, {:error, :channel_io}}

            _, acc ->
              {:cont, acc}
          end)

        case result do
          {:ok, state} ->
            state = deliver(state)

            case rearm(state) do
              {:ok, state} -> {:noreply, state}
              _ -> stop_error(state, :channel_io)
            end

          {:error, kind} ->
            stop_error(%{state | conn: conn}, kind)
        end

      :unknown ->
        {:noreply, state}

      {:error, conn, _, _} ->
        Mint.HTTP.close(conn)

        if state.closed,
          do: {:noreply, deliver(%{state | conn: conn})},
          else: stop_error(%{state | conn: conn}, :channel_io)
    end
  end

  defp decode(state, bytes) do
    if state.received + byte_size(bytes) > state.connection.max_stream_bytes or
         byte_size(state.websocket.buffer) + byte_size(bytes) >
           state.connection.max_response_bytes + 65_536 do
      {:error, :frame_limit}
    else
      with {:ok, websocket, frames} <- Mint.WebSocket.decode(state.websocket, bytes),
           true <-
             :erlang.external_size(websocket.fragment) + byte_size(websocket.buffer) <=
               state.connection.max_response_bytes + 512 do
        Enum.reduce_while(
          frames,
          {:ok, %{state | websocket: websocket, received: state.received + byte_size(bytes)}},
          &receive_frame/2
        )
      else
        _ -> {:error, :invalid_frame}
      end
    end
  end

  defp receive_frame({:ping, payload}, {:ok, state}) do
    case encode(state, {:pong, payload}) do
      {:ok, state} -> {:cont, {:ok, state}}
      {:error, kind} -> {:halt, {:error, kind}}
    end
  end

  defp receive_frame({:pong, _}, acc) do
    {:cont, acc}
  end

  defp receive_frame({:close, _, _}, {:ok, state}) do
    {:cont, {:ok, remote_closed(state)}}
  end

  defp receive_frame({:error, _}, _) do
    {:halt, {:error, :invalid_frame}}
  end

  defp receive_frame(frame, {:ok, state}) do
    if frame_size(frame) <= state.connection.max_response_bytes and
         state.queued < state.connection.queue_limit,
       do:
         {:cont, {:ok, %{state | queue: :queue.in(frame, state.queue), queued: state.queued + 1}}},
       else: {:halt, {:error, :overflow}}
  end

  defp remote_closed(state) do
    unless state.closed, do: send(state.owner, {state.ref, :eof})
    %{state | closed: true}
  end

  defp encode(state, frame) do
    with true <- now() < state.deadline,
         {:ok, websocket, bytes} <- Mint.WebSocket.encode(state.websocket, frame),
         :ok <- write_budget(state),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request, bytes) do
      {:ok, %{state | websocket: websocket, conn: conn}}
    else
      false -> {:error, :deadline}
      {:error, :deadline} -> {:error, :deadline}
      {:error, _, %Mint.TransportError{reason: :timeout}} -> {:error, :deadline}
      _ -> {:error, :channel_io}
    end
  end

  defp write_budget(state) do
    remaining = state.deadline - now()

    if remaining > 0 do
      options = [send_timeout: min(state.connection.timeout, remaining), send_timeout_close: true]
      socket = Mint.HTTP.get_socket(state.conn)

      if state.connection.transport == :unix,
        do: :inet.setopts(socket, options),
        else: :ssl.setopts(socket, options)
    else
      {:error, :deadline}
    end
  end

  defp frame_size({kind, bytes}) when kind in [:text, :binary, :ping, :pong] and is_binary(bytes),
    do: byte_size(bytes)

  defp frame_size(:close), do: 0
  defp frame_size(_), do: 1_073_741_825
  defp deliver(%{pending: nil} = state), do: state

  defp deliver(%{closed: true, queued: 0, pending: {from, _, timer}} = state) do
    Process.cancel_timer(timer)
    GenServer.reply(from, :eof)
    %{state | pending: nil}
  end

  defp deliver(%{queued: 0} = state), do: state

  defp deliver(state) do
    {{:value, frame}, queue} = :queue.out(state.queue)
    {from, _, timer} = state.pending
    Process.cancel_timer(timer)
    GenServer.reply(from, {:ok, frame})
    %{state | queue: queue, queued: state.queued - 1, pending: nil}
  end

  defp rearm(%{closed: true} = state) do
    Mint.HTTP.close(state.conn)
    {:ok, state}
  end

  defp rearm(state) do
    with {:ok, conn} <- Mint.HTTP.set_mode(state.conn, :active), do: {:ok, %{state | conn: conn}}
  end

  defp stop_error(state, kind) do
    error = %Error{kind: kind}
    send(state.owner, {state.ref, :error, error})
    if state.pending, do: GenServer.reply(elem(state.pending, 0), {:error, error})
    {:stop, :normal, state}
  end

  defp stop_error_reply(state, kind) do
    {:stop, :normal, state} = stop_error(state, kind)
    {:stop, :normal, {:error, %Error{kind: kind}}, state}
  end

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    Mint.HTTP.close(state.conn)
  end

  @impl true
  def format_status(status), do: %{status | state: :private_native_websocket}
  defp now, do: System.monotonic_time(:millisecond)
end
