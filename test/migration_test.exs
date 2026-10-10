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
