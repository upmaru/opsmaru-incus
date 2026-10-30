defmodule Opsmaru.Incus.SFTPOperationsReferenceTest do
  @moduledoc """
  S09 PR 1: SFTP path and metadata operations compared with the unchanged pinned
  `pkg/sftp` v1.13.10 client returned by `GetInstanceFileSFTP` and
  `GetStoragePoolVolumeFileSFTP`.

  The upgrade fixture relays each session to an unchanged `pkg/sftp` server rooted in
  a private temporary directory and records every frame. The pinned client runs a
  script live; our client then runs the same script against the recorded replies,
  where every request packet (ids normalized) and every result must agree, and
  finally runs it live against a fresh copy of the same tree.
  """
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Server, SFTP}
  alias Opsmaru.Incus.SFTP.Stat
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  @integration Path.expand("../.integration", __DIR__)
  @driver Path.join(@integration, "sftp-operations-driver")
  @server Path.join(@integration, "sftp-server-fixture")

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
    test "#{transport} #{kind}: every path and metadata operation matches the pinned client",
         %{base: base, root: root} do
      transport = unquote(transport)
      kind = unquote(kind)
      identity = identity(transport, base)
      steps = steps(File.stat!(base))

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
      assert ours == native["steps"]
      SFTP.close(session)
      assert_receive {:sftp_replay_done, mismatches, remaining}, 5_000
      assert mismatches == []
      assert remaining == 0

      # 3. Our client live against a fresh copy of the same tree.
      reset_tree(root)
      live = backend(base, transport, identity, {:live, root, self()})
      assert {:ok, session} = open(client(live, identity), kind)
      assert volatile(run(session, steps)) == volatile(native["steps"])
      SFTP.close(session)
      recorded()
    end
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

  # Every pinned client path/metadata call, including compound steps and errors.
  defp steps(stat) do
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

  defp reset_tree(root) do
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "a/sub"))
    File.mkdir_p!(Path.join(root, "e"))
    File.write!(Path.join(root, "a/f1"), "hello")
    File.write!(Path.join(root, "a/雪 file"), "snow")
    File.write!(Path.join(root, "a/sub/f2"), "x")
    File.write!(Path.join(root, "z"), "zz")
    File.chmod!(Path.join(root, "a/f1"), 0o644)
    :ok = File.ln_s("f1", Path.join(root, "a/link"))

    # Fixed times make the native and live attribute results comparable.
    for path <- ["a/sub/f2", "a/sub", "a/f1", "a/雪 file", "z", "e", "a", "."] do
      System.cmd("touch", ["-h", "-t", "202001020304.05", Path.join(root, path)])
    end
  end

  defp run(session, steps), do: Enum.map(steps, &step(session, &1))

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
    replay_loop(transport, socket, exchange, parent, [])
  end

  defp replay_loop(transport, socket, exchange, parent, mismatches) do
    case receive_frame(transport, socket) do
      {:ok, <<type, id::32, rest::binary>> = ours} ->
        case exchange do
          [{<<^type, _::32, ^rest::binary>>, <<reply_type, _::32, reply::binary>>} | exchange] ->
            :ok = transport.send(socket, frame(<<reply_type, id::32, reply::binary>>))
            replay_loop(transport, socket, exchange, parent, mismatches)

          [{expected, _} | exchange] ->
            :ok = transport.send(socket, frame(<<101, id::32, 4::32, 0::32, 0::32>>))
            replay_loop(transport, socket, exchange, parent, [{ours, expected} | mismatches])

          [] ->
            :ok = transport.send(socket, frame(<<101, id::32, 4::32, 0::32, 0::32>>))
            replay_loop(transport, socket, [], parent, [{ours, :unexpected} | mismatches])
        end

      :closed ->
        send(parent, {:sftp_replay_done, Enum.reverse(mismatches), length(exchange)})
    end
  end

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
