defmodule Opsmaru.Incus.FileTransferContractTest do
  @moduledoc """
  S04 file transfer contracts on Unix and mutual TLS: instance and storage volume
  file read, create and delete compared with the pinned official methods, and the
  typed HEAD helpers (no pinned method) evidenced by independent fixtures.
  """
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Files, RequestContext, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  @driver Path.expand("../.integration/files-driver", __DIR__)
  @extensions ~w(file_delete directory_manipulation file_symlinks file_append)
  @bytes :binary.copy(<<0, 255, 128, 13, 10>>, 400)
  @volume_types ~w(custom container virtual-machine image)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./files"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-s04-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} S04 reads agree with the pinned client on request, routing, bytes and metadata",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for target <- targets(), {kind, reply} <- read_replies() do
        fixture = backend(root, identity, fn _ -> reply end)
        go = oracle(root, fixture, identity, read_action(target), target)
        refute go["error"], inspect(go)
        {bytes, result} = with_sink(&read(client(fixture, identity), target, &1))
        assert {:ok, %{result: info}} = result

        assert {info.uid, info.gid, info.mode, info.type} ==
                 {go["info"]["UID"], go["info"]["GID"], go["info"]["Mode"], go["info"]["Type"]}

        # Directory entries are metadata, never sink bytes; other types stream bytes.
        if kind == :directory do
          assert bytes == "" and info.entries == go["info"]["Entries"]
        else
          assert bytes == Base.decode64!(go["bytes"])
        end

        assert_same_request(fixture, target, "GET")
      end
    end

    test "#{transport} S04 creates agree with the pinned client on headers and body bytes", %{
      root: root
    } do
      identity = identity(root, unquote(transport))

      for target <- targets(), {type, write, payload} <- creates() do
        fixture = backend(root, identity, fn _ -> sync() end)
        opts = %{"uid" => 7, "gid" => 8, "mode" => 0o640, "type" => type, "write_mode" => write}
        go = oracle(root, fixture, identity, create_action(target), target, opts, payload)
        refute go["error"], inspect(go)

        assert {:ok, _} =
                 create(client(fixture, identity), target, chunks(payload),
                   uid: 7,
                   gid: 8,
                   mode: 0o640,
                   type: type,
                   write_mode: write
                 )

        [native, local] = assert_same_request(fixture, target, "POST")
        assert native.body == local.body and local.body == payload

        for header <- ~w(x-incus-type x-incus-write x-incus-uid x-incus-gid x-incus-mode),
            do: assert(native.headers[header] == local.headers[header], header)
      end
    end

    test "#{transport} S04 deletes agree with the pinned client and lost replies are never replayed",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for target <- targets() do
        fixture = backend(root, identity, fn _ -> sync() end)
        refute oracle(root, fixture, identity, delete_action(target), target)["error"]
        assert {:ok, _} = delete(client(fixture, identity), target)
        assert_same_request(fixture, target, "DELETE")

        lost = backend(root, identity, fn _ -> %{upgrade: fn _, _ -> :ok end} end)
        assert {:error, %Error{kind: :uncertain}} = delete(client(lost, identity), target)
        assert [%{method: "DELETE"}] = HTTPFixture.requests(lost)
      end
    end

    test "#{transport} S04 HEAD returns parsed metadata without a body", %{root: root} do
      identity = identity(root, unquote(transport))

      for target <- targets(), {kind, headers} <- head_replies() do
        fixture = backend(root, identity, fn _ -> %{raw: head_response(200, headers)} end)
        assert {:ok, %{result: info}} = head(client(fixture, identity), target)
        assert {info.uid, info.gid, info.mode, info.type} == {1000, 1001, 0o640, to_string(kind)}
        assert info.modified == "2026-10-26 12:00:00 +0000 UTC"
        assert info.size == if(kind == :file, do: 2_000, else: nil)

        assert [request] = HTTPFixture.requests(fixture)
        assert request.method == "HEAD" and request.body == ""
        assert signature(request) == expected(target)
      end
    end

    test "#{transport} S04 HEAD rejects a body, early close and invalid metadata without uncertainty",
         %{root: root} do
      identity = identity(root, unquote(transport))
      common = ["X-Incus-type: file", "X-Incus-uid: 1000"]

      for target <- targets(),
          {raw, kind} <- [
            # A HEAD response carrying body bytes is a protocol failure.
            {[head_response(200, ["Content-Length: 5" | common]), "hello"], :transfer},
            {"HTTP/1.1 200 OK\r\nX-Incus-type: fi", :transfer},
            {head_response(200, ["X-Incus-mode: " <> String.duplicate("7", 17_000) | common]),
             :invalid_file_headers}
          ] do
        fixture = backend(root, identity, fn _ -> %{raw: raw} end)
        assert {:error, %Error{kind: ^kind}} = head(client(fixture, identity), target)
        assert [%{method: "HEAD"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{transport} S04 native errors are preserved with one request on each side", %{
      root: root
    } do
      identity = identity(root, unquote(transport))

      for target <- targets(), code <- [400, 403, 404] do
        error = fn _ ->
          %{status: code, body: %{type: "error", error_code: code, error: "native rejection"}}
        end

        for {action, call} <- [
              {read_action(target), &with_sink(fn sink -> read(&1, target, sink) end)},
              {create_action(target), &{"", create(&1, target, [@bytes])}},
              {delete_action(target), &{"", delete(&1, target)}}
            ] do
          fixture = backend(root, identity, error)
          opts = %{"type" => "file", "write_mode" => "overwrite"}
          go = oracle(root, fixture, identity, action, target, opts, @bytes)
          assert go["error_status"] == code

          assert {"", {:error, %Error{kind: :native, http_status: ^code, message: message}}} =
                   call.(client(fixture, identity))

          assert message == go["error"]
          assert length(HTTPFixture.requests(fixture)) == 2
        end

        # A HEAD rejection carries no body: only its HTTP status is native.
        fixture = backend(root, identity, fn _ -> %{raw: head_response(code, [])} end)

        assert {:error, %Error{kind: :native, http_status: ^code}} =
                 head(client(fixture, identity), target)
      end
    end

    test "#{transport} S04 transfers are bounded and end with their lifetime", %{root: root} do
      identity = identity(root, unquote(transport))

      for target <- targets() do
        fixture = backend(root, identity, fn _ -> file_reply(@bytes) end)

        assert {"", {:error, %Error{kind: :stream_limit}}} =
                 with_sink(&read(client(fixture, identity, max_stream_bytes: 3), target, &1))

        assert {:error, %Error{kind: :deadline}} =
                 read(client(fixture, identity, stream_timeout: 50), target, fn _ ->
                   Process.sleep(200)
                   :ok
                 end)

        # An oversized upload stops before it completes and is never resent.
        upload = backend(root, identity, fn _ -> sync() end)

        assert {:error, %Error{}} =
                 create(client(upload, identity, max_stream_bytes: 3), target, [@bytes])

        assert length(HTTPFixture.requests(upload)) <= 1

        for mode <- [:cancel, :caller_loss], do: cleanup(root, identity, target, mode)
      end
    end

    test "#{transport} S04 extension guards and invalid options reject before I/O", %{
      root: root
    } do
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> flunk("rejected transfer was dispatched") end)
      client = client(fixture, identity)

      missing = fn extension ->
        %{client | server: %Server{api_extensions: @extensions -- [extension]}}
      end

      for target <- targets() do
        for {opts, extension} <- [
              {[type: "directory"], "directory_manipulation"},
              {[type: "symlink"], "file_symlinks"},
              {[write_mode: "append"], "file_append"}
            ] do
          assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
                   create(missing.(extension), target, [@bytes], opts)
        end

        for opts <- [[type: "fifo"], [write_mode: "truncate"], [uid: "root"]] do
          assert {:error, %Error{kind: :invalid_file_options}} =
                   create(client, target, [@bytes], opts)
        end
      end

      assert {:error, %Error{kind: :unsupported_extension, extension: "file_delete"}} =
               Incus.call(missing.("file_delete"), "DeleteInstanceFile", %{
                 "instanceName" => "vm one",
                 "filePath" => "/etc/a b"
               })

      assert HTTPFixture.requests(fixture) == []
    end
  end

  # Mid-stream cancellation or caller loss closes the peer and stops the sink.
  defp cleanup(root, identity, target, mode) do
    parent = self()
    tag = make_ref()

    fixture =
      backend(root, identity, fn _ ->
        %{
          upgrade: fn transport, socket ->
            :ok =
              transport.send(
                socket,
                "HTTP/1.1 200 OK\r\nX-Incus-type: file\r\nContent-Length: 10000000\r\n\r\n"
              )

            send(parent, {tag, :closed, stream_until_closed(transport, socket)})
          end
        }
      end)

    context = RequestContext.new!(timeout: 30_000)
    scoped = Incus.with_context(client(fixture, identity), context)

    caller =
      spawn(fn ->
        result =
          read(scoped, target, fn chunk ->
            send(parent, {tag, :chunk, chunk})
            :ok
          end)

        send(parent, {tag, :result, result})
      end)

    assert_receive {^tag, :chunk, _}, 10_000

    case mode do
      :cancel ->
        RequestContext.cancel(context)
        assert_receive {^tag, :result, {:error, %Error{kind: :canceled}}}, 10_000

      :caller_loss ->
        Process.exit(caller, :kill)
    end

    assert_receive {^tag, :closed, {:error, _}}, 10_000
    flush(tag)
    refute_receive {^tag, :chunk, _}, 200
  end

  # Instance files, then a custom volume and every other volume type passed through.
  defp targets,
    do: [{:instance, "vm one"} | for(type <- @volume_types, do: {:volume, type})]

  defp read({:instance, name}, sink), do: &Files.read(&1, name, "/etc/a b", sink)

  defp read({:volume, type}, sink),
    do: &Files.volume_read(&1, "pool one", type, "vol one", "/etc/a b", sink)

  defp read(client, target, sink), do: read(target, sink).(client)

  defp create(client, {:instance, name}, source, opts \\ []),
    do: Files.create(client, name, "/etc/a b", source, opts)

  defp create(client, {:volume, type}, source, opts),
    do: Files.volume_create(client, "pool one", type, "vol one", "/etc/a b", source, opts)

  defp delete(client, {:instance, name}),
    do:
      Incus.call(client, "DeleteInstanceFile", %{"instanceName" => name, "filePath" => "/etc/a b"})

  defp delete(client, {:volume, type}),
    do: Files.volume_delete(client, "pool one", type, "vol one", "/etc/a b")

  defp head(client, {:instance, name}), do: Files.head(client, name, "/etc/a b")

  defp head(client, {:volume, type}),
    do: Files.volume_head(client, "pool one", type, "vol one", "/etc/a b")

  defp read_action({:instance, _}), do: "GetInstanceFile"
  defp read_action({:volume, _}), do: "GetStorageVolumeFile"
  defp create_action({:instance, _}), do: "CreateInstanceFile"
  defp create_action({:volume, _}), do: "CreateStorageVolumeFile"
  defp delete_action({:instance, _}), do: "DeleteInstanceFile"
  defp delete_action({:volume, _}), do: "DeleteStorageVolumeFile"

  defp expected({:instance, _}),
    do:
      {"/1.0/instances/vm%20one/files",
       %{"path" => "/etc/a b", "project" => "ops", "target" => "node-2"}}

  defp expected({:volume, type}),
    do:
      {"/1.0/storage-pools/pool%20one/volumes/#{type}/vol%20one/files",
       %{"path" => "/etc/a b", "project" => "ops", "target" => "node-2"}}

  defp signature(request) do
    uri = URI.parse(request.target)
    {uri.path, URI.decode_query(uri.query || "")}
  end

  defp assert_same_request(fixture, target, method) do
    assert [native, local] = HTTPFixture.requests(fixture)
    assert native.method == method and local.method == method
    assert signature(native) == signature(local)
    assert signature(local) == expected(target)
    [native, local]
  end

  defp read_replies do
    directory = Jason.encode!(%{type: "sync", status_code: 200, metadata: ["one", "two three"]})

    [
      {:file, file_reply(@bytes)},
      {:directory,
       raw(
         ["X-Incus-type: directory", "X-Incus-uid: 0", "X-Incus-gid: 0", "X-Incus-mode: 0755"],
         directory
       )},
      {:symlink,
       raw(
         [
           "X-Incus-type: symlink",
           "X-Incus-uid: 1000",
           "X-Incus-gid: 1001",
           "X-Incus-mode: 0777"
         ],
         "/etc/target"
       )}
    ]
  end

  defp file_reply(bytes),
    do:
      raw(
        ["X-Incus-type: file", "X-Incus-uid: 1000", "X-Incus-gid: 1001", "X-Incus-mode: 0640"],
        bytes
      )

  defp raw(headers, body),
    do: %{
      raw: [
        "HTTP/1.1 200 OK\r\n",
        Enum.map(headers, &[&1, "\r\n"]),
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ]
    }

  # File, directory (overwrite only) and symlink (its target as content) creates.
  defp creates,
    do: [
      {"file", "overwrite", @bytes},
      {"file", "append", @bytes},
      {"directory", "overwrite", ""},
      {"symlink", "overwrite", "/etc/target"}
    ]

  defp head_replies do
    common = [
      "X-Incus-uid: 1000",
      "X-Incus-gid: 1001",
      "X-Incus-mode: 0640",
      "X-Incus-modified: 2026-10-26 12:00:00 +0000 UTC"
    ]

    [
      {:file, ["X-Incus-type: file", "Content-Length: 2000" | common]},
      {:directory, ["X-Incus-type: directory" | common]},
      {:symlink, ["X-Incus-type: symlink" | common]}
    ]
  end

  # A HEAD response: headers only (any Content-Length describes the file, not a body).
  defp head_response(status, headers),
    do: ["HTTP/1.1 #{status} Status\r\n", Enum.map(headers, &[&1, "\r\n"]), "\r\n"]

  defp sync, do: %{status: 200, body: %{type: "sync", status_code: 200, metadata: %{}}}

  defp stream_until_closed(transport, socket) do
    case transport.send(socket, :binary.copy(<<1>>, 64)) do
      :ok ->
        Process.sleep(20)
        stream_until_closed(transport, socket)

      error ->
        error
    end
  end

  defp flush(tag) do
    receive do
      {^tag, :chunk, _} -> flush(tag)
    after
      0 -> :ok
    end
  end

  defp chunks(""), do: []
  defp chunks(binary) when byte_size(binary) <= 512, do: [binary]

  defp chunks(binary) do
    <<chunk::binary-size(512), rest::binary>> = binary
    [chunk | chunks(rest)]
  end

  defp with_sink(fun) do
    capture = start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> [] end]}})

    result =
      fun.(fn chunk ->
        Agent.update(capture, &[chunk | &1])
        :ok
      end)

    {Agent.get(capture, &IO.iodata_to_binary(Enum.reverse(&1))), result}
  end

  defp oracle(root, fixture, identity, action, target, opts \\ %{}, payload \\ nil) do
    endpoint = HTTPFixture.endpoint(fixture)

    target_input =
      case target do
        {:instance, name} -> %{"instance" => name}
        {:volume, type} -> %{"pool" => "pool one", "volume_type" => type, "volume" => "vol one"}
      end

    connection =
      if identity,
        do: %{
          "url" => endpoint.url,
          "tls_ca" => File.read!(identity.cafile),
          "client_cert" => File.read!(identity.certfile),
          "client_key" => File.read!(identity.keyfile)
        },
        else: %{"socket" => endpoint.socket}

    input =
      %{"action" => action, "path" => "/etc/a b", "project" => "ops", "target" => "node-2"}
      |> Map.merge(target_input)
      |> Map.merge(connection)
      |> Map.merge(opts)
      |> Map.merge(if(payload, do: %{"payload" => Base.encode64(payload)}, else: %{}))

    file = Path.join(root, "oracle-#{System.unique_integer([:positive])}.json")
    File.write!(file, Jason.encode!(input))
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end

  defp identity(_root, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "s04-#{System.unique_integer([:positive])}", "localhost")

  # Mutual TLS: the fixture requires and verifies a client certificate.
  defp backend(root, identity, handler) do
    options =
      if identity,
        do: [
          transport: :ssl,
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            cacertfile: identity.cafile,
            verify: :verify_peer,
            fail_if_no_peer_cert: true
          ]
        ],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "s#{System.unique_integer([:positive])}")
        ]

    start_supervised!({HTTPFixture, options ++ [handler: handler]}, id: make_ref())
  end

  defp client(fixture, identity, opts \\ []) do
    endpoint = HTTPFixture.endpoint(fixture)
    options = [owner: :fixture, project: "ops", member: "node-2", timeout: 30_000] ++ opts

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            options ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, options)

    %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: @extensions}
    }
  end
end
