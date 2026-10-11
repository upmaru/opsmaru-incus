defmodule FoundationConsumer.EmbeddingTest do
  use ExUnit.Case
  alias Opsmaru.Incus.Connection
  alias Opsmaru.Incus.Discovery
  alias Opsmaru.Incus.DynamicConsole
  alias Opsmaru.Incus.EventListener
  alias Opsmaru.Incus.HTTP
  alias Opsmaru.Incus.Images
  alias Opsmaru.Incus.Model
  alias Opsmaru.Incus.NativeConfig
  alias Opsmaru.Incus.NetworkModels
  alias Opsmaru.Incus.Preseed
  alias Opsmaru.Incus.Response
  alias Opsmaru.Incus.Status
  alias Opsmaru.Incus.Tokens
  alias Opsmaru.Incus.WebSocket

  test "independent host endpoint and private Unix backend use direct library calls" do
    assert Process.whereis(FoundationConsumer.Endpoint)

    for name <- [OpsmaruWeb.Endpoint, Opsmaru.Repo, Opsmaru.PubSub],
        do: refute(Process.whereis(name))

    assert Supervisor.which_children(Opsmaru.Supervisor) == []
    Application.stop(:opsmaru)

    root = Path.join(System.tmp_dir!(), "op-consumer-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "incus.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    worker =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, {:request, request})

        body =
          Jason.encode!(%{
            type: "sync",
            status_code: 200,
            metadata: %{api_version: "1.0", api_extensions: [], environment: nil}
          })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Length: ",
            Integer.to_string(byte_size(body)),
            "\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    context =
      Opsmaru.Context.new!(
        owner: :macus_fixture,
        identity: :host_verified,
        ready?: fn -> Agent.get(FoundationConsumer.Runtime, & &1) end,
        private_state: Path.join(root, "state"),
        capabilities: %{runtime: FoundationConsumer.Runtime}
      )

    connection =
      Connection.unix!(path, owner: :macus_fixture, project: "host-project")

    assert {:error, %Opsmaru.Incus.Error{kind: :host_not_ready}} =
             Opsmaru.Incus.connect(connection, context)

    refute_receive {:request, _}, 30
    Agent.update(FoundationConsumer.Runtime, fn _ -> true end)
    assert {:ok, client} = Opsmaru.Incus.connect(connection, context)
    assert client.server.api_version == "1.0"
    assert_receive {:request, request}
    assert request =~ "GET /1.0?project=host-project HTTP/1.1"
    assert {:ok, info} = Discovery.connection_info(client)
    assert info.project == "host-project"
    assert {:ok, strict} = Discovery.require_authenticated(client)
    assert strict.connection.require_authenticated
    refute client.connection.require_authenticated
    assert Status.string(103) == "Running"

    assert {:ok, profile} =
             Model.decode("Profile", %{
               "name" => "host",
               "config" => %{"user.fixture" => "native"}
             })

    assert {:ok, writable} = Model.writable(profile)
    assert writable.data == %{"config" => %{"user.fixture" => "native"}}
    assert profile.data["name"] == "host"

    assert {:ok, %{"user.fixture" => "true"}} =
             NativeConfig.from_json("ConfigMap", ~s({"user.fixture":true}))

    assert {:error, %Opsmaru.Incus.Error{kind: :invalid_console_arguments}} =
             DynamicConsole.open(client, "fixture", %{}, max_attachments: 0)

    assert {:error, %Opsmaru.Incus.Error{kind: :invalid_image_arguments}} =
             Images.download(client, "fingerprint", %{}, secret: "fixture-secret")

    assert {:ok, %Preseed{changes: []}} = Preseed.apply(client, %{})

    assert {:ok, ports} =
             Model.decode(
               "NetworkForwardPort",
               %{"target_address" => "::ffff:c000:201", "listen_port" => " 80 , 443 "}
             )

    assert {:ok, ports} = NetworkModels.normalise(ports)
    assert ports.data["target_address"] == "192.0.2.1"
    assert ports.data["listen_port"] == "80,443"
    assert {:ok, http} = HTTP.client(client)

    assert {:error, %Opsmaru.Incus.Error{kind: :invalid_path}} =
             HTTP.request(http, "GET", "https://unselected.example/1.0")

    assert {:error, %Opsmaru.Incus.Error{kind: :invalid_websocket_options}} =
             WebSocket.open(client, "/1.0/events", headers: [{"authorization", "private"}])

    assert {:ok, %{}} = Response.metadata_as_map(%Response{metadata: nil})

    assert {:ok, operation} =
             Response.metadata_as_operation(%Response{metadata: %{"id" => "host-op"}})

    assert operation.data["id"] == "host-op"

    assert {:ok, token_operation} =
             Model.decode("Operation", %{
               "metadata" => %{
                 "request" => %{"name" => "host"},
                 "secret" => "fixture-token",
                 "fingerprint" => "fixture-fingerprint",
                 "addresses" => ["unapproved.example:8443"]
               }
             })

    assert {:ok, token} = Tokens.certificate(token_operation)
    assert {:ok, encoded_token} = Tokens.encode(token)
    assert Jason.decode!(Base.decode64!(encoded_token))["client_name"] == "host"
    refute inspect(token) =~ "fixture-token"

    Agent.update(FoundationConsumer.Runtime, fn _ -> false end)
    assert {:error, %Opsmaru.Incus.Error{kind: :host_not_ready}} = EventListener.open(client)
    Agent.update(FoundationConsumer.Runtime, fn _ -> true end)

    refute_receive {:request, _}, 30
    refute File.exists?(context.private_state)
    assert Process.whereis(FoundationConsumer.Endpoint)
    refute Process.whereis(Opsmaru.Supervisor)
  end
end
