defmodule Opsmaru.Incus.WebSocket do
  @moduledoc """
  Bounded owner-monitored native WebSocket channel. Messages are pulled, never
  accumulated in the caller mailbox. Overflow, framing failures and deadlines
  are visible; local closure never implies backend cancellation.
  """
  use GenServer
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Error, Response, Transport}
  defstruct [:pid, :ref]

  def open(client, path) do
    with :ok <- Context.authorize(client.context, client.connection),
         {:ok, path} <- Incus.request_path(client.connection, path) do
      ref = make_ref()

      case GenServer.start(__MODULE__, {client.connection, path, self(), ref},
             timeout: client.connection.timeout + 100
           ) do
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

  defp call(channel, message, timeout) do
    GenServer.call(channel.pid, message, timeout)
  catch
    :exit, _ -> {:error, %Error{kind: :channel_closed}}
  end

  @impl true
  def init({connection, path, owner, ref}) do
    deadline = now() + connection.timeout

    with {:ok, conn} <- Transport.open(connection, deadline) do
      scheme = if connection.transport == :unix, do: :ws, else: :wss

      result =
        with {:ok, conn, request} <- Mint.WebSocket.upgrade(scheme, conn, path, []),
             {:ok, conn, status, headers, initial} <-
               handshake(conn, request, deadline, nil, [], [], connection.max_response_bytes),
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
            timer: Process.send_after(self(), :lifetime, connection.stream_timeout),
            queue: :queue.new(),
            queued: 0,
            pending: nil,
            received: 0,
            written: 0,
            closed: false
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
    else
      _ -> {:stop, :connection_failed}
    end
  rescue
    _ -> {:stop, :upgrade_failed}
  end

  defp handshake(conn, request, deadline, status, headers, data, limit) do
    case Mint.HTTP.recv(conn, 0, remaining(deadline)) do
      {:ok, conn, responses} ->
        {status, headers, data, done} =
          Enum.reduce(responses, {status, headers, data, false}, fn
            {:status, ^request, value}, {_, headers, data, done} ->
              {value, headers, data, done}

            {:headers, ^request, value}, {status, _, data, done} ->
              {status, value, data, done}

            {:data, ^request, value}, {status, headers, data, done} ->
              {status, headers, [value | data], done}

            {:done, ^request}, {status, headers, data, _} ->
              {status, headers, data, true}

            _, acc ->
              acc
          end)

        cond do
          IO.iodata_length(data) > limit -> {:error, :frame_limit}
          status == 101 and headers != [] -> {:ok, conn, status, headers, data}
          done -> {:ok, conn, status, headers, data}
          true -> handshake(conn, request, deadline, status, headers, data, limit)
        end

      _ ->
        {:error, :handshake}
    end
  end

  defp accepted_upgrade(101, _, _), do: :ok

  defp accepted_upgrade(status, headers, data) do
    case Response.decode(IO.iodata_to_binary(Enum.reverse(data)), status, Map.new(headers)) do
      {:ok, response} ->
        {:error,
         %Error{
           kind:
             if(response.type == "error" or status >= 400, do: :native, else: :websocket_upgrade),
           http_status: status,
           error_code: response.error_code,
           message: response.error,
           response: response,
           operation: response.operation
         }}

      _ ->
        {:error, %Error{kind: :websocket_upgrade, http_status: status}}
    end
  end

  @impl true
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
        _ -> {:stop, :normal, {:error, %Error{kind: :channel_io}}, state}
      end
    else
      {:stop, :normal, {:error, %Error{kind: :frame_limit}}, state}
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

            {:done, _}, {:ok, state} ->
              {:cont, {:ok, %{state | closed: true}}}

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
        state = %{state | conn: conn, closed: true}

        if state.pending do
          {from, _, timer} = state.pending
          Process.cancel_timer(timer)
          GenServer.reply(from, :eof)
        end

        {:noreply, %{state | pending: nil}}
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
          fn
            {:ping, payload}, {:ok, state} ->
              case encode(state, {:pong, payload}) do
                {:ok, state} -> {:cont, {:ok, state}}
                _ -> {:halt, {:error, :channel_io}}
              end

            {:pong, _}, acc ->
              {:cont, acc}

            {:close, _, _}, {:ok, state} ->
              {:cont, {:ok, %{state | closed: true}}}

            {:error, _}, _ ->
              {:halt, {:error, :invalid_frame}}

            frame, {:ok, state} ->
              if frame_size(frame) <= state.connection.max_response_bytes and
                   state.queued < state.connection.queue_limit,
                 do:
                   {:cont,
                    {:ok,
                     %{state | queue: :queue.in(frame, state.queue), queued: state.queued + 1}}},
                 else: {:halt, {:error, :overflow}}
          end
        )
      else
        _ -> {:error, :invalid_frame}
      end
    end
  end

  defp encode(state, frame) do
    with {:ok, websocket, bytes} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request, bytes),
         do: {:ok, %{state | websocket: websocket, conn: conn}}
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

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    Mint.HTTP.close(state.conn)
  end

  @impl true
  def format_status(status), do: %{status | state: :private_native_websocket}
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now())
end
