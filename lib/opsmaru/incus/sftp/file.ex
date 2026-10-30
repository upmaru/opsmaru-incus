defmodule Opsmaru.Incus.SFTP.File do
  @moduledoc """
  An open SFTP file, matching the pinned `pkg/sftp` v1.13.10 `*sftp.File` as
  `GetInstanceFileSFTP` and `GetStoragePoolVolumeFileSFTP` configure it: 128 KiB
  packets, pipelined reads with up to 64 requests per file, and writes sent one
  at a time unless `read_from_with_concurrency/3` is used.

  Any process may use a file. As with Go's per-file lock, cursor calls (`read/2`,
  `write/2`, `seek/3`, `write_to/2`, `read_from/2`, `sync/1`, `close/1`) take
  turns, while positional and metadata calls may overlap one another but not a
  cursor call, and a waiting cursor call holds back later ones. A process that
  exits while holding or waiting for the lock releases it.

  Reads return `{:ok, data}`, or `{:eof, data}` when they reach the end of the
  file. Other failures keep the byte count Go returns in `response.count`, and
  for reads the bytes received in `response.data`. A WRITE, CLOSE, FSETSTAT or
  FSYNC whose outcome is unknown is `:uncertain` and never resent. After
  `close/1`, every call fails with `:file_closed` without I/O.
  """
  import Bitwise
  alias Opsmaru.Incus.{Error, SFTP}
  alias Opsmaru.Incus.SFTP.Stat
  @enforce_keys [:session, :id, :path]
  defstruct [:session, :id, :path]
  @max_packet 131_072
  @max_concurrency 64
  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807
  @uint32 0xFFFFFFFF
  @uint64 0xFFFFFFFFFFFFFFFF
  @progress {__MODULE__, :progress}

  defguardp is_offset(value) when is_integer(value) and value in @int64_min..@int64_max

  @doc "Go `Name`: the path as given to open."
  def name(%__MODULE__{path: path}), do: path

  @doc "Go `Close`: invalidates the file before sending CLOSE, as natively."
  def close(%__MODULE__{} = file) do
    locked(file, :exclusive, fn offset ->
      {request(file, :close_file, file.id, true, &reply(:ok, &1, &2)), offset}
    end)
  end

  @doc "Go `Read`: up to `count` bytes at the file's position, which moves past them."
  def read(%__MODULE__{} = file, count) when is_integer(count) and count >= 0 do
    locked(file, :exclusive, fn offset ->
      result = read_at_offset(file, offset, count)
      {result, offset + count_of(result)}
    end)
  end

  def read(_, _), do: invalid()

  @doc "Go `ReadAt`: up to `count` bytes at `offset`, leaving the position unchanged."
  def read_at(%__MODULE__{} = file, offset, count)
      when is_offset(offset) and is_integer(count) and count >= 0,
      do: locked(file, :shared, fn _ -> {read_at_offset(file, offset, count), nil} end)

  def read_at(_, _, _), do: invalid()

  @doc "Go `Write`: writes `data` at the file's position, which moves past the bytes written."
  def write(%__MODULE__{} = file, data) when is_binary(data) do
    locked(file, :exclusive, fn offset ->
      result = write_at_offset(file, offset, data)
      {result, offset + count_of(result, byte_size(data))}
    end)
  end

  def write(_, _), do: invalid()

  @doc "Go `WriteAt`: writes `data` at `offset`, leaving the position unchanged."
  def write_at(%__MODULE__{} = file, offset, data) when is_offset(offset) and is_binary(data),
    do: locked(file, :shared, fn _ -> {write_at_offset(file, offset, data), nil} end)

  def write_at(_, _, _), do: invalid()

  @doc """
  Go `Seek`: `:start`, `:current` or `:end` (which sends FSTAT). A negative result
  fails with `:invalid_arguments` and leaves the position unchanged.
  """
  def seek(%__MODULE__{} = file, offset, whence)
      when is_offset(offset) and whence in [:start, :current, :end] do
    locked(file, :exclusive, fn current ->
      base =
        case whence do
          :start -> {:ok, 0}
          :current -> {:ok, current}
          :end -> with {:ok, stat} <- fstat(file), do: {:ok, stat.size}
        end

      case base do
        {:ok, base} when base + offset >= 0 -> {{:ok, base + offset}, base + offset}
        {:ok, _} -> {invalid(), current}
        error -> {error, current}
      end
    end)
  end

  def seek(_, _, _), do: invalid()

  @doc "Go `Stat` (FSTAT), named by the base of the opened path."
  def stat(%__MODULE__{} = file), do: locked(file, :shared, fn _ -> {fstat(file), nil} end)

  @doc "Go `Chmod` (FSETSTAT)."
  def chmod(%__MODULE__{} = file, mode) when is_integer(mode),
    do: fsetstat(file, {:permissions, Stat.chmod_perm(mode &&& @uint32)})

  def chmod(_, _), do: invalid()

  @doc "Go `Chown` (FSETSTAT): integer ids wrap to uint32 as natively."
  def chown(%__MODULE__{} = file, uid, gid) when is_integer(uid) and is_integer(gid),
    do: fsetstat(file, {:owner, uid &&& @uint32, gid &&& @uint32})

  def chown(_, _, _), do: invalid()

  @doc "Go `Truncate` (FSETSTAT): the size wraps to uint64 as natively."
  def truncate(%__MODULE__{} = file, size) when is_integer(size),
    do: fsetstat(file, {:size, size &&& @uint64})

  def truncate(_, _), do: invalid()

  @doc "Go `SetExtendedData` (FSETSTAT): `{type, data}` pairs."
  def set_extended_data(%__MODULE__{} = file, pairs) when is_list(pairs) do
    if Enum.all?(pairs, &match?({type, data} when is_binary(type) and is_binary(data), &1)),
      do: fsetstat(file, {:extended, pairs}),
      else: invalid()
  end

  def set_extended_data(_, _), do: invalid()

  @doc """
  Go `Sync` (`fsync@openssh.com`). Without the extension announced as `"1"` it
  fails locally with status 8, "fsync not supported", as natively.
  """
  def sync(%__MODULE__{} = file) do
    locked(file, :exclusive, fn offset ->
      result =
        case SFTP.has_extension(file.session, "fsync@openssh.com") do
          {:ok, "1"} ->
            request(file, :fsync, file.id, true, &reply(:ok, &1, &2))

          {:error, _} = error ->
            error

          _ ->
            {:error,
             %Error{
               kind: :sftp_status,
               error_code: 8,
               message: "fsync not supported",
               response: %{class: nil}
             }}
        end

      {result, offset}
    end)
  end

  @doc """
  Go `WriteTo`: streams the file from its position into `sink`, a function that
  receives each binary chunk and must return `:ok`. It first sends Go's STAT of
  the opened path. Regular files larger than 128 KiB are read ahead with up to
  64 pipelined requests and delivered in order; others are read one request at a
  time. Returns `{:ok, bytes_written}`. As natively, a pipelined copy leaves the
  position at the offset of the read that found the end.
  """
  def write_to(%__MODULE__{} = file, sink) when is_function(sink, 1) do
    locked(file, :exclusive, fn offset ->
      case SFTP.stat(file.session, file.path) do
        {:ok, %Stat{size: size, mode: mode}} ->
          size = size &&& @uint64

          if size <= @max_packet or (mode &&& 0o170000) != 0o100000,
            do: write_to_sequential(file, sink, offset, 0),
            else: write_to_concurrent(file, sink, offset, min(div(size, @max_packet) + 1, 64))

        error ->
          {with_count(error, 0), offset}
      end
    end)
  end

  def write_to(_, _), do: invalid()

  @doc """
  Go `ReadFrom`: writes an enumerable of binary chunks at the file's position,
  grouped into full 128 KiB WRITEs sent one at a time. Returns
  `{:ok, bytes_read}`. Unlike Go, a failed final short write is reported rather
  than ignored (an approved difference).
  """
  def read_from(%__MODULE__{} = file, source) do
    locked(file, :exclusive, fn offset ->
      {result, reader} = read_from_sequential(file, reader(source), offset, 0)
      close_reader(reader)
      result
    end)
  end

  @doc """
  Go `ReadFromWithConcurrency`: as `read_from/2`, with up to `concurrency` WRITEs
  in flight (values below 1 or above 64 mean 64). After a failure no more chunks
  are sent and the position moves to the failed chunk's offset.
  """
  def read_from_with_concurrency(%__MODULE__{} = file, source, concurrency)
      when is_integer(concurrency) do
    concurrency = if concurrency in 1..@max_concurrency, do: concurrency, else: @max_concurrency

    locked(file, :exclusive, fn offset ->
      {result, reader} = read_from_concurrent(file, reader(source), offset, concurrency)
      close_reader(reader)
      result
    end)
  end

  def read_from_with_concurrency(_, _, _), do: invalid()

  defp invalid, do: {:error, %Error{kind: :invalid_arguments}}

  # Go's per-file lock around one call. The function returns {result, offset};
  # an exclusive holder's offset becomes the file's position.
  defp locked(file, mode, fun) do
    case SFTP.file_lock(file.session, file.id, mode) do
      {:ok, token, offset} ->
        previous = Process.put(@progress, offset)

        try do
          {result, offset} = fun.(offset)
          SFTP.file_unlock(file.session, token, offset)
          result
        catch
          # A raising source or sink keeps the position its completed chunks
          # reached, as Go moves the offset chunk by chunk.
          kind, reason ->
            SFTP.file_unlock(file.session, token, Process.get(@progress))
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          if is_nil(previous),
            do: Process.delete(@progress),
            else: Process.put(@progress, previous)
        end

      error ->
        error
    end
  end

  defp progress(offset), do: Process.put(@progress, offset)

  defp request(file, op, args, mutation, interpret),
    do: SFTP.file_request(file.session, op, args, mutation, interpret)

  defp reply(kind, reply, error), do: SFTP.file_reply(kind, reply, error)

  defp data({:data, bytes}, _), do: {:ok, bytes}
  defp data(reply, error), do: reply(:status, reply, error)

  defp fstat(file),
    do:
      request(
        file,
        :fstat,
        file.id,
        false,
        &reply({:attributes, SFTP.file_base(file.path)}, &1, &2)
      )

  defp fsetstat(file, attrs) do
    locked(file, :shared, fn _ ->
      {request(file, :fsetstat, {file.id, attrs}, true, &reply(:ok, &1, &2)), nil}
    end)
  end

  defp read_at_offset(file, offset, count) when count <= @max_packet,
    do: read_chunk(file, offset, count, [], 0)

  defp read_at_offset(file, offset, count),
    do: read_concurrent(file, offset, count, min(div(count, @max_packet) + 1, @max_concurrency))

  # Go readChunkAt: reads until `count` bytes arrive, continuing after short replies.
  defp read_chunk(file, offset, count, acc, read) when read < count do
    case request(file, :read, {file.id, offset + read, count - read}, false, &data/2) do
      {:ok, bytes} ->
        bytes = binary_part(bytes, 0, min(byte_size(bytes), count - read))
        read_chunk(file, offset, count, [acc | bytes], read + byte_size(bytes))

      error ->
        read_failure(error, read, IO.iodata_to_binary(acc))
    end
  end

  defp read_chunk(_, _, _, acc, _), do: {:ok, IO.iodata_to_binary(acc)}

  defp read_failure({:error, %Error{response: %{class: :eof}}}, _, data), do: {:eof, data}
  defp read_failure(error, read, data), do: with_count(error, read, data)

  # Go readAt with concurrent reads: 128 KiB chunks in offset order, at most
  # `concurrency` plus one dispatched ahead. A short chunk means end of file, and
  # the earliest failure decides the result.
  defp read_concurrent(file, offset, count, concurrency) do
    chunks = chunks(offset, count)

    consume = fn {start, size}, result, {acc, _} ->
      case SFTP.file_settle(result, false, &data/2) do
        {:ok, bytes} when byte_size(bytes) >= size ->
          {:cont, {[acc | binary_part(bytes, 0, size)], nil}}

        {:ok, bytes} ->
          eof = {:error, %Error{kind: :sftp_status, error_code: 1, response: %{class: :eof}}}
          {:halt, {[acc | bytes], {start + byte_size(bytes) - offset, eof}}}

        error ->
          {:halt, {acc, {start - offset, error}}}
      end
    end

    {{acc, failure}, _} =
      pipeline(
        file,
        concurrency + 1,
        list_producer(chunks, file),
        &read_stop?/1,
        consume,
        {[], nil}
      )

    case failure do
      nil -> {:ok, IO.iodata_to_binary(acc)}
      {read, error} -> read_failure(error, read, IO.iodata_to_binary(acc))
    end
  end

  defp chunks(offset, count) do
    Stream.unfold(0, fn
      done when done >= count -> nil
      done -> {{offset + done, min(@max_packet, count - done)}, done + @max_packet}
    end)
    |> Enum.to_list()
  end

  defp list_producer(chunks, file) do
    {fn
       [{start, size} | rest] -> {:item, {:read, {file.id, start, size}, {start, size}}, rest}
       [] -> :done
     end, chunks}
  end

  defp read_stop?({:ok, {:data, _}, _}), do: false
  defp read_stop?(_), do: true

  defp write_stop?({:ok, {:status, {0, _, _}}, _}), do: false
  defp write_stop?(_), do: true

  # Go writeAt without concurrent writes: one WRITE of at most 128 KiB at a time.
  defp write_at_offset(file, offset, data) when byte_size(data) <= @max_packet,
    do: with_count(write_chunk(file, offset, data), 0)

  defp write_at_offset(file, offset, data), do: write_sequential(file, offset, data, 0)

  defp write_sequential(_, _, <<>>, _), do: :ok

  defp write_sequential(file, offset, data, written) do
    size = min(byte_size(data), @max_packet)
    <<chunk::binary-size(size), rest::binary>> = data

    case write_chunk(file, offset + written, chunk) do
      :ok -> write_sequential(file, offset, rest, written + size)
      error -> with_count(error, written)
    end
  end

  defp write_chunk(file, offset, bytes),
    do: request(file, :write, {file.id, offset, bytes}, true, &reply(:ok, &1, &2))

  # Go writeToSequential: 128 KiB readChunkAt calls until end of file.
  defp write_to_sequential(file, sink, offset, written) do
    result = read_chunk(file, offset, @max_packet, [], 0)
    {data, finished} = sequential_chunk(result)
    offset = offset + byte_size(data)
    progress(offset)

    case deliver(sink, data, written) do
      {:ok, written} when finished == :more ->
        write_to_sequential(file, sink, offset, written)

      {:ok, written} ->
        {done(finished, written), offset}

      error ->
        {error, offset}
    end
  end

  defp sequential_chunk({:ok, data}), do: {data, :more}
  defp sequential_chunk({:eof, data}), do: {data, :eof}

  defp sequential_chunk({:error, %Error{response: %{data: data}}} = error),
    do: {data, error}

  defp done(:eof, written), do: {:ok, written}

  defp done({:error, error}, written),
    do: with_count({:error, %{error | response: Map.delete(error.response, :data)}}, written)

  defp deliver(_, <<>>, written), do: {:ok, written}

  defp deliver(sink, data, written) do
    if sink.(data) == :ok,
      do: {:ok, written + byte_size(data)},
      else: with_count({:error, %Error{kind: :sink_failed}}, written)
  end

  # Go's pipelined WriteTo: reads ahead from the position and delivers in order.
  defp write_to_concurrent(file, sink, offset, concurrency) do
    producer =
      {fn start ->
         {:item, {:read, {file.id, start, @max_packet}, start}, start + @max_packet}
       end, offset}

    consume = fn start, result, {written, _, _} ->
      case SFTP.file_settle(result, false, &data/2) do
        {:ok, bytes} ->
          bytes = binary_part(bytes, 0, min(byte_size(bytes), @max_packet))
          progress(start + byte_size(bytes))

          case deliver(sink, bytes, written) do
            {:ok, written} -> {:cont, {written, start + byte_size(bytes), nil}}
            error -> {:halt, {written, start + byte_size(bytes), error}}
          end

        {:error, %Error{response: %{class: :eof}}} ->
          {:halt, {written, start, :eof}}

        error ->
          {:halt, {written, start, error}}
      end
    end

    {{written, offset, finished}, _} =
      pipeline(file, concurrency + 1, producer, &read_stop?/1, consume, {0, offset, nil})

    case finished do
      :eof -> {{:ok, written}, offset}
      error -> {with_count(error, written), offset}
    end
  end

  # Go ReadFrom without concurrent writes. The read count includes a chunk whose
  # write failed, as natively. Returns the reader so the source can be closed.
  defp read_from_sequential(file, reader, offset, read) do
    case read_full(reader, @max_packet) do
      {:eof, reader} ->
        {{{:ok, read}, offset}, reader}

      {:error, error, reader} ->
        {{with_count({:error, error}, read), offset}, reader}

      {kind, chunk, reader} ->
        read = read + byte_size(chunk)

        case write_chunk(file, offset, chunk) do
          :ok when kind == :full ->
            progress(offset + byte_size(chunk))
            read_from_sequential(file, reader, offset + byte_size(chunk), read)

          :ok ->
            {{{:ok, read}, offset + byte_size(chunk)}, reader}

          error ->
            {{with_count(error, read), offset}, reader}
        end
    end
  end

  # Go readFromWithConcurrency: chunks are read and sent in order with up to
  # `concurrency` plus one in flight; the earliest failure wins.
  defp read_from_concurrent(file, reader, offset, concurrency) do
    producer =
      {fn {reader, start, read} ->
         case read_full(reader, @max_packet) do
           {:eof, reader} ->
             {:done, {reader, start, read}}

           {:error, error, reader} ->
             {:failed, {:error, error}, {start, 0}, {reader, start, read}}

           {_, chunk, reader} ->
             size = byte_size(chunk)

             {:item, {:write, {file.id, start, chunk}, {start, size}},
              {reader, start + size, read + size}}
         end
       end, {reader, offset, 0}}

    # Progress is the acknowledged prefix, written in order.
    consume = fn {start, size}, result, nil ->
      case SFTP.file_settle(result, true, &reply(:ok, &1, &2)) do
        :ok ->
          progress(start + size)
          {:cont, nil}

        error ->
          {:halt, {start, error}}
      end
    end

    {failure, {reader, _, read}} =
      pipeline(file, concurrency + 1, producer, &write_stop?/1, consume, nil)

    case failure do
      nil -> {{{:ok, read}, offset + read}, reader}
      {start, error} -> {{with_count(error, read), start}, reader}
    end
  end

  # Pipelined requests in offset order. Up to `window` dispatched requests wait to
  # be consumed in order; after a failure or end of data no more are sent, and
  # every dispatched request is awaited before returning, as Go's workers drain.
  defp pipeline(file, window, producer, stop?, consume, acc) do
    dest = Process.alias()
    monitor = Process.monitor(file.session.pid)

    state = %{
      session: file.session,
      dest: dest,
      monitor: monitor,
      window: window,
      producer: producer,
      held: nil,
      order: :queue.new(),
      results: %{},
      stopped: false,
      halted: false,
      stop?: stop?,
      consume: consume,
      acc: acc
    }

    try do
      state = step(state)
      {state.acc, elem(state.producer, 1)}
    after
      Process.unalias(dest)
      Process.demonitor(monitor, [:flush])
      flush(dest)
    end
  end

  defp step(state) do
    state = fill(state)

    case :queue.peek(state.order) do
      :empty ->
        state

      {:value, {key, meta}} ->
        case ready(state, key) do
          {:ok, result, state} ->
            step(consume_head(%{state | order: :queue.drop(state.order)}, meta, result))

          :wait ->
            step(await(state))
        end
    end
  end

  defp fill(%{stopped: true} = state), do: state

  defp fill(state) do
    if :queue.len(state.order) >= state.window, do: state, else: dispatch(state, next(state))
  end

  defp next(%{held: item} = state) when not is_nil(item), do: {item, state}

  defp next(%{producer: {fun, producer_state}} = state) do
    case fun.(producer_state) do
      {:item, item, producer_state} ->
        {item, %{state | producer: {fun, producer_state}}}

      {:done, producer_state} ->
        {:done, %{state | producer: {fun, producer_state}}}

      :done ->
        {:done, state}

      {:failed, error, meta, producer_state} ->
        {{:failed, error, meta}, %{state | producer: {fun, producer_state}}}
    end
  end

  defp dispatch(_, {:done, state}), do: %{state | stopped: true}
  defp dispatch(_, {{:failed, error, meta}, state}), do: fail(state, error, meta)

  defp dispatch(_, {{op, args, meta} = item, state}) do
    case SFTP.file_dispatch(state.session, op, args, state.dest) do
      {:ok, id} ->
        fill(%{state | held: nil, order: :queue.in({id, meta}, state.order)})

      # The connection's in-flight bound: wait for a reply, then send this chunk.
      {:error, %Error{kind: :sftp_limit}} = error ->
        if :queue.is_empty(state.order),
          do: fail(state, error, meta),
          else: %{state | held: item}

      error ->
        fail(state, error, meta)
    end
  end

  defp fail(state, error, meta),
    do: %{
      state
      | held: nil,
        stopped: true,
        order: :queue.in({{:failed, error}, meta}, state.order)
    }

  defp ready(state, {:failed, error}), do: {:ok, error, state}

  defp ready(state, id) do
    case Map.pop(state.results, id) do
      {nil, _} -> :wait
      {result, results} -> {:ok, result, %{state | results: results}}
    end
  end

  defp consume_head(%{halted: true} = state, _, _), do: state

  defp consume_head(state, meta, result) do
    case state.consume.(meta, result, state.acc) do
      {:cont, acc} -> %{state | acc: acc}
      {:halt, acc} -> %{state | acc: acc, halted: true, stopped: true}
    end
  end

  defp await(%{dest: dest, monitor: monitor} = state) do
    receive do
      {:sftp_reply, ^dest, id, result} ->
        %{
          state
          | results: Map.put(state.results, id, result),
            stopped: state.stopped or state.stop?.(result)
        }

      {:DOWN, ^monitor, :process, _, _} ->
        # The session ended without answering: every outstanding request failed.
        results =
          for {id, _} when is_integer(id) <- :queue.to_list(state.order),
              not is_map_key(state.results, id),
              into: state.results,
              do: {id, {:error, %Error{kind: :channel_closed, response: %{request_id: id}}}}

        %{state | results: results, stopped: true}
    end
  end

  defp flush(dest) do
    receive do
      {:sftp_reply, ^dest, _, _} -> flush(dest)
    after
      0 -> :ok
    end
  end

  # A pull-based reader over an enumerable source, grouping its chunks like
  # io.ReadFull: {:full, chunk}, a final {:partial, chunk}, then :eof.
  defp reader(source) do
    %{
      next: fn command ->
        Enumerable.reduce(source, command, fn chunk, _ -> {:suspend, chunk} end)
      end,
      buffer: [],
      size: 0,
      done: false
    }
  end

  defp read_full(%{size: size} = reader, count) when size >= count do
    <<chunk::binary-size(count), rest::binary>> = IO.iodata_to_binary(reader.buffer)
    {:full, chunk, %{reader | buffer: [rest], size: size - count}}
  end

  defp read_full(%{done: true, size: 0} = reader, _), do: {:eof, reader}

  defp read_full(%{done: true} = reader, _),
    do: {:partial, IO.iodata_to_binary(reader.buffer), %{reader | buffer: [], size: 0}}

  defp read_full(reader, count) do
    case reader.next.({:cont, nil}) do
      {:suspended, chunk, continuation} when is_binary(chunk) ->
        reader = %{
          reader
          | next: continuation,
            buffer: [reader.buffer | chunk],
            size: reader.size + byte_size(chunk)
        }

        read_full(reader, count)

      {:suspended, _, continuation} ->
        {:error, %Error{kind: :invalid_arguments}, %{reader | next: continuation}}

      _ ->
        read_full(%{reader | done: true}, count)
    end
  end

  defp close_reader(%{done: false, next: next}) do
    next.({:halt, nil})
    :ok
  end

  defp close_reader(_), do: :ok

  defp count_of({:ok, data}) when is_binary(data), do: byte_size(data)
  defp count_of({:eof, data}), do: byte_size(data)
  defp count_of({:error, %Error{response: %{count: count}}}), do: count
  defp count_of(_), do: 0

  defp count_of(:ok, size), do: size
  defp count_of(result, _), do: count_of(result)

  defp with_count(result, count, data \\ nil)

  defp with_count({:error, %Error{} = error}, count, data) do
    fields = if is_nil(data), do: %{count: count}, else: %{count: count, data: data}
    {:error, %{error | response: Map.merge(error.response || %{}, fields)}}
  end

  defp with_count(result, _, _), do: result
end

defimpl Inspect, for: Opsmaru.Incus.SFTP.File do
  def inspect(_, _), do: "#Opsmaru.Incus.SFTP.File<native handle redacted>"
end
