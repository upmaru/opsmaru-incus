defmodule Opsmaru.Incus.SFTPOperationsReferenceTest do
  @moduledoc """
  S09: SFTP path, metadata and file operations compared with the unchanged pinned
  `pkg/sftp` v1.13.10 client returned by `GetInstanceFileSFTP` and
  `GetStoragePoolVolumeFileSFTP`.

  The upgrade fixture relays each session to an unchanged `pkg/sftp` server rooted in
  a private temporary directory and records every frame. The pinned client runs a
  script live; our client then runs the same script against the recorded replies,
  where every request packet (ids normalized) and every result must agree, and
  finally runs it live against a fresh copy of the same tree.

  Go's pipelined `WriteTo` keeps reading ahead until it handles the end of the
  file, so how many reads it sends past the end depends on timing. The replay
  therefore skips recorded reads answered with end of file that our client did
  not send, and answers our extra reads with end of file only when they start at
  or past an offset already answered that way on the same handle. Both are
  listed and checked; nothing else may differ.
  """
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Server, SFTP}
  alias Opsmaru.Incus.SFTP.Stat
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  @integration Path.expand("../.integration", __DIR__)
  @driver Path.join(@integration, "sftp-operations-driver")
  @server Path.join(@integration, "sftp-server-fixture")
  # A regular file larger than eight 128 KiB packets, so WriteTo reads ahead.
  @big 1_060_921

  setup_all do
    File.mkdir_p!(@integration)

    for {output, package} <- [{@driver, "./sftpops"}, {@server, "./sftpserver"}] do
      {out, status} =
        System.cmd("mise", ["exec", "--", "go", "build", "-o", output, package],
          cd: Path.expand("reference", __DIR__),
          env: [{"GOTOOLCHAIN", "local"}],
          stderr_to_stdout: true
        )

      assert status == 0, out
    end

    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "op-sftp-ops-#{System.unique_integer([:positive])}")
    File.mkdir!(base)
    File.chmod!(base, 0o700)
    on_exit(fn -> File.rm_rf!(base) end)
    # A canonical root keeps RealPath results identical across runs.
    root = Path.join(base, "tree")
    File.mkdir!(root)
    {real, 0} = System.cmd("realpath", [root])
    %{base: base, root: String.trim(real)}
  end

  for transport <- [:gen_tcp, :ssl], kind <- [:instance, :volume] do
    test(
      "#{transport} #{kind}: every path and metadata operation matches the pinned client",
      context,
      do: differential(context, unquote(transport), unquote(kind), :paths)
    )

    test(
      "#{transport} #{kind}: every file operation matches the pinned client",
      context,
      do: differential(context, unquote(transport), unquote(kind), :files)
    )
  end

  defp differential(%{base: base, root: root}, transport, kind, script) do
    identity = identity(transport, base)
    steps = steps(script, File.stat!(base))

    # 1. The pinned client, live against the unchanged pkg/sftp server.
    reset_tree(root)
    live = backend(base, transport, identity, {:live, root, self()})
    native = oracle(native_input(live, identity, kind, steps))
    assert Map.has_key?(native, "steps"), inspect(native)
    exchange = recorded()

    # 2. Our client against the recorded replies: identical requests and results.
    replay = backend(base, transport, identity, {:replay, exchange, self()})
    assert {:ok, session} = open(client(replay, identity), kind)
    ours = run(session, steps)
    assert_steps(ours, native["steps"], steps)
    SFTP.close(session)
    assert_receive {:sftp_replay_done, mismatches, remaining, read_ahead}, 5_000
    assert mismatches == []
    assert remaining == 0
    if script == :paths, do: assert(read_ahead == [])

    # 3. Our client live against a fresh copy of the same tree.
    reset_tree(root)
    live = backend(base, transport, identity, {:live, root, self()})
    assert {:ok, session} = open(client(live, identity), kind)
    assert_steps(volatile(run(session, steps)), volatile(native["steps"]), steps)
    SFTP.close(session)
    recorded()
  end

  test "Go path helpers agree with the pinned sftp.Join, Split and Match", %{base: base} do
    joins = [
      [],
      [""],
      ["a", "b"],
      ["a", "", "b"],
      ["", "a"],
      ["/", "a", "../b"],
      ["a/", "/b/", "./c/."],
      ["..", "a", "..", ".."],
      ["/..", "x"],
      ["a//b", "c/../../.."]
    ]

    splits = ["", "a", "/", "a/", "a/b", "/a/b/", "a//b", "雪/f"]

    matches =
      for pattern <- [
            "*",
            "a*",
            "*b",
            "a?c",
            "[a-c]x",
            "[^a-c]x",
            "[!a]",
            "\\*",
            "a\\",
            "[",
            "[a",
            "[]",
            "[-]",
            "[a-]",
            "[\\]]",
            "a[",
            "*x[",
            "?",
            "雪?",
            "[雪]",
            "a/*",
            "*/b"
          ],
          name <- ["", "a", "abc", "ab", "bx", "dx", "*", "]", "a/b", "雪x", "雪", "-"],
          do: {pattern, name}

    steps =
      Enum.map(joins, &%{op: "join", elems: &1}) ++
        Enum.map(splits, &%{op: "split", path: &1}) ++
        Enum.map(matches, fn {pattern, name} -> %{op: "match", pattern: pattern, name: name} end)

    fixture = backend(base, :gen_tcp, nil, {:live, base, self()})
    native = oracle(native_input(fixture, nil, :instance, steps))
    recorded()

    ours =
      Enum.map(steps, fn
        %{op: "join", elems: elems} -> ok("join", SFTP.join(elems))
        %{op: "split", path: path} -> ok("split", Tuple.to_list(SFTP.split(path)))
        %{op: "match", pattern: p, name: n} -> result("match", SFTP.match(p, n))
      end)

    assert ours == native["steps"]
  end

  defp assert_steps(ours, native, steps) do
    assert length(ours) == length(native)

    for {{mine, theirs}, step} <- Enum.zip(Enum.zip(ours, native), steps),
        do: assert({step, mine} == {step, theirs})
  end

  # Every pinned client path/metadata call, including compound steps and errors.
  defp steps(:paths, stat) do
    [
      %{op: "stat", path: "a/f1"},
      %{op: "stat", path: "missing"},
      %{op: "lstat", path: "a/link"},
      %{op: "stat", path: "a/link"},
      %{op: "stat", path: "a/"},
      %{op: "lstat", path: "a/雪 file"},
      %{op: "read_dir", path: "a"},
      %{op: "read_dir", path: "missing"},
      %{op: "read_dir", path: "a/f1"},
      %{op: "read_link", path: "a/link"},
      %{op: "read_link", path: "a/f1"},
      %{op: "real_path", path: "a/../a/sub"},
      %{op: "getwd"},
      %{op: "has_extension", name: "statvfs@openssh.com"},
      %{op: "has_extension", name: "absent@example.com"},
      %{op: "mkdir", path: "n"},
      %{op: "mkdir", path: "n"},
      %{op: "mkdir_all", path: "m/x/y/"},
      %{op: "mkdir_all", path: "m/x"},
      %{op: "mkdir_all", path: "a/f1/q"},
      %{op: "mkdir_all", path: "a/f1"},
      %{op: "chmod", path: "a/f1", mode: 0o640},
      %{op: "chmod", path: "missing", mode: 0o600},
      %{op: "chown", path: "a/f1", uid: stat.uid, gid: stat.gid},
      %{op: "chtimes", path: "a/f1", atime: 1_000_000_000, mtime: 1_100_000_000},
      %{op: "truncate", path: "a/f1", size: 2},
      %{op: "set_extended_data", path: "a/f1", extended: [["x@example.com", "v"]]},
      %{op: "stat", path: "a/f1"},
      %{op: "stat_vfs", path: "."},
      %{op: "link", path: "a/f1", path2: "a/hard"},
      %{op: "symlink", path: "f1", path2: "a/sym2"},
      %{op: "lstat", path: "a/sym2"},
      %{op: "read_link", path: "a/sym2"},
      %{op: "rename", path: "a/hard", path2: "a/hard2"},
      %{op: "posix_rename", path: "a/hard2", path2: "a/hard3"},
      %{op: "rename", path: "missing", path2: "x"},
      %{op: "remove", path: "a/sym2"},
      %{op: "remove", path: "e"},
      %{op: "remove", path: "missing"},
      %{op: "remove", path: "a/sub"},
      %{op: "remove_directory", path: "m/x/y"},
      %{op: "remove_directory", path: "a"},
      %{op: "glob", pattern: "a/*"},
      %{op: "glob", pattern: "a/f?"},
      %{op: "glob", pattern: "*/f*"},
      %{op: "glob", pattern: "[a]/*"},
      %{op: "glob", pattern: "a/["},
      %{op: "glob", pattern: "zz"},
      %{op: "glob", pattern: "a/f1"},
      # pkg/sftp joins the directory with the Lstat name, so "a/" yields "a/a".
      %{op: "glob", pattern: "a/"},
      %{op: "glob", pattern: "missing/*"},
      %{op: "walk", path: "a", skip: ["a/sub"]},
      %{op: "walk", path: ".", skip: []},
      %{op: "walk", path: "missing", skip: []},
      %{op: "remove_all", path: "m"},
      %{op: "stat", path: "m"},
      %{op: "remove_all", path: "missing"},
      %{op: "remove_all", path: "a"},
      %{op: "read_dir", path: "."}
    ]
  end

  # Every *sftp.File method: cursor and positional I/O, end of file, pipelined
  # reads and read-ahead, one-at-a-time and pipelined uploads, attributes, closed
  # files and the open flags.
  defp steps(:files, stat) do
    [
      %{op: "open", file: "f", path: "a/f1"},
      %{op: "read", file: "f", count: 3},
      %{op: "read", file: "f", count: 0},
      %{op: "read", file: "f", count: 10},
      %{op: "read", file: "f", count: 10},
      %{op: "seek", file: "f", offset: 1, whence: "start"},
      %{op: "seek", file: "f", offset: 2, whence: "current"},
      %{op: "seek", file: "f", offset: -1, whence: "end"},
      %{op: "seek", file: "f", offset: -10, whence: "end"},
      %{op: "read_at", file: "f", offset: 1, count: 3},
      %{op: "seek", file: "f", offset: 0, whence: "current"},
      %{op: "write", file: "f", data: %{size: 3, seed: 1}},
      %{op: "file_stat", file: "f"},
      %{op: "write_to", file: "f"},
      %{op: "sync", file: "f"},
      %{op: "close", file: "f"},
      %{op: "close", file: "f"},
      %{op: "read", file: "f", count: 1},
      %{op: "read_at", file: "f", offset: 0, count: 1},
      %{op: "file_stat", file: "f"},
      %{op: "open", file: "m", path: "missing"},
      %{op: "open_file", file: "x", path: "a/f1", flags: ["write_only", "create", "exclusive"]},
      %{op: "open", file: "b", path: "big"},
      %{op: "read", file: "b", count: 300_000},
      %{op: "read_at", file: "b", offset: @big - 921, count: 200_000},
      %{op: "read_at", file: "b", offset: @big - 21, count: 100},
      %{op: "read_at", file: "b", offset: 2_000_000, count: 10},
      %{op: "seek", file: "b", offset: 0, whence: "start"},
      %{op: "write_to", file: "b"},
      %{op: "seek", file: "b", offset: 0, whence: "current"},
      %{op: "seek", file: "b", offset: 1_000_000, whence: "start"},
      %{op: "write_to", file: "b"},
      %{op: "seek", file: "b", offset: 0, whence: "current"},
      %{op: "close", file: "b"},
      %{op: "create", file: "w", path: "new"},
      %{op: "write", file: "w", data: %{size: 300_000, seed: 3}},
      %{op: "write_at", file: "w", offset: 10, data: %{size: 5, seed: 4}},
      %{op: "write", file: "w", data: %{size: 0, seed: 0}},
      %{op: "seek", file: "w", offset: 0, whence: "current"},
      %{op: "read_at", file: "w", offset: 0, count: 300_000},
      %{op: "file_chmod", file: "w", mode: 0o600},
      %{op: "file_chown", file: "w", uid: stat.uid, gid: stat.gid},
      %{op: "file_truncate", file: "w", size: 200_000},
      %{op: "file_set_extended_data", file: "w", extended: [["x@example.com", "v"]]},
      %{op: "file_stat", file: "w"},
      %{op: "seek", file: "w", offset: 0, whence: "end"},
      %{op: "read_from", file: "w", data: %{size: 300_000, seed: 5}},
      %{op: "seek", file: "w", offset: 0, whence: "current"},
      %{
        op: "read_from_with_concurrency",
        file: "w",
        data: %{size: 400_000, seed: 6},
        concurrency: 2
      },
      %{op: "seek", file: "w", offset: 0, whence: "current"},
      %{op: "read_from", file: "w", data: %{size: 0, seed: 0}},
      %{op: "seek", file: "w", offset: 0, whence: "start"},
      %{op: "write_to", file: "w"},
      %{op: "close", file: "w"},
      %{op: "open_file", file: "a", path: "z", flags: ["write_only", "append"]},
      %{op: "write", file: "a", data: %{size: 4, seed: 9}},
      %{op: "close", file: "a"},
      %{op: "open_file", file: "rw", path: "z", flags: ["read_write"]},
      %{op: "read", file: "rw", count: 100},
      %{op: "close", file: "rw"},
      %{op: "open_file", file: "both", path: "z", flags: ["write_only", "read_write"]},
      %{op: "read", file: "both", count: 1},
      %{op: "close", file: "both"},
      %{op: "stat", path: "new"},
      %{op: "stat", path: "z"}
    ]
  end

  defp reset_tree(root) do
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "a/sub"))
    File.mkdir_p!(Path.join(root, "e"))
    File.write!(Path.join(root, "a/f1"), "hello")
    File.write!(Path.join(root, "a/雪 file"), "snow")
    File.write!(Path.join(root, "a/sub/f2"), "x")
    File.write!(Path.join(root, "z"), "zz")
    File.write!(Path.join(root, "big"), generate(%{size: @big, seed: 7}))
    File.chmod!(Path.join(root, "a/f1"), 0o644)
    :ok = File.ln_s("f1", Path.join(root, "a/link"))

    # Fixed times make the native and live attribute results comparable.
    for path <- ["a/sub/f2", "a/sub", "a/f1", "a/雪 file", "z", "big", "e", "a", "."] do
      System.cmd("touch", ["-h", "-t", "202001020304.05", Path.join(root, path)])
    end
  end

  defp run(session, steps) do
    {results, _} = Enum.map_reduce(steps, %{}, &file_step(session, &1, &2))
    results
  end

  # Byte i is (i * 31 + seed) mod 251, as the Go driver generates it.
  defp generate(%{size: size, seed: seed}),
    do: :binary.list_to_bin(for(i <- 0..(size - 1)//1, do: rem(i * 31 + seed, 251)))

  defp summary(bytes),
    do: %{
      "n" => byte_size(bytes),
      "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }

  defp file_step(session, %{op: op, file: name, path: path} = step, files)
       when op in ["open", "create", "open_file"] do
    result =
      case op do
        "open" -> SFTP.open(session, path)
        "create" -> SFTP.create(session, path)
        "open_file" -> SFTP.open_file(session, path, Enum.map(step.flags, &String.to_atom/1))
      end

    case result do
      {:ok, file} -> {ok(op, SFTP.File.name(file)), Map.put(files, name, file)}
      error -> {result(op, error), files}
    end
  end

  defp file_step(_, %{op: op, file: name}, files) when not is_map_key(files, name),
    do: {%{"op" => op, "error" => %{"class" => "unopened"}}, files}

  defp file_step(_, %{file: name} = step, files),
    do: {file_op(files[name], step), files}

  defp file_step(session, step, files), do: {step(session, step), files}

  defp file_op(file, %{op: "read", count: count}),
    do: read_result("read", SFTP.File.read(file, count))

  defp file_op(file, %{op: "read_at", offset: offset, count: count}),
    do: read_result("read_at", SFTP.File.read_at(file, offset, count))

  defp file_op(file, %{op: "write", data: data}),
    do: write_result("write", SFTP.File.write(file, generate(data)), data.size)

  defp file_op(file, %{op: "write_at", offset: offset, data: data}),
    do: write_result("write_at", SFTP.File.write_at(file, offset, generate(data)), data.size)

  defp file_op(file, %{op: "seek", offset: offset, whence: whence}),
    do: result("seek", SFTP.File.seek(file, offset, String.to_existing_atom(whence)))

  defp file_op(file, %{op: "write_to"}) do
    parent = self()
    ref = make_ref()

    sink = fn chunk ->
      send(parent, {ref, chunk})
      :ok
    end

    result = SFTP.File.write_to(file, sink)
    sunk = summary(sunk(ref, []))

    case result do
      {:ok, written} -> ok("write_to", %{sunk | "n" => written})
      {:error, error} -> partial("write_to", error, %{sunk | "n" => error.response.count})
    end
  end

  defp file_op(file, %{op: "read_from", data: data}),
    do: count_result("read_from", SFTP.File.read_from(file, source(data)))

  defp file_op(file, %{op: "read_from_with_concurrency", data: data, concurrency: concurrency}),
    do:
      count_result(
        "read_from_with_concurrency",
        SFTP.File.read_from_with_concurrency(file, source(data), concurrency)
      )

  defp file_op(file, %{op: "file_stat"}), do: stat_result("file_stat", SFTP.File.stat(file))

  defp file_op(file, %{op: "file_chmod", mode: mode}),
    do: result("file_chmod", SFTP.File.chmod(file, mode))

  defp file_op(file, %{op: "file_chown", uid: uid, gid: gid}),
    do: result("file_chown", SFTP.File.chown(file, uid, gid))

  defp file_op(file, %{op: "file_truncate", size: size}),
    do: result("file_truncate", SFTP.File.truncate(file, size))

  defp file_op(file, %{op: "file_set_extended_data", extended: pairs}),
    do:
      result(
        "file_set_extended_data",
        SFTP.File.set_extended_data(file, Enum.map(pairs, &List.to_tuple/1))
      )

  defp file_op(file, %{op: "sync"}), do: result("sync", SFTP.File.sync(file))
  defp file_op(file, %{op: "close"}), do: result("close", SFTP.File.close(file))

  defp sunk(ref, acc) do
    receive do
      {^ref, chunk} -> sunk(ref, [acc | chunk])
    after
      0 -> IO.iodata_to_binary(acc)
    end
  end

  # Odd-sized chunks, so grouping into 128 KiB WRITEs is our client's work.
  defp source(data) do
    bytes = generate(data)

    Stream.unfold(bytes, fn
      <<>> -> nil
      <<chunk::binary-size(100_000), rest::binary>> -> {chunk, rest}
      rest -> {rest, <<>>}
    end)
  end

  defp read_result(op, {:ok, data}), do: ok(op, summary(data))

  defp read_result(op, {:eof, data}),
    do: %{"op" => op, "error" => %{"class" => "eof"}, "partial" => summary(data)}

  defp read_result(op, {:error, error}),
    do: partial(op, error, summary(Map.get(error.response || %{}, :data, "")))

  defp write_result(op, :ok, size), do: ok(op, %{"n" => size})
  defp write_result(op, {:error, error}, _), do: partial(op, error, %{"n" => count(error)})

  defp count_result(op, {:ok, count}), do: ok(op, %{"n" => count})
  defp count_result(op, {:error, error}), do: partial(op, error, %{"n" => count(error)})

  defp count(%Error{response: %{count: count}}), do: count
  defp count(_), do: 0

  defp partial(op, error, value),
    do: %{"op" => op, "error" => error_json(error), "partial" => value}

  defp step(session, %{op: "stat", path: path}), do: stat_result("stat", SFTP.stat(session, path))

  defp step(session, %{op: "lstat", path: path}),
    do: stat_result("lstat", SFTP.lstat(session, path))

  defp step(session, %{op: "read_dir", path: path}) do
    case SFTP.read_dir(session, path) do
      {:ok, entries} -> ok("read_dir", Enum.map(entries, &stat_json/1))
      error -> result("read_dir", error)
    end
  end

  defp step(session, %{op: "read_link", path: path}),
    do: result("read_link", SFTP.read_link(session, path))

  defp step(session, %{op: "real_path", path: path}),
    do: result("real_path", SFTP.real_path(session, path))

  defp step(session, %{op: "getwd"}), do: result("getwd", SFTP.getwd(session))

  defp step(session, %{op: "has_extension", name: name}) do
    case SFTP.has_extension(session, name) do
      {:ok, data} -> ok("has_extension", %{"found" => true, "data" => data})
      :error -> ok("has_extension", %{"found" => false, "data" => ""})
    end
  end

  defp step(session, %{op: "link", path: old, path2: new}),
    do: result("link", SFTP.link(session, old, new))

  defp step(session, %{op: "symlink", path: old, path2: new}),
    do: result("symlink", SFTP.symlink(session, old, new))

  defp step(session, %{op: "chmod", path: path, mode: mode}),
    do: result("chmod", SFTP.chmod(session, path, mode))

  defp step(session, %{op: "chown", path: path, uid: uid, gid: gid}),
    do: result("chown", SFTP.chown(session, path, uid, gid))

  defp step(session, %{op: "chtimes", path: path, atime: atime, mtime: mtime}),
    do: result("chtimes", SFTP.chtimes(session, path, atime, mtime))

  defp step(session, %{op: "truncate", path: path, size: size}),
    do: result("truncate", SFTP.truncate(session, path, size))

  defp step(session, %{op: "set_extended_data", path: path, extended: pairs}),
    do:
      result(
        "set_extended_data",
        SFTP.set_extended_data(session, path, Enum.map(pairs, &List.to_tuple/1))
      )

  defp step(session, %{op: "stat_vfs", path: path}) do
    case SFTP.stat_vfs(session, path) do
      {:ok, vfs} ->
        ok("stat_vfs", vfs |> Map.from_struct() |> Map.new(fn {k, v} -> {to_string(k), v} end))

      error ->
        result("stat_vfs", error)
    end
  end

  defp step(session, %{op: op, path: path})
       when op in ["remove", "remove_directory", "mkdir", "mkdir_all", "remove_all"],
       do: result(op, apply(SFTP, String.to_existing_atom(op), [session, path]))

  defp step(session, %{op: op, path: old, path2: new}) when op in ["rename", "posix_rename"],
    do: result(op, apply(SFTP, String.to_existing_atom(op), [session, old, new]))

  defp step(session, %{op: "glob", pattern: pattern}),
    do: result("glob", SFTP.glob(session, pattern))

  defp step(session, %{op: "walk", path: path, skip: skip}) do
    items =
      session
      |> SFTP.walk(path, skip: fn path, _ -> path in skip end)
      |> Enum.map(fn
        {path, {:ok, stat}} -> %{"path" => path, "stat" => stat_json(stat), "error" => nil}
        {path, {:error, error}} -> %{"path" => path, "stat" => nil, "error" => error_json(error)}
      end)

    ok("walk", items)
  end

  defp stat_result(op, {:ok, stat}), do: ok(op, stat_json(stat))
  defp stat_result(op, error), do: result(op, error)

  defp result(op, :ok), do: ok(op, nil)
  defp result(op, {:ok, value}), do: ok(op, value)
  defp result(op, {:error, error}), do: %{"op" => op, "error" => error_json(error)}
  defp ok(op, value), do: %{"op" => op, "ok" => value}

  defp stat_json(%Stat{} = stat),
    do: %{
      "name" => stat.name,
      "size" => stat.size,
      "mode" => stat.mode,
      "go_mode" => stat.file_mode,
      "is_dir" => Stat.dir?(stat),
      "mtime" => stat.mtime,
      "atime" => stat.atime,
      "uid" => stat.uid,
      "gid" => stat.gid,
      "extended" => Enum.map(stat.extended, &Tuple.to_list/1)
    }

  defp error_json(:bad_pattern), do: %{"class" => "bad_pattern"}
  defp error_json(%Error{kind: :bad_pattern}), do: %{"class" => "bad_pattern"}

  defp error_json(%Error{kind: :not_directory, response: response}),
    do: %{"class" => "not_dir", "op" => response.op, "path" => response.path}

  defp error_json(%Error{kind: :sftp_status} = error), do: status_json(error)

  # os.ErrClosed and os.ErrInvalid, as the Go driver reports them.
  defp error_json(%Error{kind: :file_closed}),
    do: %{"class" => "other", "text" => "file already closed"}

  defp error_json(%Error{kind: :invalid_arguments}),
    do: %{"class" => "other", "text" => "invalid argument"}

  defp error_json(%Error{kind: kind}), do: %{"class" => "other", "kind" => to_string(kind)}

  defp status_json(error) do
    location =
      Map.take(error.response, [:op, :path]) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    case error.response.class do
      nil ->
        Map.merge(location, %{
          "class" => "status",
          "code" => error.error_code,
          "message" => error.message
        })

      class ->
        Map.put(location, "class", to_string(class))
    end
  end

  # Live runs differ from the recorded run only in times the server sets itself and
  # in filesystem counters.
  defp volatile(steps) do
    Enum.map(steps, fn
      %{"op" => "stat_vfs", "ok" => value} = step when is_map(value) ->
        %{step | "ok" => Map.keys(value)}

      step ->
        scrub(step)
    end)
  end

  defp scrub(%{"mtime" => _, "atime" => _} = stat),
    do: stat |> Map.drop(["mtime", "atime"]) |> scrub()

  defp scrub(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, scrub(v)} end)
  defp scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  defp scrub(value), do: value

  defp identity(:gen_tcp, _), do: nil
  defp identity(:ssl, base), do: TLSIdentity.generate(base, "sftp-ops", "localhost")

  defp backend(base, transport, identity, mode) do
    endpoint =
      if transport == :gen_tcp,
        do: [path: Path.join(base, "s#{System.unique_integer([:positive])}")],
        else: [
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            verify: :verify_peer,
            fail_if_no_peer_cert: true,
            cacertfile: identity.cafile
          ]
        ]

    handler = fn request ->
      if request.target == "/1.0" do
        %{
          status: 200,
          body: %{
            type: "sync",
            metadata: %{api_version: "1.0", api_extensions: ["custom_volume_sftp"]}
          }
        }
      else
        %{upgrade: fn transport, socket -> serve(transport, socket, mode) end}
      end
    end

    start_supervised!({HTTPFixture, [transport: transport, handler: handler] ++ endpoint},
      id: make_ref()
    )
  end

  defp serve(transport, socket, mode) do
    :ok =
      transport.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: sftp\r\n\r\n"
      )

    case mode do
      {:live, root, parent} -> relay(transport, socket, root, parent)
      {:replay, exchange, parent} -> replay(transport, socket, exchange, parent)
    end
  end

  # Relays one session to the unchanged pkg/sftp server and records each frame.
  defp relay(transport, socket, root, parent) do
    port =
      Port.open({:spawn_executable, @server}, [:binary, :exit_status, args: [root], cd: root])

    setopts(transport, socket, active: :once)
    relay_loop(transport, socket, port, parent, {"", ""})
  end

  defp relay_loop(transport, socket, port, parent, {client, server}) do
    receive do
      {tag, ^socket, bytes} when tag in [:tcp, :ssl] ->
        Port.command(port, bytes)
        setopts(transport, socket, active: :once)
        client = record(client <> bytes, :client, parent)
        relay_loop(transport, socket, port, parent, {client, server})

      {tag, ^socket} when tag in [:tcp_closed, :ssl_closed] ->
        Port.close(port)
        send(parent, :sftp_relay_closed)

      {^port, {:data, bytes}} ->
        transport.send(socket, bytes)
        server = record(server <> bytes, :server, parent)
        relay_loop(transport, socket, port, parent, {client, server})

      {^port, {:exit_status, _}} ->
        transport.close(socket)
        send(parent, :sftp_relay_closed)
    end
  end

  defp record(<<length::32, body::binary-size(length), rest::binary>>, side, parent) do
    send(parent, {:sftp_frame, side, body})
    record(rest, side, parent)
  end

  defp record(buffer, _, _), do: buffer

  defp setopts(:gen_tcp, socket, opts), do: :inet.setopts(socket, opts)
  defp setopts(:ssl, socket, opts), do: :ssl.setopts(socket, opts)

  # The pinned exchange: the version reply, then each request with its reply.
  defp recorded do
    assert_receive :sftp_relay_closed, 5_000
    frames = drain([])
    [version | replies] = for {:server, body} <- frames, do: body
    [_init | requests] = for {:client, body} <- frames, do: body
    replies = Map.new(replies, fn <<_, id::32, _::binary>> = body -> {id, body} end)
    {version, Enum.map(requests, fn <<_, id::32, _::binary>> = body -> {body, replies[id]} end)}
  end

  defp drain(acc) do
    receive do
      {:sftp_frame, side, body} -> drain([{side, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp replay(transport, socket, {version, exchange}, parent) do
    {:ok, _init} = receive_frame(transport, socket)
    :ok = transport.send(socket, frame(version))
    replay_loop(transport, socket, exchange, parent, %{mismatches: [], read_ahead: [], eof: %{}})
  end

  defp replay_loop(transport, socket, exchange, parent, state) do
    case receive_frame(transport, socket) do
      {:ok, ours} ->
        {reply, exchange, state} = answer(ours, exchange, state)
        :ok = transport.send(socket, frame(reply))
        replay_loop(transport, socket, exchange, parent, state)

      :closed ->
        send(
          parent,
          {:sftp_replay_done, Enum.reverse(state.mismatches), length(exchange),
           Enum.reverse(state.read_ahead)}
        )
    end
  end

  defp answer(<<type, id::32, rest::binary>> = ours, exchange, state) do
    case exchange do
      [
        {<<^type, _::32, ^rest::binary>>, <<reply_type, _::32, reply::binary>> = recorded}
        | exchange
      ] ->
        {<<reply_type, id::32, reply::binary>>, exchange, note_eof(ours, recorded, state)}

      # Go read further ahead than we did: skip its read answered with end of file.
      [{<<5, _::binary>> = read, <<101, _::32, 1::32, _::binary>>} | exchange] ->
        answer(ours, exchange, %{state | read_ahead: [{:skipped, read} | state.read_ahead]})

      _ ->
        case past_eof(ours, state) do
          true ->
            eof = <<101, id::32, 1::32, 0::32, 0::32>>
            {eof, exchange, %{state | read_ahead: [{:extra, ours} | state.read_ahead]}}

          false ->
            {expected, exchange} =
              case exchange do
                [{request, _} | rest] -> {request, rest}
                [] -> {:unexpected, []}
              end

            failure = <<101, id::32, 4::32, 0::32, 0::32>>
            {failure, exchange, %{state | mismatches: [{ours, expected} | state.mismatches]}}
        end
    end
  end

  defp note_eof(<<5, _::32, rest::binary>>, <<101, _::32, 1::32, _::binary>>, state) do
    {handle, offset} = read_position(rest)
    %{state | eof: Map.update(state.eof, handle, offset, &min(&1, offset))}
  end

  defp note_eof(_, _, state), do: state

  # Our extra read-ahead must start at or past an offset already answered with
  # end of file on the same handle.
  defp past_eof(<<5, _::32, rest::binary>>, state) do
    {handle, offset} = read_position(rest)
    is_map_key(state.eof, handle) and offset >= state.eof[handle]
  end

  defp past_eof(_, _), do: false

  defp read_position(<<length::32, handle::binary-size(length), offset::64, _::32>>),
    do: {handle, offset}

  defp receive_frame(transport, socket) do
    with {:ok, <<length::32>>} <- transport.recv(socket, 4, 5_000),
         {:ok, body} <- transport.recv(socket, length, 5_000) do
      {:ok, body}
    else
      _ -> :closed
    end
  end

  defp frame(body), do: <<byte_size(body)::32, body::binary>>

  defp client(fixture, identity) do
    endpoint = HTTPFixture.endpoint(fixture)

    defaults = [
      owner: :fixture,
      project: "project +",
      member: "member +",
      timeout: 2_000,
      stream_timeout: 10_000,
      max_chunk_bytes: 132_096
    ]

    connection =
      if endpoint[:socket],
        do: Connection.unix!(endpoint.socket, defaults),
        else:
          Connection.https!(
            endpoint.url,
            defaults ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          )

    %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: ["custom_volume_sftp"]}
    }
  end

  defp open(client, :instance), do: Incus.file_sftp(client, "name+/@ é")
  defp open(client, :volume), do: Incus.volume_file_sftp(client, "pool+@ ", "custom", "name+/@ é")

  defp native_input(fixture, identity, kind, steps) do
    endpoint = HTTPFixture.endpoint(fixture)

    input = %{
      Kind: Atom.to_string(kind),
      Name: "name+/@ é",
      Pool: "pool+@ ",
      VolumeType: "custom",
      Project: "project +",
      Target: "member +",
      Steps: steps
    }

    if endpoint[:socket],
      do: Map.put(input, :Socket, endpoint.socket),
      else:
        Map.merge(input, %{
          URL: endpoint.url,
          CA: File.read!(identity.cafile),
          Cert: File.read!(identity.certfile),
          Key: File.read!(identity.keyfile)
        })
  end

  defp oracle(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} -> collect(port, data <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(data)
      {^port, {:exit_status, status}} -> flunk("SFTP operations driver exited #{status}: #{data}")
    after
      15_000 ->
        Port.close(port)
        flunk("SFTP operations driver deadline")
    end
  end
end
