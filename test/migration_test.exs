defmodule Opsmaru.Incus.MigrationTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Migration, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture}

  setup do
    root = Path.join(System.tmp_dir!(), "op-migrate-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "relay negotiation retains two native accepted identities and never follows advertised addresses",
       %{root: root} do
    source = client(root, "source", :accept)
    target = client(root, "target", :accept)

    assert {:ok, migration} =
             Migration.negotiate(source, target, source_request(), target_request(), mode: :relay)

    assert migration.source.url == "/1.0/operations/source"
    assert migration.target.url == "/1.0/operations/target"
    assert migration.source.client.connection == source.connection
    assert migration.target.client.connection == target.connection
    refute inspect(migration) =~ "transport-secret"
    # Acceptance does not imply backend completion or automatic stream activation.
    assert migration.source.response.metadata.data["status_code"] == 103
  end

  test "target loss preserves accepted source and uncertain target without retry or cancellation",
       %{root: root} do
    source = client(root, "source", :accept)
    target = client(root, "target", :disconnect)

    assert {:error, %Error{kind: :uncertain, response: %{accepted: migration}}} =
             Migration.negotiate(source, target, source_request(), target_request(), mode: :relay)

    assert migration.source.url == "/1.0/operations/source"
    assert is_nil(migration.target)
    assert_received {:posted, "source", _}
    assert_received {:posted, "target", _}
    refute_received {:posted, _, _}
  end

  test "ambiguous negotiation and relay options reject before I/O, retaining accepted handles", %{
    root: root
  } do
    source = client(root, "source", :accept)
    target = client(root, "target", :accept)

    for opts <- [
          %{mode: :relay},
          [mode: :relay, mode: :push],
          [mode: :relay, retry: true],
          [mode: false],
          [mode: "relay"]
        ] do
      assert {:error, %Error{kind: :invalid_migration_options}} =
               Migration.negotiate(source, target, source_request(), target_request(), opts)
    end

    refute_received {:posted, _, _}

    assert {:ok, migration} =
             Migration.negotiate(source, target, source_request(), target_request(), mode: :relay)

    assert_receive {:posted, "source", _}
    assert_receive {:posted, "target", _}

    for opts <- [
          %{timeout: 10},
          [timeout: 1, timeout: 100],
          [timeout: 10, retry: true],
          [timeout: false],
          [timeout: nil]
        ] do
      assert {:error, %Error{kind: :invalid_relay, response: %{accepted: ^migration}}} =
               Migration.relay(migration, opts)
    end

    incomplete = %{migration | target: nil}

    assert {:error, %Error{kind: :invalid_relay, response: %{accepted: ^incomplete}}} =
             Migration.relay(incomplete)

    refute_received {:posted, _, _}
  end

  test "unapproved origins and malformed secrets fail before a target mutation", %{root: root} do
    source = client(root, "source", :invalid)
    target = client(root, "target", :accept)

    assert {:error, %Error{kind: :unapproved_migration_origin}} =
             Migration.negotiate(source, target, source_request(), target_request(),
               approved_origin: "https://advertised.example"
             )

    refute_received {:posted, _, _}

    assert {:error, %Error{kind: :invalid_migration_secrets, response: %{accepted: migration}}} =
             Migration.negotiate(source, target, source_request(), target_request(), mode: :relay)

    assert migration.source.url == "/1.0/operations/source"
    assert_received {:posted, "source", _}
    refute_received {:posted, "target", _}
  end

  test "HTTPS pull/push descriptors use native secrets and retain accepted operation bindings", %{
    root: root
  } do
    identity = TLSIdentity.generate(root, "migration", "localhost")
    parent = self()

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: identity.certfile,
         keyfile: identity.keyfile,
         handler: fn request ->
           project = URI.decode_query(URI.parse(request.target).query)["project"]
           send(parent, {:native_request, project, Jason.decode!(request.body)})

           %{
             status: 202,
             body: %{
               type: "async",
               operation: "/1.0/operations/" <> project,
               metadata: %{id: project, status_code: 103, metadata: %{control: "native-secret"}}
             }
           }
         end},
        id: make_ref()
      )

    origin = HTTPFixture.endpoint(fixture).url

    client = fn project ->
      %Incus{
        connection:
          Connection.https!(origin,
            owner: project,
            project: project,
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          ),
        context: Context.new!(owner: project, identity: project, ready?: fn -> true end),
        server: %Server{
          api_extensions: [],
          environment: %{"certificate" => File.read!(identity.certfile)}
        }
      }
    end

    for mode <- [:pull, :push] do
      assert {:ok, migration} =
               Migration.negotiate(
                 client.("source"),
                 client.("target"),
                 source_request(),
                 target_request(),
                 mode: mode,
                 approved_origin: origin
               )

      assert migration.source.url == "/1.0/operations/source"
      assert migration.target.url == "/1.0/operations/target"
      assert_receive {:native_request, "source", source_body}
      assert_receive {:native_request, "target", target_body}
      descriptor = if mode == :pull, do: target_body["source"], else: source_body["target"]
      assert descriptor["secrets"] == %{"control" => "native-secret"}
      refute Map.has_key?(descriptor, "websockets")

      assert descriptor["operation"] ==
               origin <> "/1.0/operations/" <> if(mode == :pull, do: "source", else: "target")

      assert descriptor["certificate"] == File.read!(identity.certfile)
    end
  end

  test "relay forwards native control bytes, handles peer EOF and releases both channels", %{
    root: root
  } do
    parent = self()
    bytes = <<0, 255, 128, 42>>

    source_fixture =
      start_supervised!(
        {WebSocketFixture,
         path: Path.join(root, "relay-source"),
         wire: WebSocketFixture.frame(2, bytes),
         close_after: 200,
         frame_handler: fn _, _ -> :ok end},
        id: make_ref()
      )

    target_fixture =
      start_supervised!(
        {WebSocketFixture,
         path: Path.join(root, "relay-target"),
         wire: "",
         frame_handler: fn opcode, data -> send(parent, {:relayed, opcode, data}) end},
        id: make_ref()
      )

    operation = fn fixture, name ->
      client = %Incus{
        connection: Connection.unix!(WebSocketFixture.path(fixture), owner: name),
        context: Context.new!(owner: name, identity: name, ready?: fn -> true end),
        server: %Server{api_extensions: []}
      }

      %Opsmaru.Incus.Operation{
        client: client,
        url: "/1.0/operations/" <> name,
        response: %Opsmaru.Incus.Response{
          metadata: %{"metadata" => %{"control" => "native-secret"}}
        }
      }
    end

    migration = %Migration{
      mode: :relay,
      source: operation.(source_fixture, "source"),
      target: operation.(target_fixture, "target")
    }

    assert {:ok, ^migration} = Migration.relay(migration, timeout: 1000)
    assert_receive {:relayed, 2, ^bytes}
    # Native operation metadata stays accepted; stream EOF is not workload completion.
    assert migration.source.url == "/1.0/operations/source"
  end

  test "relay keeps multiple binary and text channels separate in both directions", %{root: root} do
    parent = self()
    bytes = <<0, 255, 128, 42>>

    source =
      relay_fixture(root, "source-many",
        wire: WebSocketFixture.frame(2, bytes) <> WebSocketFixture.frame(1, "barrier"),
        close_after: 250,
        frame_handler: fn opcode, data -> send(parent, {:source_frame, opcode, data}) end
      )

    target =
      relay_fixture(root, "target-many",
        wire: WebSocketFixture.frame(2, "reverse"),
        frame_handler: fn opcode, data -> send(parent, {:target_frame, opcode, data}) end
      )

    secrets = %{"control" => "control-secret", "fs" => "data-secret"}
    migration = relay_handles(source, target, secrets, secrets)
    assert {:ok, ^migration} = Migration.relay(migration, timeout: 1000)

    for _ <- 1..2 do
      assert_receive {:target_frame, 2, ^bytes}
      assert_receive {:target_frame, 1, "barrier"}
      assert_receive {:source_frame, 2, "reverse"}
    end

    for fixture <- [source, target] do
      requests = WebSocketFixture.requests(fixture)
      assert length(requests) == 2

      assert Enum.sort(
               Enum.map(requests, &URI.decode_query(URI.parse(&1.target).query)["secret"])
             ) == Enum.sort(Map.values(secrets))

      assert Enum.all?(requests, &(&1.method == "GET"))
    end
  end

  test "relay deadline releases silent channels and preserves accepted identities", %{root: root} do
    source = relay_fixture(root, "source-silent", wire: "", frame_handler: fn _, _ -> :ok end)
    target = relay_fixture(root, "target-silent", wire: "", frame_handler: fn _, _ -> :ok end)
    secrets = %{"control" => "control-secret", "fs" => "data-secret"}
    migration = relay_handles(source, target, secrets, secrets)
    before = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :deadline, response: %{accepted: ^migration}}} =
             Migration.relay(migration, timeout: 100)

    assert System.monotonic_time(:millisecond) - before < 700
    assert length(WebSocketFixture.requests(source)) == 2
    assert length(WebSocketFixture.requests(target)) == 2
    refute inspect(migration) =~ "control-secret"
    refute inspect(migration) =~ "data-secret"
  end

  test "mismatched channel names fail before sockets open and retain both operations", %{
    root: root
  } do
    source = relay_fixture(root, "source-mismatch", wire: "")
    target = relay_fixture(root, "target-mismatch", wire: "")

    migration =
      relay_handles(source, target, %{"control" => "control-secret"}, %{
        "control" => "control-secret",
        "fs" => "data-secret"
      })

    assert {:error, %Error{kind: :invalid_relay, response: %{accepted: ^migration}}} =
             Migration.relay(migration)

    assert WebSocketFixture.requests(source) == []
    assert WebSocketFixture.requests(target) == []
  end

  test "a later channel upgrade failure closes every previously opened relay socket", %{
    root: root
  } do
    source = cleanup_fixture(root, "cleanup-source")
    target = cleanup_fixture(root, "cleanup-target", "fs-secret")
    secrets = %{"control" => "control-secret", "fs" => "fs-secret"}
    migration = relay_handles(source, target, secrets, secrets, HTTPFixture)

    assert {:error, %Error{kind: :native, http_status: 403, response: %{accepted: ^migration}}} =
             Migration.relay(migration, timeout: 1000)

    for {name, secret} <- [
          {"cleanup-source", "control-secret"},
          {"cleanup-target", "control-secret"},
          {"cleanup-source", "fs-secret"}
        ] do
      assert_receive {:relay_peer_closed, ^name, ^secret, {:error, :closed}}, 1000
    end

    for fixture <- [source, target] do
      assert length(HTTPFixture.requests(fixture)) == 2
      assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))
    end
  end

  test "caller loss during relay releases all channels and preserves the original accepted handles",
       %{root: root} do
    source = cleanup_fixture(root, "owner-source")
    target = cleanup_fixture(root, "owner-target")
    secrets = %{"control" => "control-secret", "fs" => "fs-secret"}
    migration = relay_handles(source, target, secrets, secrets, HTTPFixture)
    caller = spawn(fn -> Migration.relay(migration, timeout: 5000) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    for name <- ["owner-source", "owner-target"], secret <- Map.values(secrets) do
      assert_receive {:relay_peer_opened, ^name, ^secret}, 1000
    end

    Process.exit(caller, :kill)

    for name <- ["owner-source", "owner-target"], secret <- Map.values(secrets) do
      assert_receive {:relay_peer_closed, ^name, ^secret, {:error, :closed}}, 1000
    end

    assert migration.source.url == "/1.0/operations/source"
    assert migration.target.url == "/1.0/operations/target"

    for fixture <- [source, target] do
      assert length(HTTPFixture.requests(fixture)) == 2
      assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))
    end
  end

  defp cleanup_fixture(root, name, rejected_secret \\ nil) do
    parent = self()

    start_supervised!(
      {HTTPFixture,
       transport: :gen_tcp,
       path: Path.join(root, name),
       handler: fn request ->
         secret = URI.decode_query(URI.parse(request.target).query)["secret"]

         if secret == rejected_secret do
           %{status: 403, body: %{type: "error", error_code: 403, error: "fixture refusal"}}
         else
           %{
             upgrade: fn transport, socket ->
               accept =
                 Base.encode64(
                   :crypto.hash(
                     :sha,
                     request.headers["sec-websocket-key"] <>
                       "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                   )
                 )

               :ok =
                 transport.send(
                   socket,
                   "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
                 )

               send(parent, {:relay_peer_opened, name, secret})
               result = peer_closed(transport, socket, System.monotonic_time(:millisecond) + 2000)
               send(parent, {:relay_peer_closed, name, secret, result})
             end
           }
         end
       end},
      id: make_ref()
    )
  end

  defp peer_closed(transport, socket, deadline) do
    case transport.recv(socket, 0, max(1, deadline - System.monotonic_time(:millisecond))) do
      {:ok, _} -> peer_closed(transport, socket, deadline)
      result -> result
    end
  end

  test "rejected relay upgrade retains native errors and accepted handles without replay", %{
    root: root
  } do
    source = relay_fixture(root, "source-rejected", wire: "", frame_handler: fn _, _ -> :ok end)

    target =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "target-rejected"),
         handler: fn _ ->
           %{
             status: 403,
             headers: [{"etag", "native-rejection"}],
             body: %{
               type: "error",
               error_code: 777,
               error: "native channel refusal",
               operation: "/1.0/operations/target"
             }
           }
         end},
        id: make_ref()
      )

    secrets = %{"control" => "control-secret"}
    migration = relay_handles(source, source, secrets, secrets)
    connection = Connection.unix!(HTTPFixture.endpoint(target).socket, owner: "target")
    target_client = %{migration.target.client | connection: connection}
    migration = %{migration | target: %{migration.target | client: target_client}}

    {result, log} =
      ExUnit.CaptureLog.with_log(fn -> Migration.relay(migration, timeout: 1000) end)

    assert {:error,
            %Error{
              kind: :native,
              http_status: 403,
              error_code: 777,
              message: "native channel refusal",
              operation: "/1.0/operations/target",
              response: %{accepted: ^migration, error: error}
            }} = result

    assert error.response.etag == "native-rejection"
    # Channel opening clamps only its budgets to the remaining relay deadline.
    assert %{
             error.response.connection
             | timeout: connection.timeout,
               stream_timeout: connection.stream_timeout
           } == connection

    assert error.response.identity == migration.target.client.context.identity
    assert length(WebSocketFixture.requests(source)) == 1
    assert [%{method: "GET"}] = HTTPFixture.requests(target)
    refute inspect(error) =~ "native channel refusal"
    refute inspect(error) =~ "control-secret"
    refute log =~ "control-secret"
    refute log =~ "native channel refusal"
  end

  defp relay_fixture(root, name, opts),
    do:
      start_supervised!({WebSocketFixture, [path: Path.join(root, name)] ++ opts}, id: make_ref())

  defp relay_handles(
         source,
         target,
         source_secrets,
         target_secrets,
         fixture_module \\ WebSocketFixture
       ) do
    operation = fn fixture, name, secrets ->
      client = %Incus{
        connection: Connection.unix!(relay_socket(fixture, fixture_module), owner: name),
        context: Context.new!(owner: name, identity: name, ready?: fn -> true end),
        server: %Server{api_extensions: []}
      }

      %Opsmaru.Incus.Operation{
        client: client,
        url: "/1.0/operations/" <> name,
        response: %Opsmaru.Incus.Response{metadata: %{"metadata" => secrets}}
      }
    end

    %Migration{
      mode: :relay,
      source: operation.(source, "source", source_secrets),
      target: operation.(target, "target", target_secrets)
    }
  end

  defp relay_socket(fixture, HTTPFixture), do: HTTPFixture.endpoint(fixture).socket
  defp relay_socket(fixture, WebSocketFixture), do: WebSocketFixture.path(fixture)

  defp source_request, do: {"MigrateInstance", %{"name" => "fixture"}, %{"migration" => true}}
  defp target_request, do: {"CreateInstance", %{}, %{"name" => "copy", "type" => "container"}}

  defp client(root, name, behavior) do
    parent = self()

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, name),
         handler: fn request ->
           send(parent, {:posted, name, request})

           if behavior == :disconnect do
             %{raw: ""}
           else
             %{
               status: 202,
               body: %{
                 type: "async",
                 status_code: 100,
                 operation: "/1.0/operations/" <> name,
                 metadata: %{
                   id: name,
                   status_code: 103,
                   metadata:
                     if(behavior == :invalid,
                       do: %{control: nil},
                       else: %{control: "transport-secret", fs: "transport-secret-fs"}
                     )
                 }
               }
             }
           end
         end},
        id: make_ref()
      )

    %Incus{
      connection:
        Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: name, timeout: 200),
      context: Context.new!(owner: name, identity: name, ready?: fn -> true end),
      server: %Server{
        api_extensions: [],
        environment: %{"addresses" => ["https://advertised.example"]}
      }
    }
  end
end
