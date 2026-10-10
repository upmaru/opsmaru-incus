defmodule Opsmaru.Incus.RawChannel do
  @moduledoc """
  Owner-monitored native SFTP/NBD duplex byte channel. No WebSocket framing.

  A pull reader and bounded inbound queue expose backpressure; overflow is
  visible. Read EOF leaves the write direction usable. Lifetime, chunks, byte
  totals and every blocking socket write are bounded. Closing the local channel
  never cancels an operation or owns host/Incus lifecycle.
  """
  use GenServer
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error}
  defstruct [:pid, :ref]

  def open(client, path, protocol) when protocol in ["sftp", "nbd"] do
    with :ok <- Context.authorize(client.context, client.connection),
         {:ok, path} <- Incus.request_path(client.connection, path) do
      ref = make_ref()

      case GenServer.start(__MODULE__, {client.connection, path, protocol, self(), ref},
             timeout: client.connection.timeout + 100
           ) do
        {:ok, pid} -> {:ok, %__MODULE__{pid: pid, ref: ref}}
        {:error, _} -> {:error, %Error{kind: :upgrade_failed}}
      end
    else
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  def recv(channel, timeout \\ 5_000) when is_integer(timeout) and timeout in 1..3_600_000,
    do: call(channel, {:recv, timeout}, timeout + 100)

  def send_data(channel, bytes), do: call(channel, {:send, bytes}, 3_600_100)
  def shutdown_write(channel), do: call(channel, :shutdown_write, 3_600_100)
  def close(channel), do: call(channel, :close, 5_000)

  defp call(channel, message, timeout) do
    GenServer.call(channel.pid, message, timeout)
  catch
    :exit, _ -> {:error, %Error{kind: :channel_closed}}
  end

  @impl true
  def init({connection, path, protocol, owner, ref}) do
    deadline = now() + connection.timeout

    with {:ok, transport, socket} <- connect(connection, deadline) do
      result = handshake(transport, socket, connection, path, protocol, deadline)

      case result do
        {:ok, initial} ->
          monitor = Process.monitor(owner)
          timer = Process.send_after(self(), :lifetime, connection.stream_timeout)

          state = %{
            connection: connection,
            transport: transport,
            socket: socket,
            owner: owner,
            ref: ref,
            monitor: monitor,
            timer: timer,
            queue: :queue.new(),
            queued: 0,
            received: 0,
            written: 0,
            pending: nil,
            read_eof: false,
            write_eof: false
          }

          case enqueue(state, initial) do
            {:ok, state} ->
              rearm(state)
              {:ok, state}

            _ ->
              transport.close(socket)
              {:stop, :stream_limit}
          end

        _ ->
          transport.close(socket)
          {:stop, :upgrade_failed}
      end
    else
      _ -> {:stop, :connection_failed}
    end
  rescue
    _ -> {:stop, :upgrade_failed}
  end

  defp connect(%Connection{transport: :unix} = connection, deadline) do
    opts = [
      :binary,
      active: false,
      packet: :raw,
      exit_on_close: false,
      send_timeout: remaining(deadline),
      send_timeout_close: true,
      buffer: connection.max_chunk_bytes
    ]

    with {:ok, socket} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(connection.address)},
             0,
             opts,
             remaining(deadline)
           ),
         do: {:ok, :gen_tcp, socket}
  end

  defp connect(%Connection{transport: :https} = connection, deadline) do
    uri = connection.address

    opts =
      [
        :binary,
        active: false,
        packet: :raw,
        exit_on_close: false,
        send_timeout: remaining(deadline),
        send_timeout_close: true,
        buffer: connection.max_chunk_bytes,
        server_name_indication: String.to_charlist(uri.host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++ Connection.tls_options(connection)

    with {:ok, socket} <-
           :ssl.connect(String.to_charlist(uri.host), uri.port, opts, remaining(deadline)),
         do: {:ok, :ssl, socket}
  end

  defp handshake(transport, socket, connection, path, protocol, deadline) do
    host =
      if connection.transport == :unix,
        do: "unix.socket",
        else: connection.address.host <> ":" <> Integer.to_string(connection.address.port)

    with :ok <-
           transport.send(socket, [
             "GET ",
             path,
             " HTTP/1.1\r\nHost: ",
             host,
             "\r\nConnection: Upgrade\r\nUpgrade: ",
             protocol,
             "\r\n\r\n"
           ]),
         {:ok, head, initial} <- head(transport, socket, "", deadline) do
      [status | lines] = String.split(head, "\r\n")

      headers =
        Map.new(lines, fn line ->
          [key, value] = String.split(line, ":", parts: 2)
          {String.downcase(key), String.trim(value)}
        end)

      if String.starts_with?(status, "HTTP/1.1 101 ") and headers["upgrade"] == protocol and
           "upgrade" in String.split(String.downcase(headers["connection"] || ""), ~r/\s*,\s*/),
         do: {:ok, initial},
         else: {:error, :invalid_upgrade}
    end
  end

  defp head(transport, socket, bytes, deadline) do
    case :binary.split(bytes, "\r\n\r\n") do
      [header, initial] when byte_size(header) <= 65_536 ->
        {:ok, header, initial}

      [_] when byte_size(bytes) <= 65_536 ->
        with {:ok, next} <- transport.recv(socket, 0, remaining(deadline)),
             do: head(transport, socket, bytes <> next, deadline)

      _ ->
        {:error, :header_limit}
    end
  end

  @impl true
  def handle_call({:recv, _}, _from, %{read_eof: true, queued: 0} = state),
    do: {:reply, :eof, state}

  def handle_call({:recv, _}, _, %{pending: pending} = state) when not is_nil(pending),
    do: {:reply, {:error, %Error{kind: :reader_busy}}, state}

  def handle_call({:recv, timeout}, from, state) do
    case :queue.out(state.queue) do
      {{:value, bytes}, queue} ->
        state = %{state | queue: queue, queued: state.queued - 1}
        rearm(state)
        {:reply, {:ok, bytes}, state}

      {:empty, _} ->
        tag = make_ref()

        timer =
          Process.send_after(self(), {:read_timeout, tag}, min(timeout, state.connection.timeout))

        {:noreply, %{state | pending: {from, tag, timer}}}
    end
  end

  def handle_call({:send, bytes}, _, state) do
    cond do
      state.write_eof ->
        {:reply, {:error, %Error{kind: :write_closed}}, state}

      not is_binary(bytes) or byte_size(bytes) > state.connection.max_chunk_bytes or
          state.written + byte_size(bytes) > state.connection.max_stream_bytes ->
        fail(state, :stream_limit)

      true ->
        case state.transport.send(state.socket, bytes) do
          :ok -> {:reply, :ok, %{state | written: state.written + byte_size(bytes)}}
          _ -> fail(state, :channel_io)
        end
    end
  end

  def handle_call(:shutdown_write, _, state) do
    result = state.transport.shutdown(state.socket, :write)
    {:reply, result, %{state | write_eof: true}}
  end

  def handle_call(:close, _, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info({tag, socket, bytes}, %{socket: socket} = state) when tag in [:tcp, :ssl] do
    case enqueue(state, bytes) do
      {:ok, state} ->
        state = deliver(state)
        rearm(state)
        {:noreply, state}

      _ ->
        terminate_error(state, :overflow)
    end
  end

  def handle_info({tag, socket}, %{socket: socket} = state)
      when tag in [:tcp_closed, :ssl_closed] do
    state = %{state | read_eof: true}

    if state.pending do
      {from, _, timer} = state.pending
      Process.cancel_timer(timer)
      GenServer.reply(from, :eof)
    end

    {:noreply, %{state | pending: nil}}
  end

  def handle_info({tag, socket, _}, %{socket: socket} = state)
      when tag in [:tcp_error, :ssl_error], do: terminate_error(state, :channel_io)

  def handle_info({:read_timeout, tag}, %{pending: {from, tag, _}} = state) do
    GenServer.reply(from, {:error, %Error{kind: :deadline}})
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(:lifetime, state), do: terminate_error(state, :deadline)
  def handle_info(_, state), do: {:noreply, state}

  defp enqueue(state, <<>>), do: {:ok, state}

  defp enqueue(state, bytes) do
    chunks = chunks(bytes, state.connection.max_chunk_bytes)

    if state.received + byte_size(bytes) <= state.connection.max_stream_bytes and
         state.queued + length(chunks) <= state.connection.queue_limit do
      {:ok,
       %{
         state
         | queue: Enum.reduce(chunks, state.queue, &:queue.in/2),
           queued: state.queued + length(chunks),
           received: state.received + byte_size(bytes)
       }}
    else
      {:error, :overflow}
    end
  end

  defp chunks(<<>>, _), do: []

  defp chunks(bytes, maximum) do
    count = min(maximum, byte_size(bytes))
    <<chunk::binary-size(count), rest::binary>> = bytes
    [chunk | chunks(rest, maximum)]
  end

  defp deliver(%{pending: nil} = state), do: state

  defp deliver(state) do
    {{:value, bytes}, queue} = :queue.out(state.queue)
    {from, _, timer} = state.pending
    Process.cancel_timer(timer)
    GenServer.reply(from, {:ok, bytes})
    %{state | queue: queue, queued: state.queued - 1, pending: nil}
  end

  defp rearm(%{read_eof: false} = state) do
    if state.queued < state.connection.queue_limit, do: setopts(state, active: :once)
    :ok
  end

  defp rearm(_), do: :ok
  defp setopts(%{transport: :gen_tcp} = state, opts), do: :inet.setopts(state.socket, opts)
  defp setopts(state, opts), do: :ssl.setopts(state.socket, opts)
  defp fail(state, kind), do: {:stop, :normal, {:error, %Error{kind: kind}}, state}

  defp terminate_error(state, kind) do
    error = %Error{kind: kind}
    send(state.owner, {state.ref, :error, error})
    if state.pending, do: GenServer.reply(elem(state.pending, 0), {:error, error})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    state.transport.close(state.socket)
  end

  @impl true
  def format_status(status), do: %{status | state: :private_native_channel}
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now())
end
