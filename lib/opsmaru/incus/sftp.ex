defmodule Opsmaru.Incus.SFTP do
  @moduledoc """
  Owner-bound SFTP v3 subset over the native Incus raw upgrade: initialization,
  extension metadata, open, positional read/write and close. No SSH or host files.

  Modes are read, write, read_write, append (existing file), and create (read/write,
  create/truncate). One request runs at a time. File handles belong to one session;
  paths are UTF-8, at most 4096 bytes and contain no NUL. Reads/writes are at most
  128 KiB and use nonnegative signed-int64 offsets. A read returns the full requested
  DATA packet or EOF; short/empty DATA rejects instead of issuing extra requests.
  Each outgoing packet must also fit the host's request/chunk budgets. Other
  operations reject. File handles are invalidated after any close attempt.
  Native status errors retain codes/messages/language; possibly dispatched
  mutations with no valid reply are uncertain and never replayed. Closing a local
  session releases its channel without deleting backend files or canceling Incus.
  """
  use GenServer
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Error, RawChannel, RequestContext, Transport}
  alias Opsmaru.Incus.SFTP.{Handle, Packet}
  defstruct [:pid, :ref, :owner, :timeout, :lifetime, :request_context, :connection, :identity]
  @modes %{read: 1, write: 2, read_write: 3, append: 6, create: 27}
  @packet_limit 132_096

  def instance(client, name), do: start(client, {:instance, name})
  def volume(client, pool, type, name), do: start(client, {:volume, pool, type, name})
  def extensions(session), do: call(session, :extensions)
  def open(session, path, mode), do: call(session, {:open, path, mode})
  def read_at(session, handle, offset, count), do: call(session, {:read, handle, offset, count})
  def write_at(session, handle, offset, bytes), do: call(session, {:write, handle, offset, bytes})
  def close_file(session, handle), do: call(session, {:close_file, handle})
  def close(session), do: call(session, :close)
  def unsupported(_session, _operation), do: error(:unsupported_sftp_operation)

  defp start(client, target) do
    case Context.authorize(client.context, client.connection) do
      :ok ->
        ref = make_ref()
        lifetime = lifetime(client.connection)

        case GenServer.start(__MODULE__, {client, target, self(), ref, lifetime},
               timeout: client.connection.timeout + 200
             ) do
          {:ok, pid} ->
            {:ok,
             %__MODULE__{
               pid: pid,
               ref: ref,
               owner: self(),
               timeout: client.connection.timeout,
               lifetime: lifetime,
               request_context: client.connection.request_context,
               connection: client.connection,
               identity: client.context.identity
             }}

          {:error, %Error{} = reason} ->
            {:error, reason}

          {:error, _} ->
            kind = closed_kind(lifetime, client.connection.request_context)
            error(if(kind == :channel_closed, do: :sftp_protocol, else: kind))
        end

      {:error, kind} ->
        error(kind)
    end
  end

  defp lifetime(connection) do
    # Never shorten a shared context while retaining its cancellation cell:
    # expiry of the local stream must not cancel unrelated host requests.
    RequestContext.new!(timeout: connection.stream_timeout)
  end

  defp call(%__MODULE__{owner: owner} = session, request) when owner == self() do
    tag = make_ref()
    monitor = Process.monitor(session.pid)

    deadline =
      RequestContext.deadline(
        session.request_context,
        min(session.lifetime.deadline, now() + session.timeout)
      )

    try do
      result = GenServer.call(session.pid, {session.ref, tag, request}, session.timeout + 200)
      request_id(tag)
      result
    catch
      :exit, _ ->
        receive do
          {:DOWN, ^monitor, :process, _, _} -> :ok
        after
          100 -> :ok
        end

        id = request_id(tag)
        reason = closed_kind(session.lifetime, session.request_context)
        reason = if reason == :channel_closed and now() >= deadline, do: :deadline, else: reason
        kind = if mutation?(request) and id, do: :uncertain, else: reason

        if request == :close,
          do: :ok,
          else:
            {:error,
             %Error{
               kind: kind,
               response: %{
                 request_id: id,
                 error: as_error(reason),
                 connection: session.connection,
                 identity: session.identity,
                 session: session.ref
               }
             }}
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp call(%__MODULE__{}, _), do: error(:owner_mismatch)
  defp call(_, _), do: error(:invalid_arguments)

  defp closed_kind(lifetime, request_context) do
    status =
      case RequestContext.status(request_context) do
        :active -> RequestContext.status(lifetime)
        kind -> kind
      end

    case status do
      :active -> :channel_closed
      kind -> kind
    end
  end

  @impl true
  def init({client, target, owner, ref, lifetime}) do
    Transport.watch_owner(owner, lifetime)

    if client.connection.request_context,
      do: Transport.watch_owner(owner, client.connection.request_context)

    deadline =
      RequestContext.deadline(
        client.connection.request_context,
        min(lifetime.deadline, now() + client.connection.timeout)
      )

    case raw(client, target) do
      {:ok, raw} ->
        state = %{
          raw: raw,
          client: client,
          owner: owner,
          ref: ref,
          lifetime: lifetime,
          buffer: <<>>,
          id: 0,
          handles: MapSet.new(),
          extensions: %{},
          raw_monitor: Process.monitor(raw.pid)
        }

        with :ok <- RawChannel.notify_read_eof(raw),
             :ok <- send_packet(state, Packet.init(), deadline),
             {:ok, body, state} <- packet(state, deadline),
             {:ok, extensions} <- Packet.version(body) do
          {:ok, %{state | extensions: extensions}}
        else
          {:error, reason} ->
            RawChannel.close(raw)
            {:stop, as_error(reason)}
        end

      {:error, reason} ->
        {:stop, as_error(reason)}
    end
  end

  defp raw(client, {:instance, name}), do: Incus.sftp(client, name)
  defp raw(client, {:volume, pool, type, name}), do: Incus.volume_sftp(client, pool, type, name)

  @impl true
  def handle_call({ref, _, :close}, {owner, _}, %{ref: ref, owner: owner} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call({ref, tag, request}, {owner, _}, %{ref: ref, owner: owner} = state) do
    # Only the actual session creates a deadline guard for its own process.
    # A forged public handle must never cause us to kill an unrelated PID.
    worker = self()
    guard = spawn(fn -> request_guard(worker, tag, state.client.connection.timeout) end)

    try do
      case Context.authorize(state.client.context, state.client.connection) do
        :ok -> dispatch(request, tag, state)
        {:error, kind} -> {:reply, error(kind), state}
      end
    after
      send(guard, {tag, :finished})
    end
  end

  def handle_call(_, _, state), do: {:reply, error(:owner_mismatch), state}

  defp dispatch(:extensions, _, state), do: {:reply, {:ok, state.extensions}, state}

  defp dispatch(request, tag, state) do
    with {:ok, op, args} <- arguments(request, state),
         true <- state.id < 4_294_967_295,
         body = Packet.frame(Packet.request(state.id + 1, op, args)),
         true <-
           byte_size(body) <=
             min(
               state.client.connection.max_chunk_bytes,
               state.client.connection.max_request_bytes
             ) do
      id = state.id + 1
      state = %{state | id: id}
      # As natively, a close attempt invalidates the local handle even if the
      # server rejects it. Never send a later use-after-close request.
      state =
        if op == :close_file,
          do: %{state | handles: MapSet.delete(state.handles, args)},
          else: state

      deadline =
        RequestContext.deadline(
          state.client.connection.request_context,
          min(state.lifetime.deadline, now() + state.client.connection.timeout)
        )

      send(state.owner, {tag, id})

      result =
        with :ok <- send_packet(state, body, deadline),
             {:ok, body, state} <- packet(state, deadline) do
          {:ok, Packet.reply(body, id, op), state}
        end

      finish(result, op, args, request, state)
    else
      {:error, kind} -> {:reply, error(kind), state}
      false -> {:reply, error(:sftp_limit), state}
    end
  end

  defp arguments({:open, path, mode}, state)
       when is_binary(path) and byte_size(path) in 1..4096 and is_map_key(@modes, mode) do
    if String.valid?(path) and not String.contains?(path, <<0>>) and
         MapSet.size(state.handles) < min(state.client.connection.queue_limit, 128),
       do: {:ok, :open, {path, @modes[mode]}},
       else: {:error, :invalid_arguments}
  end

  defp arguments({:close_file, %Handle{session: ref, value: handle}}, %{ref: ref} = state) do
    if MapSet.member?(state.handles, handle),
      do: {:ok, :close_file, handle},
      else: {:error, :invalid_arguments}
  end

  defp arguments({op, %Handle{session: ref, value: handle}, offset, value}, %{ref: ref} = state)
       when op in [:read, :write] and is_integer(offset) and
              offset in 0..9_223_372_036_854_775_807 do
    count = if op == :write and is_binary(value), do: byte_size(value), else: value

    if is_integer(count) and count in 1..131_072 and
         offset + count <= 9_223_372_036_854_775_807 and
         (op == :read or is_binary(value)) and MapSet.member?(state.handles, handle),
       do: {:ok, op, {handle, offset, value}},
       else: {:error, :invalid_arguments}
  end

  defp arguments(_, _), do: {:error, :invalid_arguments}

  defp finish({:ok, {:handle, handle}, state}, :open, _, request, _) do
    if MapSet.member?(state.handles, handle),
      do: fatal(:sftp_protocol, mutation?(request), state),
      else:
        {:reply, {:ok, %Handle{session: state.ref, value: handle}},
         %{state | handles: MapSet.put(state.handles, handle)}}
  end

  defp finish({:ok, {:data, bytes}, state}, :read, {_, _, count}, _, _)
       when byte_size(bytes) == count,
       do: {:reply, {:ok, bytes}, state}

  defp finish({:ok, {:status, 1, _, _}, state}, :read, _, _, _), do: {:reply, :eof, state}

  defp finish({:ok, {:status, 0, _, _}, state}, :write, _, _, _), do: {:reply, :ok, state}

  defp finish({:ok, {:status, 0, _, _}, state}, :close_file, handle, _, _),
    do: {:reply, :ok, %{state | handles: MapSet.delete(state.handles, handle)}}

  defp finish({:ok, {:status, code, message, language}, state}, _, _, _, _) when code != 0,
    do:
      {:reply,
       {:error,
        %Error{
          kind: :sftp_status,
          error_code: code,
          message: message,
          response: %{
            request_id: state.id,
            language: language,
            session: state.ref,
            connection: state.client.connection,
            identity: state.client.context.identity
          }
        }}, state}

  defp finish({:error, reason}, _, _, request, state),
    do: fatal(reason, mutation?(request), state)

  defp finish(_, _, _, request, state), do: fatal(:sftp_protocol, mutation?(request), state)

  defp mutation?({:open, _, mode}), do: mode != :read
  defp mutation?({:write, _, _, _}), do: true
  defp mutation?({:close_file, _}), do: true
  defp mutation?(_), do: false

  defp fatal(reason, mutation, state) do
    error = as_error(reason)

    error = %{
      error
      | kind: if(mutation, do: :uncertain, else: error.kind),
        response: %{
          request_id: state.id,
          error: error,
          session: state.ref,
          connection: state.client.connection,
          identity: state.client.context.identity
        }
    }

    {:stop, :normal, {:error, error}, state}
  end

  defp send_packet(state, bytes, deadline) do
    cond do
      byte_size(bytes) >
          min(
            state.client.connection.max_chunk_bytes,
            state.client.connection.max_request_bytes
          ) ->
        error(:sftp_limit)

      now() >= deadline ->
        error(:deadline)

      true ->
        RawChannel.send_data(state.raw, bytes)
    end
  end

  defp packet(state, deadline) do
    with {:ok, <<length::32>>, state} <- bytes(state, 4, deadline),
         true <- length in 1..min(@packet_limit, state.client.connection.max_response_bytes) do
      bytes(state, length, deadline)
    else
      false -> error(:sftp_limit)
      error -> error
    end
  end

  defp bytes(state, count, deadline) do
    receive_bytes(state, count, deadline, [state.buffer], byte_size(state.buffer))
  end

  defp receive_bytes(state, count, deadline, chunks, total) do
    cond do
      now() >= deadline ->
        error(:deadline)

      total >= count ->
        <<value::binary-size(count), rest::binary>> = IO.iodata_to_binary(Enum.reverse(chunks))
        {:ok, value, %{state | buffer: rest}}

      true ->
        case RawChannel.recv(state.raw, max(1, deadline - now())) do
          {:ok, more} ->
            receive_bytes(state, count, deadline, [more | chunks], total + byte_size(more))

          :eof ->
            error(:channel_closed)

          error ->
            error
        end
    end
  end

  @impl true
  def handle_info({ref, :read_eof}, %{raw: %{ref: ref}} = state),
    do: {:stop, :normal, state}

  def handle_info({ref, :error, _}, %{raw: %{ref: ref}} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _, _}, %{raw_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, state), do: RawChannel.close(state.raw)
  @impl true
  def format_status(status), do: %{status | state: :private_sftp_session}
  defp error(kind), do: {:error, %Error{kind: kind}}
  defp as_error(%Error{} = error), do: error
  defp as_error(kind), do: %Error{kind: kind}
  defp now, do: System.monotonic_time(:millisecond)

  defp request_id(tag) do
    receive do
      {^tag, id} -> id
    after
      0 -> nil
    end
  end

  defp request_guard(worker, tag, timeout) do
    monitor = Process.monitor(worker)

    receive do
      {^tag, :finished} -> Process.demonitor(monitor, [:flush])
      {:DOWN, ^monitor, :process, _, _} -> :ok
    after
      timeout -> Process.exit(worker, :kill)
    end
  end
end

defimpl Inspect, for: Opsmaru.Incus.SFTP do
  def inspect(_, _), do: "#Opsmaru.Incus.SFTP<native session redacted>"
end
