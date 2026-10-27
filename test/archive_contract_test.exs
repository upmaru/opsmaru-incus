defmodule Opsmaru.Incus.ArchiveContractTest do
  @moduledoc """
  S06 archive contracts on Unix and mutual TLS: instance, volume and bucket backup
  export downloads, direct backup POST and backup/ISO imports compared with the
  pinned official methods. The control plane (list, get, create, rename, delete and
  bucket creation) is compared in the inspection and sync-mutation contract tests.
  """
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Files, RequestContext, Server, Transfer}
  alias Opsmaru.TestSupport.{HTTPFixture, ModelSamples, TLSIdentity}

  @driver Path.expand("../.integration/archives-driver", __DIR__)
  @extensions ~w(container_backup custom_volume_backup storage_bucket_backup direct_backup custom_volume_iso backup_override_name container_backup_override_pool backup_override_config)
  @bytes :binary.copy(<<0, 255, 128, 13, 10>>, 400)
  @volume_types ~w(custom container virtual-machine image)
  @headers ~w(content-type accept x-incus-name x-incus-pool x-incus-config x-incus-devices x-incus-type)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./archives"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-s06-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} S06 exports agree with the pinned client on request, routing and bytes",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for target <- exports(), member <- [nil, "node-2"] do
        fixture = backend(root, identity, fn _ -> bytes_reply(@bytes) end)

        if pinned?(target) do
          go = oracle(root, fixture, identity, export_action(target), target, member)
          refute go["error"], inspect(go)
          assert Base.decode64!(go["bytes"]) == @bytes and go["size"] == byte_size(@bytes)
        end

        {bytes, result} =
          with_sink(&export(client(fixture, identity, member: member), target, &1))

        assert {:ok, %Transfer{bytes: 2_000}} = result
        assert bytes == @bytes
        assert_same_request(fixture, target, member, "GET")
      end
    end

    test "#{transport} S06 direct backup POST agrees with the pinned client on body and bytes",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for target <- exports(), member <- [nil, "node-2"] do
        fixture = backend(root, identity, fn _ -> bytes_reply(@bytes) end)
        body = stream_body(target)

        # The pinned client's decoded body, so both sides send the same typed value;
        # Go keeps every generated field and adds zero values.
        sent =
          if pinned?(target) do
            go =
              oracle(root, fixture, identity, stream_action(target), target, member, %{
                "body" => body
              })

            refute go["error"], inspect(go)
            assert Base.decode64!(go["bytes"]) == @bytes
            [native] = HTTPFixture.requests(fixture)
            decoded = Jason.decode!(native.body)
            assert sent?(decoded, body), "pinned DTO dropped or changed a generated field"
            decoded
          else
            body
          end

        {bytes, result} =
          with_sink(
            &Files.backup_stream(
              client(fixture, identity, member: member),
              resource(target),
              sent,
              &1
            )
          )

        assert {:ok, %Transfer{bytes: 2_000}} = result
        assert bytes == @bytes

        requests = assert_same_request(fixture, target, member, "POST", "/backups")
        local = List.last(requests)
        assert local.headers["accept"] == "application/octet-stream"
        assert Jason.decode!(local.body) == sent

        if pinned?(target) do
          [native, _] = requests
          assert native.headers["accept"] == local.headers["accept"]
        end
      end
    end

    test "#{transport} S06 imports agree with the pinned client on headers, bytes and operation",
         %{root: root} do
      identity = identity(root, unquote(transport))

      for {target, opts, go_opts} <- imports(), member <- [nil, "node-2"] do
        fixture = backend(root, identity, fn _ -> accepted() end)

        go =
          oracle(
            root,
            fixture,
            identity,
            import_action(target, opts),
            target,
            member,
            go_opts,
            @bytes
          )

        refute go["error"], inspect(go)

        assert {:ok, response} =
                 import(client(fixture, identity, member: member), target, chunks(@bytes), opts)

        assert response.operation == "/1.0/operations/archive-op"
        assert response.metadata["id"] == go["operation"]["id"]

        [native, local] = assert_same_request(fixture, target, member, "POST")
        assert native.body == @bytes and local.body == @bytes

        for header <- @headers,
            do: assert(native.headers[header] == local.headers[header], header)
      end
    end

    test "#{transport} S06 native errors are preserved with one request on each side", %{
      root: root
    } do
      identity = identity(root, unquote(transport))

      cases =
        for(target <- pinned_exports(), do: {target, :export}) ++
          for(target <- pinned_exports(), do: {target, :stream}) ++
          for({target, opts, go_opts} <- imports(), do: {target, {:import, opts, go_opts}})

      for {target, mode} <- cases, code <- [400, 403, 404] do
        fixture =
          backend(root, identity, fn _ ->
            %{status: code, body: %{type: "error", error_code: code, error: "native rejection"}}
          end)

        client = client(fixture, identity)

        {go, result} =
          case mode do
            :export ->
              {oracle(root, fixture, identity, export_action(target), target, nil),
               with_sink(&export(client, target, &1))}

            :stream ->
              body = stream_body(target)

              {oracle(root, fixture, identity, stream_action(target), target, nil, %{
                 "body" => body
               }), with_sink(&Files.backup_stream(client, resource(target), body, &1))}

            {:import, opts, go_opts} ->
              {oracle(
                 root,
                 fixture,
                 identity,
                 import_action(target, opts),
                 target,
                 nil,
                 go_opts,
                 @bytes
               ), {"", import(client, target, [@bytes], opts)}}
          end

        assert go["error_status"] == code

        assert {"", {:error, %Error{kind: :native, http_status: ^code, message: message}}} =
                 result

        assert message == go["error"]
        assert length(HTTPFixture.requests(fixture)) == 2
      end
    end

    test "#{transport} S06 archives are bounded and end with their lifetime", %{root: root} do
      identity = identity(root, unquote(transport))

      for target <- exports() do
        fixture = backend(root, identity, fn _ -> bytes_reply(@bytes) end)

        assert {"", {:error, %Error{kind: :stream_limit}}} =
                 with_sink(&export(client(fixture, identity, max_stream_bytes: 3), target, &1))

        assert {:error, %Error{kind: :deadline}} =
                 export(client(fixture, identity, stream_timeout: 50), target, fn _ ->
                   Process.sleep(200)
                   :ok
                 end)

        # A direct backup POST past its bound is uncertain and never resent.
        stream = backend(root, identity, fn _ -> bytes_reply(@bytes) end)

        assert {_, {:error, %Error{kind: :uncertain}}} =
                 with_sink(
                   &Files.backup_stream(
                     client(stream, identity, max_stream_bytes: 1_500),
                     resource(target),
                     stream_body(target),
                     &1
                   )
                 )

        assert [%{method: "POST"}] = HTTPFixture.requests(stream)

        for mode <- [:cancel, :caller_loss],
            call <- [:export, :stream],
            do: cleanup(root, identity, target, mode, call)
      end

      # The bound counts the whole upload: chunks that each fit but together exceed it
      # stop before the fixture receives a complete body, and nothing is resent.
      for {target, opts, _} <- imports() do
        upload = backend(root, identity, fn _ -> accepted() end)
        bound = byte_size(@bytes) - 1
        assert Enum.all?(chunks(@bytes), &(byte_size(&1) <= bound))

        assert {:error, %Error{kind: :uncertain}} =
                 import(
                   client(upload, identity, max_stream_bytes: bound),
                   target,
                   chunks(@bytes),
                   opts
                 )

        assert HTTPFixture.requests(upload) == []

        exact = backend(root, identity, fn _ -> accepted() end)

        assert {:ok, _} =
                 import(
                   client(exact, identity, max_stream_bytes: byte_size(@bytes)),
                   target,
                   chunks(@bytes),
                   opts
                 )

        assert [%{body: @bytes}] = HTTPFixture.requests(exact)
      end
    end

    test "#{transport} S06 lost import and direct backup replies are uncertain and never replayed",
         %{root: root} do
      identity = identity(root, unquote(transport))
      lost = fn -> backend(root, identity, fn _ -> %{upgrade: fn _, _ -> :ok end} end) end

      for {target, opts, _} <- imports() do
        fixture = lost.()

        assert {:error, %Error{kind: :uncertain}} =
                 import(client(fixture, identity), target, chunks(@bytes), opts)

        assert [%{method: "POST"}] = HTTPFixture.requests(fixture)
      end

      for target <- exports() do
        fixture = lost.()

        assert {"", {:error, %Error{kind: :uncertain}}} =
                 with_sink(
                   &Files.backup_stream(
                     client(fixture, identity),
                     resource(target),
                     stream_body(target),
                     &1
                   )
                 )

        assert [%{method: "POST"}] = HTTPFixture.requests(fixture)
      end
    end

    test "#{transport} S06 archives write no implicit host files", %{root: root} do
      identity = identity(root, unquote(transport))

      # Every fixture socket and certificate exists before the first archive call.
      exports =
        for target <- exports(),
            do:
              {target, client(backend(root, identity, fn _ -> bytes_reply(@bytes) end), identity)}

      imports =
        for {target, opts, _} <- imports(),
            do: {target, opts, client(backend(root, identity, fn _ -> accepted() end), identity)}

      before = {tree(root), File.ls!(File.cwd!())}

      for {target, client} <- exports do
        assert {@bytes, {:ok, _}} = with_sink(&export(client, target, &1))

        assert {@bytes, {:ok, _}} =
                 with_sink(
                   &Files.backup_stream(client, resource(target), stream_body(target), &1)
                 )
      end

      for {target, opts, client} <- imports,
          do: assert({:ok, _} = import(client, target, [@bytes], opts))

      assert {tree(root), File.ls!(File.cwd!())} == before
    end

    test "#{transport} S06 extension guards and invalid options reject before I/O", %{
      root: root
    } do
      identity = identity(root, unquote(transport))
      fixture = backend(root, identity, fn _ -> flunk("rejected archive was dispatched") end)
      client = client(fixture, identity)
      sink = fn _ -> :ok end

      missing = fn extension ->
        %{client | server: %Server{api_extensions: @extensions -- [extension]}}
      end

      for {call, extension} <- [
            {&Files.backup_download(&1, "vm one", "bk one", sink), "container_backup"},
            {&Files.volume_backup_download(&1, "pool one", "custom", "vol one", "bk one", sink),
             "custom_volume_backup"},
            {&Files.bucket_backup_download(&1, "pool one", "bkt one", "bk one", sink),
             "storage_bucket_backup"},
            {&Files.backup_stream(&1, {:instance, "vm one"}, %{"name" => "bk"}, sink),
             "direct_backup"},
            {&Files.backup_import(&1, [@bytes]), "container_backup"},
            {&Files.backup_import(&1, [@bytes], name: "copy"), "backup_override_name"},
            {&Files.backup_import(&1, [@bytes], pool: "fast"), "container_backup_override_pool"},
            {&Files.backup_import(&1, [@bytes], config: ["a=b"]), "backup_override_config"},
            {&Files.backup_import(&1, [@bytes], devices: ["root,size=1GiB"]),
             "backup_override_config"},
            {&Files.volume_import(&1, "pool one", [@bytes]), "custom_volume_backup"},
            {&Files.volume_import(&1, "pool one", [@bytes], name: "copy"),
             "backup_override_name"},
            {&Files.volume_import(&1, "pool one", [@bytes], type: :iso, name: "disk"),
             "custom_volume_iso"},
            {&Files.bucket_import(&1, "pool one", [@bytes]), "storage_bucket_backup"}
          ] do
        assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
                 call.(missing.(extension))
      end

      # An ISO import needs a name; direct backup bodies are typed and bounded.
      for name <- [nil, ""] do
        assert {:error, %Error{kind: :invalid_file_options}} =
                 Files.volume_import(client, "pool one", [@bytes], type: :iso, name: name)
      end

      for body <- [%{"name" => 5}, %{"name" => String.duplicate("a", 70_000)}] do
        assert {:error, %Error{kind: :invalid_body}} =
                 Files.backup_stream(client, {:instance, "vm one"}, body, sink)
      end

      assert HTTPFixture.requests(fixture) == []
    end
  end

  # Mid-stream cancellation or caller loss closes the peer and stops the sink.
  defp cleanup(root, identity, target, mode, call) do
    parent = self()
    tag = make_ref()

    fixture =
      backend(root, identity, fn _ ->
        %{
          upgrade: fn transport, socket ->
            :ok = transport.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 10000000\r\n\r\n")
            send(parent, {tag, :closed, stream_until_closed(transport, socket)})
          end
        }
      end)

    context = RequestContext.new!(timeout: 30_000)
    scoped = Incus.with_context(client(fixture, identity), context)

    sink = fn chunk ->
      send(parent, {tag, :chunk, chunk})
      :ok
    end

    caller =
      spawn(fn ->
        result =
          case call do
            :export -> export(scoped, target, sink)
            :stream -> Files.backup_stream(scoped, resource(target), stream_body(target), sink)
          end

        send(parent, {tag, :result, result})
      end)

    assert_receive {^tag, :chunk, _}, 10_000

    case mode do
      # A canceled export is canceled; a canceled direct backup POST is uncertain.
      :cancel ->
        kind = if call == :export, do: :canceled, else: :uncertain
        RequestContext.cancel(context)
        assert_receive {^tag, :result, {:error, %Error{kind: ^kind}}}, 10_000

      :caller_loss ->
        Process.exit(caller, :kill)
    end

    assert_receive {^tag, :closed, {:error, _}}, 10_000
    flush(tag)
    refute_receive {^tag, :chunk, _}, 200
  end

  # Instance and bucket backups, then a custom volume and every other volume type
  # passed through (the pinned volume methods address only custom volumes).
  defp exports,
    do: [{:instance}, {:bucket} | for(type <- @volume_types, do: {:volume, type})]

  defp pinned_exports, do: Enum.filter(exports(), &pinned?/1)
  defp pinned?({:volume, type}), do: type == "custom"
  defp pinned?(_), do: true

  defp resource({:instance}), do: {:instance, "vm one"}
  defp resource({:bucket}), do: {:bucket, "pool one", "bkt one"}
  defp resource({:volume, type}), do: {:volume, "pool one", type, "vol one"}

  defp export(client, {:instance}, sink),
    do: Files.backup_download(client, "vm one", "bk one", sink)

  defp export(client, {:bucket}, sink),
    do: Files.bucket_backup_download(client, "pool one", "bkt one", "bk one", sink)

  defp export(client, {:volume, type}, sink),
    do: Files.volume_backup_download(client, "pool one", type, "vol one", "bk one", sink)

  defp export_action({:instance}), do: "GetInstanceBackupFile"
  defp export_action({:bucket}), do: "GetStoragePoolBucketBackupFile"
  defp export_action({:volume, _}), do: "GetStorageVolumeBackupFile"
  defp stream_action({:instance}), do: "CreateInstanceBackupStream"
  defp stream_action({:bucket}), do: "CreateStoragePoolBucketBackupStream"
  defp stream_action({:volume, _}), do: "CreateStorageVolumeBackupStream"

  # Schema-driven direct backup bodies with every generated field: expiry,
  # compression, target and the instance-only, volume-only and optimized options.
  defp stream_body({:instance}), do: ModelSamples.generate("InstanceBackupsPost")
  defp stream_body({:volume, _}), do: ModelSamples.generate("StorageVolumeBackupsPost")
  defp stream_body({:bucket}), do: ModelSamples.generate("StorageBucketBackupsPost")

  # The decoded value keeps every sent field and value; Go may add zero-valued fields.
  defp sent?(decoded, sent) when is_map(sent),
    do: is_map(decoded) and Enum.all?(sent, fn {key, value} -> sent?(decoded[key], value) end)

  defp sent?(decoded, sent), do: decoded == sent

  # Instance backup import with name, pool, config and device overrides (including
  # empty overrides), custom volume backup and ISO import, and bucket import.
  defp imports,
    do: [
      {{:instance}, [], %{}},
      {{:instance}, [name: "restored", pool: "fast"],
       %{"name" => "restored", "pool_name" => "fast"}},
      {{:instance}, [config: ["limits.cpu=2", "user.note=a b"], devices: ["root,size=10GiB"]],
       %{"config" => ["limits.cpu=2", "user.note=a b"], "devices" => ["root,size=10GiB"]}},
      {{:instance}, [config: [], devices: []], %{"config" => [], "devices" => []}},
      {{:volume, "custom"}, [], %{}},
      {{:volume, "custom"}, [name: "restored"], %{"name" => "restored"}},
      {{:iso}, [type: :iso, name: "disk"], %{"name" => "disk"}},
      {{:bucket}, [], %{}},
      {{:bucket}, [name: "restored"], %{"name" => "restored"}}
    ]

  defp import(client, {:instance}, source, opts), do: Files.backup_import(client, source, opts)

  defp import(client, {:bucket}, source, opts),
    do: Files.bucket_import(client, "pool one", source, opts)

  defp import(client, _, source, opts), do: Files.volume_import(client, "pool one", source, opts)

  defp import_action({:instance}, _), do: "CreateInstanceFromBackup"
  defp import_action({:bucket}, _), do: "CreateStoragePoolBucketFromBackup"
  defp import_action({:iso}, _), do: "CreateStoragePoolVolumeFromISO"
  defp import_action({:volume, _}, _), do: "CreateStoragePoolVolumeFromBackup"

  defp expected({:instance}, suffix), do: "/1.0/instances" <> suffix(:instance, suffix)

  defp expected({:bucket}, suffix),
    do: "/1.0/storage-pools/pool%20one/buckets" <> suffix(:bucket, suffix)

  defp expected({:iso}, _), do: "/1.0/storage-pools/pool%20one/volumes/custom"

  defp expected({:volume, type}, suffix),
    do: "/1.0/storage-pools/pool%20one/volumes/" <> type <> suffix({:volume}, suffix)

  defp suffix(:instance, :import), do: ""
  defp suffix(:instance, rest), do: "/vm%20one" <> rest
  defp suffix(:bucket, :import), do: ""
  defp suffix(:bucket, rest), do: "/bkt%20one" <> rest
  defp suffix({:volume}, :import), do: ""
  defp suffix({:volume}, rest), do: "/vol%20one" <> rest

  # The pinned instance and bucket exports and every direct backup POST send only
  # the project; volume exports and all imports also send the host target.
  defp pinned_target?({:volume, _}, "GET"), do: true
  defp pinned_target?(_, "GET"), do: false
  defp pinned_target?(_, {"POST", "/backups"}), do: false
  defp pinned_target?(_, "POST"), do: true

  defp signature(request) do
    uri = URI.parse(request.target)
    {uri.path, URI.decode_query(uri.query || "")}
  end

  defp assert_same_request(fixture, target, member, method, route \\ nil) do
    path =
      case {method, route} do
        {"GET", _} -> expected(target, "/backups/bk%20one/export")
        {"POST", "/backups"} -> expected(target, "/backups")
        {"POST", nil} -> expected(target, :import)
      end

    query = %{"project" => "ops"}
    query = if member, do: Map.put(query, "target", member), else: query
    requests = HTTPFixture.requests(fixture)
    local = List.last(requests)
    assert local.method == method and signature(local) == {path, query}

    if pinned?(target) do
      assert [native, ^local] = requests
      assert native.method == method
      key = if route, do: {method, route}, else: method
      native_query = if pinned_target?(target, key), do: query, else: Map.delete(query, "target")
      assert signature(native) == {path, native_query}
    end

    requests
  end

  defp bytes_reply(body),
    do: %{
      raw: [
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ]
    }

  defp accepted,
    do: %{
      status: 202,
      body: %{
        type: "async",
        status: "Operation created",
        status_code: 100,
        operation: "/1.0/operations/archive-op",
        metadata: %{
          id: "archive-op",
          class: "task",
          description: "Restoring backup",
          created_at: "2026-10-27T00:00:00Z",
          updated_at: "2026-10-27T00:00:00Z",
          status: "Running",
          status_code: 103,
          resources: %{},
          metadata: nil,
          may_cancel: false,
          err: "",
          location: "none"
        }
      }
    }

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

  # Every path under a directory, recursively, so a nested or oddly named file shows.
  defp tree(dir), do: Enum.sort(Path.wildcard(Path.join(dir, "**"), match_dot: true))

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

  defp oracle(root, fixture, identity, action, target, member, opts \\ %{}, payload \\ nil) do
    endpoint = HTTPFixture.endpoint(fixture)

    target_input =
      case target do
        {:instance} -> %{"instance" => "vm one"}
        {:bucket} -> %{"pool" => "pool one", "bucket" => "bkt one"}
        _ -> %{"pool" => "pool one", "volume" => "vol one"}
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
      %{"action" => action, "backup" => "bk one", "project" => "ops", "target" => member || ""}
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
    do: TLSIdentity.generate(root, "s06-#{System.unique_integer([:positive])}", "localhost")

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
    {member, opts} = Keyword.pop(opts, :member, "node-2")
    options = [owner: :fixture, project: "ops", member: member, timeout: 30_000] ++ opts

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
