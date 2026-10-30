defmodule Opsmaru.Incus.SFTP do
  @moduledoc """
  SFTP v3 client over the native Incus raw upgrade, matching the pinned `pkg/sftp`
  v1.13.10 client returned by `GetInstanceFileSFTP` and
  `GetStoragePoolVolumeFileSFTP`. No SSH or host files.

  A session is shared: any process may call it, and requests are pipelined with
  distinct ids whose replies are matched by id, as goroutines share a Go
  `*sftp.Client`. It closes on `close/1`, peer EOF, its stream lifetime, or when
  the process that opened it exits. In-flight requests are bounded by the
  connection's queue limit.

  Path and metadata calls send the pinned packets, including the compound steps
  of `remove/2`, `mkdir_all/2`, `remove_all/2`, `glob/2` and `walk/3`. Paths are
  sent as given; only packet and connection bounds apply. A compound call stops at
  the first error that is not a native status, so it never sends more mutations
  after a possibly accepted one.

  Native status errors are `:sftp_status` with the code, message and language,
  plus `response.class` (`:eof`, `:not_exist`, `:permission` or `nil`) as Go
  normalizes them, and `response.op`/`response.path` where Go returns an
  `os.PathError`. A request whose local deadline passes fails alone: a possibly
  sent mutation is `:uncertain` and never replayed, and its late reply is
  discarded. Malformed, oversized or unmatched frames end the session and fail
  every pending request, mutations as `:uncertain`. Closing a session releases
  its channel without deleting backend files or canceling Incus.

  File handles from `open/3` belong to one session. `read_at/4` and `write_at/4`
  move at most 128 KiB per call with nonnegative signed-int64 offsets; a short
  DATA reply is rejected rather than continued.
  """
  use GenServer
  import Bitwise
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Context, Error, RawChannel, RequestContext, Transport}
  alias Opsmaru.Incus.SFTP.{Handle, Packet, Stat, StatVFS}
  alias Opsmaru.Incus.SFTP.Path, as: SPath
  defstruct [:pid, :ref, :timeout, :lifetime, :request_context, :connection, :identity]
  @modes %{read: 1, write: 2, read_write: 3, append: 6, create: 27}
  @packet_limit 132_096
  @uint32 0xFFFFFFFF

  def instance(client, name), do: start(client, {:instance, name})
  def volume(client, pool, type, name), do: start(client, {:volume, pool, type, name})
  def extensions(session), do: call(session, :extensions)
  def close(session), do: call(session, :close)

  @doc "Go `HasExtension`: `{:ok, data}` when the server announced the extension."
  def has_extension(session, name) do
    with {:ok, extensions} <- extensions(session) do
      case Map.fetch(extensions, name) do
        {:ok, data} -> {:ok, data}
        :error -> :error
      end
    end
  end

  def open(session, path, mode) when is_binary(path) and is_map_key(@modes, mode),
    do: request(session, :open, {path, @modes[mode]}, mode != :read, &handle/2)

  def open(_, _, _), do: error(:invalid_arguments)

  def read_at(session, %Handle{} = handle, offset, count)
      when is_integer(offset) and offset in 0..9_223_372_036_854_775_807 and
             is_integer(count) and count in 1..131_072 and
             offset + count <= 9_223_372_036_854_775_807 do
    with {:ok, value} <- file_handle(session, handle) do
      request(session, :read, {value, offset, count}, false, fn
        {:data, bytes}, _ when byte_size(bytes) == count -> {:ok, bytes}
        {:status, {1, _, _}}, _ -> :eof
        reply, error -> status(reply, error)
      end)
    end
  end

  def read_at(_, _, _, _), do: error(:invalid_arguments)

  def write_at(session, %Handle{} = handle, offset, bytes)
      when is_integer(offset) and offset in 0..9_223_372_036_854_775_807 and is_binary(bytes) and
             byte_size(bytes) in 1..131_072 and
             offset + byte_size(bytes) <= 9_223_372_036_854_775_807 do
    with {:ok, value} <- file_handle(session, handle),
         do: request(session, :write, {value, offset, bytes}, true, &ok/2)
  end

  def write_at(_, _, _, _), do: error(:invalid_arguments)

  def close_file(session, %Handle{} = handle) do
    with {:ok, value} <- file_handle(session, handle),
         do: request(session, :close_file, value, true, &ok/2)
  end

  def close_file(_, _), do: error(:invalid_arguments)

  @doc "Go `Stat`: attributes of the file `path` names, following symlinks."
  def stat(session, path) when is_binary(path),
    do: request(session, :stat, path, false, &attributes(&1, &2, base(path)))

  @doc "Go `Lstat`: attributes of `path` itself, without following a symlink."
  def lstat(session, path) when is_binary(path),
    do: request(session, :lstat, path, false, &attributes(&1, &2, base(path)))

  @doc "Go `ReadDir`: the entries of a directory in server order, without `.` and `..`."
  def read_dir(session, path) when is_binary(path) do
    with {:ok, handle} <-
           request(session, :opendir, path, false, fn
             {:handle, handle}, _ -> {:ok, handle}
             {:status, {0, _, _}}, _ -> {:ok, ""}
             reply, error -> status(reply, error)
           end) do
      result = read_entries(session, handle, [])
      # As natively, the directory close result is ignored.
      request(session, :close_dir, handle, false, &ok/2)
      result
    end
  end

  defp read_entries(session, handle, acc) do
    case request(session, :readdir, handle, false, fn
           {:name, entries}, _ -> {:entries, entries}
           {:status, {code, _, _}}, _ when code in [0, 1] -> :done
           reply, error -> status(reply, error)
         end) do
      {:entries, entries} ->
        acc =
          for {name, fields} <- entries, name not in [".", ".."], reduce: acc do
            acc -> [Stat.new(fields, base(name)) | acc]
          end

        read_entries(session, handle, acc)

      :done ->
        {:ok, Enum.reverse(acc)}

      error ->
        error
    end
  end

  @doc "Go `ReadLink`: the target of a symbolic link."
  def read_link(session, path) when is_binary(path),
    do: request(session, :readlink, path, false, &single_name/2)

  @doc "Go `RealPath`: the server's canonical absolute path."
  def real_path(session, path) when is_binary(path),
    do: request(session, :realpath, path, false, &single_name/2)

  @doc "Go `Getwd`: `real_path(session, \".\")`."
  def getwd(session), do: real_path(session, ".")

  @doc "Go `Link`: a hard link `new` to `old` (`hardlink@openssh.com`)."
  def link(session, old, new) when is_binary(old) and is_binary(new),
    do: request(session, :hardlink, {old, new}, true, &ok/2)

  @doc "Go `Symlink`: a symbolic link `new` pointing at `old`."
  def symlink(session, old, new) when is_binary(old) and is_binary(new),
    do: request(session, :symlink, {old, new}, true, &ok/2)

  @doc "Go `Chmod`: permission and special bits (Go `FileMode` flags are honored)."
  def chmod(session, path, mode) when is_binary(path) and is_integer(mode),
    do: setstat(session, path, {:permissions, Stat.chmod_perm(mode &&& @uint32)})

  @doc "Go `Chown`: integer ids wrap to uint32 as natively."
  def chown(session, path, uid, gid) when is_binary(path) and is_integer(uid) and is_integer(gid),
    do: setstat(session, path, {:owner, uid &&& @uint32, gid &&& @uint32})

  @doc "Go `Chtimes`: Unix seconds or `DateTime`s, sent as native uint32 seconds."
  def chtimes(session, path, atime, mtime) when is_binary(path) do
    with {:ok, atime} <- unix(atime),
         {:ok, mtime} <- unix(mtime),
         do: setstat(session, path, {:times, atime &&& @uint32, mtime &&& @uint32})
  end

  @doc "Go `Truncate`: the size wraps to uint64 as natively."
  def truncate(session, path, size) when is_binary(path) and is_integer(size),
    do: setstat(session, path, {:size, size &&& 0xFFFFFFFFFFFFFFFF})

  @doc "Go `SetExtendedData`: `{type, data}` pairs."
  def set_extended_data(session, path, pairs) when is_binary(path) and is_list(pairs) do
    if Enum.all?(pairs, &match?({type, data} when is_binary(type) and is_binary(data), &1)),
      do: setstat(session, path, {:extended, pairs}),
      else: error(:invalid_arguments)
  end

  defp setstat(session, path, attrs), do: request(session, :setstat, {path, attrs}, true, &ok/2)

  @doc "Go `StatVFS` (`statvfs@openssh.com`)."
  def stat_vfs(session, path) when is_binary(path) do
    request(session, :statvfs, path, false, fn
      {:extended, <<values::binary-size(88), _::binary>>}, _ ->
        <<bsize::64, frsize::64, blocks::64, bfree::64, bavail::64, files::64, ffree::64,
          favail::64, fsid::64, flag::64, namemax::64>> = values

        {:ok,
         %StatVFS{
           bsize: bsize,
           frsize: frsize,
           blocks: blocks,
           bfree: bfree,
           bavail: bavail,
           files: files,
           ffree: ffree,
           favail: favail,
           fsid: fsid,
           flag: flag,
           namemax: namemax
         }}

      {:extended, _}, error ->
        {:error, %{error | kind: :sftp_protocol}}

      reply, error ->
        status(reply, error)
    end)
  end

  @doc """
  Go `Remove`: removes a file, else a directory. When both fail with different
  native errors, the pinned client stats `path` to choose which to return.
  """
  def remove(session, path) when is_binary(path) do
    with {:error, file_error} <- remove_file(session, path),
         :retry <- native(file_error),
         {:error, dir_error} <- remove_directory(session, path),
         :retry <- native(dir_error) do
      if same_class?(file_error, dir_error) do
        {:error, file_error}
      else
        case stat(session, path) do
          {:ok, stat} -> {:error, if(Stat.dir?(stat), do: dir_error, else: file_error)}
          error -> error
        end
      end
    else
      {:stop, error} -> {:error, error}
      result -> result
    end
  end

  defp remove_file(session, path),
    do: request(session, :remove, path, true, &path_error(&1, &2, path))

  @doc "Go `RemoveDirectory`: removes an empty directory."
  def remove_directory(session, path) when is_binary(path),
    do: request(session, :rmdir, path, true, &path_error(&1, &2, path))

  defp path_error(reply, error, path) do
    case ok(reply, error) do
      {:error, %Error{kind: :sftp_status, response: response} = error} ->
        {:error, %{error | response: Map.merge(response, %{op: "remove", path: path})}}

      result ->
        result
    end
  end

  defp native(%Error{kind: :sftp_status}), do: :retry
  defp native(error), do: {:stop, error}

  # errors.Is on two normalized PathError causes: only Go's sentinel classes compare equal.
  defp same_class?(%Error{response: %{class: class}}, %Error{response: %{class: class}})
       when not is_nil(class),
       do: true

  defp same_class?(_, _), do: false

  @doc "Go `Rename`."
  def rename(session, old, new) when is_binary(old) and is_binary(new),
    do: request(session, :rename, {old, new}, true, &ok/2)

  @doc "Go `PosixRename` (`posix-rename@openssh.com`)."
  def posix_rename(session, old, new) when is_binary(old) and is_binary(new),
    do: request(session, :posix_rename, {old, new}, true, &ok/2)

  @doc "Go `Mkdir`."
  def mkdir(session, path) when is_binary(path), do: request(session, :mkdir, path, true, &ok/2)

  @doc "Go `MkdirAll`: creates `path` and any missing parents."
  def mkdir_all(session, path) when is_binary(path) do
    case stat(session, path) do
      {:ok, stat} ->
        if Stat.dir?(stat),
          do: :ok,
          else:
            {:error,
             %Error{kind: :not_directory, response: %{op: "mkdir", path: path, class: :not_dir}}}

      {:error, %Error{kind: :sftp_status}} ->
        with :ok <- mkdir_parent(session, path), do: mkdir_missing(session, path)

      error ->
        error
    end
  end

  # A failed Mkdir still succeeds when the path is now a directory.
  defp mkdir_missing(session, path) do
    case mkdir(session, path) do
      {:error, %Error{kind: :sftp_status}} = error ->
        case lstat(session, path) do
          {:ok, stat} -> if Stat.dir?(stat), do: :ok, else: error
          _ -> error
        end

      result ->
        result
    end
  end

  # The pinned element scan: skip trailing slashes, then the last element.
  defp mkdir_parent(session, path) do
    i = byte_size(path) - trailing(path, byte_size(path), ?/, true)
    j = i - trailing(path, i, ?/, false)
    if j > 1, do: mkdir_all(session, binary_part(path, 0, j - 1)), else: :ok
  end

  defp trailing(path, index, byte, equal, count \\ 0)

  defp trailing(path, index, byte, equal, count) when index > 0 do
    if :binary.at(path, index - 1) == byte == equal,
      do: trailing(path, index - 1, byte, equal, count + 1),
      else: count
  end

  defp trailing(_, _, _, _, count), do: count

  @doc "Go `RemoveAll`: removes `path` and everything it contains."
  def remove_all(session, path) when is_binary(path) do
    with {:ok, stat} <- stat(session, path),
         :ok <- remove_children(session, path, stat),
         do: remove(session, path)
  end

  defp remove_children(session, path, stat) do
    if Stat.dir?(stat) do
      with {:ok, entries} <- read_dir(session, path),
           do: Enum.reduce_while(entries, :ok, &remove_entry(session, path, &1, &2))
    else
      :ok
    end
  end

  defp remove_entry(session, path, entry, :ok) do
    child = path <> "/" <> entry.name
    result = if Stat.dir?(entry), do: remove_all(session, child), else: remove(session, child)
    if result == :ok, do: {:cont, :ok}, else: {:halt, result}
  end

  @doc """
  Go `Glob`: the paths matching a shell pattern. As natively, a pattern without
  metacharacters that does not exist and unreadable directories yield no matches.
  """
  def glob(session, pattern) when is_binary(pattern) do
    if SPath.meta?(pattern) do
      {dir, file} = SPath.split(pattern)

      with {:ok, matches} <- glob_meta(session, pattern, clean_glob(dir), file),
           do: {:ok, Enum.reverse(matches)}
    else
      case lstat(session, pattern) do
        {:ok, stat} -> {:ok, [SPath.join([clean_glob(elem(SPath.split(pattern), 0)), stat.name])]}
        _ -> {:ok, []}
      end
    end
  end

  defp glob_meta(session, pattern, dir, file) do
    cond do
      not SPath.meta?(dir) ->
        glob_dir(session, dir, file, [])

      dir == pattern ->
        {:error, %Error{kind: :bad_pattern}}

      true ->
        with {:ok, dirs} <- glob(session, dir),
             do: Enum.reduce_while(dirs, {:ok, []}, &glob_into(session, &1, file, &2))
    end
  end

  defp glob_into(session, dir, file, {:ok, matches}) do
    case glob_dir(session, dir, file, matches) do
      {:ok, matches} -> {:cont, {:ok, matches}}
      error -> {:halt, error}
    end
  end

  defp clean_glob(""), do: "."
  defp clean_glob("/"), do: "/"
  defp clean_glob(dir), do: binary_part(dir, 0, byte_size(dir) - 1)

  # Matches accumulate newest first; glob/2 reverses them once. Stat or ReadDir
  # failures end this directory quietly with the matches so far.
  defp glob_dir(session, dir, pattern, matches) do
    with {:ok, stat} <- stat(session, dir),
         true <- Stat.dir?(stat),
         {:ok, entries} <- read_dir(session, dir) do
      Enum.reduce_while(entries, {:ok, matches}, fn entry, {:ok, matches} ->
        case SPath.match(pattern, entry.name) do
          {:ok, true} -> {:cont, {:ok, [SPath.join([dir, entry.name]) | matches]}}
          {:ok, false} -> {:cont, {:ok, matches}}
          {:error, :bad_pattern} -> {:halt, {:error, %Error{kind: :bad_pattern}}}
        end
      end)
    else
      _ -> {:ok, matches}
    end
  end

  @doc """
  Go `Walk` (kr/fs `Walker`): a lazy stream of `{path, {:ok, stat} | {:error, error}}`
  in the pinned order. `skip: fun(path, stat)` returning true skips a directory's
  contents, like `SkipDir`. A directory that cannot be read is yielded again with
  its error.
  """
  def walk(session, root, opts \\ []) when is_binary(root) do
    skip = Keyword.get(opts, :skip, fn _, _ -> false end)

    Stream.unfold(:start, fn
      :start ->
        item = {root, lstat(session, root)}
        {item, {[], item}}

      {stack, previous} ->
        stack = descend(session, previous, stack, skip)

        case stack do
          [] -> nil
          [item | rest] -> {item, {rest, item}}
        end
    end)
  end

  defp descend(session, {path, {:ok, stat}} = item, stack, skip) do
    if Stat.dir?(stat) and not skip.(path, stat) do
      case read_dir(session, path) do
        {:ok, entries} -> Enum.map(entries, &{SPath.join([path, &1.name]), {:ok, &1}}) ++ stack
        error -> [{elem(item, 0), error} | stack]
      end
    else
      stack
    end
  end

  defp descend(_, _, stack, _), do: stack

  @doc "Go `path.Join`, as `sftp.Join`."
  defdelegate join(elements), to: SPath
  @doc "Go `path.Split`, as `sftp.Split`."
  defdelegate split(path), to: SPath
  @doc "Go `path.Match`, as `sftp.Match`."
  defdelegate match(pattern, name), to: SPath

  # Go path.Base.
  defp base(""), do: "."

  defp base(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      trimmed -> elem(SPath.split(trimmed), 1)
    end
  end

  defp unix(%DateTime{} = time), do: {:ok, DateTime.to_unix(time)}
  defp unix(seconds) when is_integer(seconds), do: {:ok, seconds}
  defp unix(_), do: error(:invalid_arguments)

  # Reply interpreters: (decoded reply, error template) -> result.
  defp ok({:status, {0, _, _}}, _), do: :ok
  defp ok(reply, error), do: status(reply, error)

  defp handle({:handle, value}, %Error{response: %{session: ref}}),
    do: {:ok, %Handle{session: ref, value: value}}

  defp handle(reply, error), do: status(reply, error)

  defp attributes({:attrs, fields}, _, name), do: {:ok, Stat.new(fields, name)}
  defp attributes(reply, error, _), do: status(reply, error)

  defp single_name({:name, [{name, _}]}, _), do: {:ok, name}
  defp single_name({:name, _}, error), do: {:error, %{error | kind: :sftp_protocol}}
  defp single_name({:status, {0, _, _}}, _), do: {:ok, ""}
  defp single_name(reply, error), do: status(reply, error)

  defp status({:status, {code, message, language}}, error) when code != 0 do
    class =
      case code do
        1 -> :eof
        2 -> :not_exist
        3 -> :permission
        _ -> nil
      end

    {:error,
     %{
       error
       | kind: :sftp_status,
         error_code: code,
         message: message,
         response: Map.merge(error.response, %{language: language, class: class})
     }}
  end

  defp status(_, %Error{} = error), do: {:error, %{error | kind: error.kind || :sftp_protocol}}

  defp file_handle(%__MODULE__{ref: ref}, %Handle{session: ref, value: value}), do: {:ok, value}
  defp file_handle(_, _), do: error(:invalid_arguments)

  defp request(session, op, args, mutation, interpret) do
    case call(session, {:request, op, args}) do
      {:ok, reply, %Error{} = template} ->
        result = interpret.(reply, template)
        if mutation, do: uncertain_malformed(result), else: result

      error ->
        if mutation, do: uncertain(error), else: error
    end
  end

  # A matched reply that does not decode leaves a mutation's outcome unknown.
  defp uncertain_malformed({:error, %Error{kind: :sftp_protocol} = error}),
    do: {:error, %{error | kind: :uncertain}}

  defp uncertain_malformed(result), do: result

  defp uncertain({:error, %Error{kind: kind, response: %{request_id: id}} = error})
       when is_integer(id) and kind != :uncertain,
       do: {:error, %{error | kind: :uncertain}}

  defp uncertain(result), do: result

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

  defp call(%__MODULE__{pid: pid, ref: ref} = session, request) when is_pid(pid) do
    tag = make_ref()

    try do
      result = GenServer.call(pid, {ref, tag, expiring(request, session)}, session.timeout + 500)
      request_id(tag)
      result
    catch
      :exit, _ ->
        id = request_id(tag)
        reason = closed_kind(session.lifetime, session.request_context)

        if request == :close,
          do: :ok,
          else:
            {:error,
             %Error{
               kind: reason,
               response: %{
                 request_id: id,
                 error: as_error(reason),
                 connection: session.connection,
                 identity: session.identity,
                 session: ref
               }
             }}
    end
  end

  defp call(_, _), do: error(:invalid_arguments)

  # A request carries the caller's absolute deadline, so one that waited in the
  # session queue past it is never sent after the caller has given up.
  defp expiring({:request, op, args}, session),
    do: {:request, op, args, now() + session.timeout}

  defp expiring(request, _), do: request

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

    deadline = request_deadline(client.connection, lifetime)

    case raw(client, target) do
      {:ok, raw} ->
        state = %{
          raw: raw,
          client: client,
          owner: owner,
          owner_monitor: Process.monitor(owner),
          ref: ref,
          lifetime: lifetime,
          buffer: <<>>,
          id: 0,
          pending: %{},
          abandoned: MapSet.new(),
          handles: MapSet.new(),
          extensions: %{},
          reader: nil,
          raw_monitor: Process.monitor(raw.pid)
        }

        with :ok <- send_packet(state, Packet.init(), deadline),
             {:ok, body, state} <- handshake(state, deadline),
             {:ok, extensions} <- Packet.version(body) do
          session = self()
          reader = spawn_link(fn -> read_loop(raw, session, ref) end)
          {:ok, %{state | extensions: extensions, reader: reader}}
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

  defp request_deadline(connection, lifetime),
    do:
      RequestContext.deadline(
        connection.request_context,
        min(lifetime.deadline, now() + connection.timeout)
      )

  # The reader forwards one chunk at a time and waits for the session to take it,
  # so backpressure stays in the bounded raw channel queue.
  defp read_loop(raw, session, ref) do
    case RawChannel.recv(raw, 60_000) do
      {:ok, bytes} ->
        send(session, {:sftp_bytes, ref, bytes})

        receive do
          {:sftp_ack, ^ref} -> read_loop(raw, session, ref)
        end

      :eof ->
        send(session, {:sftp_closed, ref})

      {:error, %Error{kind: :deadline}} ->
        read_loop(raw, session, ref)

      {:error, _} ->
        send(session, {:sftp_closed, ref})
    end
  end

  @impl true
  def handle_call({ref, _, :close}, _, %{ref: ref} = state), do: {:stop, :normal, :ok, state}

  def handle_call({ref, _, :extensions}, _, %{ref: ref} = state),
    do: {:reply, {:ok, state.extensions}, state}

  def handle_call(
        {ref, tag, {:request, op, args, expires}},
        {caller, _} = from,
        %{ref: ref} = state
      ) do
    connection = state.client.connection
    limit = min(connection.max_chunk_bytes, connection.max_request_bytes)

    with :ok <- unexpired(expires),
         :ok <- authorize(state),
         :ok <- open_handle(state, op, args),
         true <- map_size(state.pending) + MapSet.size(state.abandoned) < connection.queue_limit,
         true <- state.id < @uint32,
         body = Packet.frame(Packet.request(state.id + 1, op, args)),
         true <- byte_size(body) <= limit do
      id = state.id + 1
      state = %{state | id: id}

      # As natively, a close attempt invalidates the local handle even if the
      # server rejects it. Never send a later use-after-close request.
      state =
        if op == :close_file,
          do: %{state | handles: MapSet.delete(state.handles, args)},
          else: state

      send(caller, {tag, id})
      deadline = min(request_deadline(connection, state.lifetime), expires)

      case send_packet(state, body, deadline) do
        :ok ->
          timer = Process.send_after(self(), {:sftp_deadline, id}, max(0, deadline - now()))
          entry = %{from: from, op: op, timer: timer, template: template(state, id)}
          {:noreply, %{state | pending: Map.put(state.pending, id, entry)}}

        {:error, reason} ->
          GenServer.reply(from, {:error, failure(state, id, reason)})
          fatal(state, reason)
      end
    else
      {:error, kind} -> {:reply, error(kind), state}
      false -> {:reply, error(:sftp_limit), state}
    end
  end

  def handle_call(_, _, state), do: {:reply, error(:invalid_arguments), state}

  defp unexpired(expires), do: if(now() < expires, do: :ok, else: {:error, :deadline})

  # Never send a request for a handle this session has not opened or already closed.
  defp open_handle(state, op, {handle, _, _}) when op in [:read, :write],
    do: open_handle(state, :close_file, handle)

  defp open_handle(state, :close_file, handle),
    do: if(MapSet.member?(state.handles, handle), do: :ok, else: {:error, :invalid_arguments})

  defp open_handle(_, _, _), do: :ok

  defp authorize(state) do
    case Context.authorize(state.client.context, state.client.connection) do
      :ok -> :ok
      {:error, kind} -> {:error, kind}
    end
  end

  @impl true
  def handle_info({:sftp_bytes, ref, bytes}, %{ref: ref} = state) do
    case frames(%{state | buffer: state.buffer <> bytes}) do
      {:ok, state} ->
        send(state.reader, {:sftp_ack, ref})
        {:noreply, state}

      {:error, reason, state} ->
        fatal(state, reason)
    end
  end

  def handle_info({:sftp_closed, ref}, %{ref: ref} = state), do: fatal(state, :channel_closed)

  def handle_info({:sftp_deadline, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {entry, pending} ->
        GenServer.reply(entry.from, {:error, failure(state, id, deadline_kind(state))})
        {:noreply, %{state | pending: pending, abandoned: MapSet.put(state.abandoned, id)}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{owner_monitor: monitor} = state),
    do: fatal(state, :channel_closed)

  def handle_info({:DOWN, monitor, :process, _, _}, %{raw_monitor: monitor} = state),
    do: fatal(state, :channel_closed)

  def handle_info(_, state), do: {:noreply, state}

  defp deadline_kind(state) do
    case closed_kind(state.lifetime, state.client.connection.request_context) do
      :channel_closed -> :deadline
      kind -> kind
    end
  end

  defp frames(%{buffer: <<length::32, rest::binary>>} = state) do
    limit = min(@packet_limit, state.client.connection.max_response_bytes)

    cond do
      length not in 1..limit ->
        {:error, :sftp_limit, state}

      byte_size(rest) < length ->
        {:ok, state}

      true ->
        <<body::binary-size(length), rest::binary>> = rest

        case route(%{state | buffer: rest}, body) do
          {:ok, state} -> frames(state)
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp frames(state), do: {:ok, state}

  defp route(state, body) do
    with {:ok, type, id, payload} <- Packet.split(body) do
      case Map.pop(state.pending, id) do
        {nil, _} ->
          if MapSet.member?(state.abandoned, id),
            do: {:ok, %{state | abandoned: MapSet.delete(state.abandoned, id)}},
            else: {:error, :sftp_protocol}

        {entry, pending} ->
          Process.cancel_timer(entry.timer)
          state = %{state | pending: pending}
          reply = decode(type, payload)
          state = track(state, entry.op, reply)
          GenServer.reply(entry.from, {:ok, reply, entry.template})
          {:ok, state}
      end
    end
  end

  defp decode(type, payload) do
    case Packet.reply(type, payload) do
      :malformed -> {:malformed, type}
      reply -> reply
    end
  end

  defp track(state, :open, {:handle, handle}),
    do: %{state | handles: MapSet.put(state.handles, handle)}

  defp track(state, _, _), do: state

  defp template(state, id),
    do: %Error{
      kind: :sftp_protocol,
      response: %{
        request_id: id,
        session: state.ref,
        connection: state.client.connection,
        identity: state.client.context.identity
      }
    }

  defp failure(state, id, reason) do
    error = as_error(reason)

    %Error{
      kind: error.kind,
      response: %{
        request_id: id,
        error: error,
        session: state.ref,
        connection: state.client.connection,
        identity: state.client.context.identity
      }
    }
  end

  # Ends the session: every pending request fails; request/5 marks mutations uncertain.
  defp fatal(state, reason) do
    for {id, entry} <- state.pending do
      Process.cancel_timer(entry.timer)
      GenServer.reply(entry.from, {:error, failure(state, id, reason)})
    end

    {:stop, :normal, %{state | pending: %{}}}
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

  defp handshake(state, deadline) do
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
  def terminate(_, state) do
    for {id, entry} <- state.pending,
        do: GenServer.reply(entry.from, {:error, failure(state, id, :channel_closed)})

    # The reader may be waiting for an acknowledgement that a failed session never sends.
    if state.reader, do: Process.exit(state.reader, :kill)
    RawChannel.close(state.raw)
  end

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
end

defimpl Inspect, for: Opsmaru.Incus.SFTP do
  def inspect(_, _), do: "#Opsmaru.Incus.SFTP<native session redacted>"
end
