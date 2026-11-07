defmodule FoundationConsumer.GatewayTest do
  use ExUnit.Case, async: false

  alias FoundationConsumer.{GatewayEndpoint, GatewayRouter}
  alias Opsmaru.Incus.{Connection, Gateway}
  alias Opsmaru.Incus.Gateway.Admission

  alias Opsmaru.TestSupport.{
    CertificateHost,
    HTTPFixture,
    NativeWebSocketBackend,
    StreamBackend,
    TLSIdentity
  }

  alias Opsmaru.TestSupport.NativeMigrationBackend, as: MigrationBackend

  defmodule MigrationHost do
    @behaviour Opsmaru.Incus.Gateway.Host
    def ready?(_), do: true

    def authorize(request, config) do
      if request.peer.certificate == config.client.der and
           request.project in [nil, "migration-project"],
         do: {:ok, :consumer},
         else: {:error, :unauthenticated}
    end

    def valid?(_, grant, _), do: grant in [:consumer, :pending_migration]
    def identity(_, config), do: {:ok, config.identity}

    def admit_operation_secret(request, config) do
      if request.operation == config.operation and request.project in [nil, "migration-project"] and
           request.target == nil and request.peer.address == {127, 0, 0, 1},
         do: {:ok, :pending_migration},
         else: {:error, :forbidden}
    end
  end

  @extensions ~w(certificate_update instances console instance_nbd custom_volume_sftp storage_volume_nbd)
  @drivers ~w(execio console eventhandlers directwebsocket sftphelpers gatewayidentity files gatewaymigration)

  setup_all do
    root = Path.join(System.tmp_dir!(), "consumer-gateway-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    server = TLSIdentity.generate(root, "host", "localhost")
    client = TLSIdentity.generate(root, "client", "client")
    listeners = :ranch.info()
    unavailable = Path.join(root, "never-opened.sock")
    assert Application.spec(:opsmaru_incus, :mod) == []
    refute Process.whereis(GatewayEndpoint)

    passive =
      Gateway.new!(
        connection: Connection.unix!(unavailable, owner: :consumer_fixture),
        host: CertificateHost,
        host_config: %{not_started: true},
        admission: self()
      )

    assert passive.connection.address == unavailable
    assert :ranch.info() == listeners
    refute File.exists?(unavailable)

    start_supervised!(%{
      id: FoundationConsumer.GatewayConfig,
      start: {Agent, :start_link, [fn -> nil end, [name: FoundationConsumer.GatewayConfig]]}
    })

    Application.put_env(:foundation_consumer, GatewayEndpoint,
      adapter: Phoenix.Endpoint.Cowboy2Adapter,
      server: true,
      secret_key_base: String.duplicate("consumer-fixture-", 8),
      https: [
        dispatch: GatewayEndpoint.dispatch(),
        ip: {127, 0, 0, 1},
        port: 0,
        certfile: server.certfile,
        keyfile: server.keyfile,
        cacertfile: client.cafile,
        verify: :verify_peer,
        fail_if_no_peer_cert: false,
        alpn_preferred_protocols: ["http/1.1"]
      ]
    )

    start_supervised!(GatewayEndpoint)
    port = :ranch.get_port(GatewayEndpoint.HTTPS)
    File.mkdir_p!(".integration")

    for name <- ["." | Enum.map(@drivers, &("./" <> &1))] do
      output = if name == ".", do: "native", else: Path.basename(name)

      {log, status} =
        System.cmd(
          "mise",
          ["exec", "--", "go", "build", "-o", "../../.integration/#{output}", name],
          cd: "test/reference",
          env: [{"GOTOOLCHAIN", "local"}],
          stderr_to_stdout: true
        )

      assert status == 0, log
    end

    conf = System.fetch_env!("INCUS_CONF")
    File.mkdir_p!(Path.join(conf, "servercerts"))
    File.cp!(client.certfile, Path.join(conf, "client.crt"))
    File.cp!(client.keyfile, Path.join(conf, "client.key"))
    File.cp!(server.certfile, Path.join(conf, "servercerts/gateway.crt"))

    File.write!(
      Path.join(conf, "config.yml"),
      "config: {}\nremotes:\n  gateway:\n    addr: https://localhost:#{port}\n    auth_type: tls\n    project: default\ndefault-remote: gateway\n"
    )

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{root: root, port: port, server: server, client: client}
  end

  setup context do
    File.write!(
      Path.join(System.fetch_env!("INCUS_CONF"), "config.yml"),
      "config: {}\nremotes:\n  gateway:\n    addr: https://localhost:#{context.port}\n    auth_type: tls\n    project: default\ndefault-remote: gateway\n"
    )

    admission = start_supervised!({Admission, max_exchanges: 16})

    trust = %{
      CertificateHost.fingerprint(context.client.der) => %{
        role: :owner_admin,
        expires: System.monotonic_time(:millisecond) + 120_000,
        certificate: File.read!(context.client.certfile),
        name: "consumer"
      }
    }

    state = start_supervised!({CertificateHost, trust: trust, token: "consumer-token"})
    %{admission: admission, trust: state}
  end

  test "consumer endpoint owns native HTTP, CLI discovery, errors, binary upload/download and host routes",
       context do
    payload = :binary.copy(<<0, 255, 128, 13, 10>>, 100_000)
    parent = self()

    fixture =
      fixture(context, fn request ->
        case URI.parse(request.target).path do
          "/1.0" ->
            discovery()

          "/1.0/instances/fixture" ->
            sync(%{name: "fixture", type: "container", status: "Stopped", status_code: 102})

          "/1.0/instances/fixture/files" ->
            if request.method == "POST" do
              send(parent, {:uploaded, request.body})
              sync(%{})
            else
              %{
                raw: [
                  "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(payload)}\r\nConnection: close\r\nX-Incus-type: file\r\nX-Incus-mode: 0644\r\nX-Incus-uid: 0\r\nX-Incus-gid: 0\r\n\r\n",
                  payload
                ]
              }
            end

          _ ->
            %{status: 404, body: %{type: "error", error: "native missing", error_code: 404}}
        end
      end)

    mount(context, HTTPFixture.endpoint(fixture).socket)
    {body, 0} = cli(["query", "gateway:/1.0"])

    assert Jason.decode!(body)["environment"]["addresses"] == [
             "gateway.example.com:#{context.port}"
           ]

    refute body =~ "10.0.2.15"
    {error, status} = cli(["query", "gateway:/1.0/missing"])
    assert status != 0
    assert error =~ "native missing"

    input =
      Map.merge(lower_credentials(context), %{
        instance: "fixture",
        path: "/binary",
        type: "file",
        mode: 420
      })

    pushed =
      driver(
        context,
        "files",
        Map.merge(input, %{action: "CreateInstanceFile", payload: Base.encode64(payload)}),
        :file
      )

    refute pushed["error"]
    assert_receive {:uploaded, ^payload}, 2_000
    pulled = driver(context, "files", Map.put(input, :action, "GetInstanceFile"), :file)
    refute pulled["error"]

    assert :crypto.hash(:sha256, Base.decode64!(pulled["bytes"])) ==
             :crypto.hash(:sha256, payload)

    assert tls_request(context, "GET", "/runtime").body == "consumer-runtime"
    assert tls_request(context, "POST", "/mcp", "{}").body == "consumer-mcp:{}"
    count = length(HTTPFixture.requests(fixture))
    assert tls_request(context, "GET", "/1.0/instances", "", false).status == 403
    assert length(HTTPFixture.requests(fixture)) == count
    assert Application.spec(:opsmaru_incus, :mod) == []
  end

  test "test-only trust enrollment and identity mediation traverse consumer endpoint", context do
    fixture = fixture(context, fn _ -> discovery() end)
    Agent.update(context.trust, &%{&1 | trust: %{}})
    mount(context, HTTPFixture.endpoint(fixture).socket)

    input =
      Map.merge(credentials(context), %{
        ServerCertificate: File.read!(context.server.certfile),
        ClientCertificate: File.read!(context.client.certfile),
        ClientKey: File.read!(context.client.keyfile),
        Token: "consumer-token",
        Fingerprint: CertificateHost.fingerprint(context.client.der)
      })

    result = driver(context, "gatewayidentity", input, :file)
    assert result["before"]["auth"] == "untrusted"
    assert result["after"]["auth"] == "trusted"
    assert result["final"]["auth"] == "untrusted"

    assert result["info"]["Addresses"] == [
             "https://localhost:#{context.port}",
             "https://gateway.example.com:#{context.port}"
           ]

    refute Enum.any?(HTTPFixture.requests(fixture), &String.contains?(&1.target, "certificates"))
  end

  test "native exec, console, events and operation channels share the consumer endpoint",
       context do
    for mode <- [:exec, :console, :events] do
      fixture = NativeWebSocketBackend.start(context, mode)
      mount(context, HTTPFixture.endpoint(fixture).socket)

      case mode do
        :exec ->
          result =
            driver(
              context,
              "execio",
              Map.merge(credentials(context), %{
                Mode: "collect",
                Stdin: "",
                Body: %{
                  "command" => ["fixture"],
                  "wait-for-websocket" => true,
                  "interactive" => false
                }
              })
            )

          assert Base.decode64!(result["stdout"]) == <<0, 255, 128, 10>>
          assert result["operation"]["metadata"]["return"] == 7

        :console ->
          result =
            driver(
              context,
              "console",
              Map.merge(lower_credentials(context), %{
                mode: "static",
                payload: Base.encode64(<<42>>),
                expect: 4,
                body: %{}
              })
            )

          assert result["outputs"] == [Base.encode64(<<0, 255, 128, 42>>)]

        :events ->
          result =
            driver(
              context,
              "eventhandlers",
              Map.merge(lower_credentials(context), %{
                event: %{type: "logging", metadata: %{message: "consumer"}}
              })
            )

          assert result["event"]["metadata"]["message"] == "consumer"

          result =
            driver(
              context,
              "directwebsocket",
              Map.merge(lower_credentials(context), %{
                path: "/1.0/operations/native/websocket?secret=operation"
              })
            )

          assert result["status"] == 101
      end

      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.method == "DELETE"))
    end
  end

  test "unchanged instance and volume raw clients traverse consumer Cowboy dispatch", context do
    for protocol <- ~w(sftp nbd volume_sftp volume_nbd) do
      raw = if String.ends_with?(protocol, "sftp"), do: "sftp", else: "nbd"
      path = Path.join(context.root, "raw-#{protocol}.sock")

      backend =
        start_supervised!(
          {StreamBackend,
           path: path,
           observer: self(),
           script: fn conn ->
             if URI.parse(conn.head.target).path == "/1.0" do
               StreamBackend.write(conn, StreamBackend.json(200, discovery().body))
             else
               StreamBackend.write(
                 conn,
                 "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: #{raw}\r\n\r\n"
               )

               # Approved pinned rawConn oracle exception; coalesced-byte tests are
               # stronger library fixture evidence, never claimed by this driver.
               Process.sleep(150)
               StreamBackend.write(conn, <<0, 255, 128>>)
               {:ok, bytes} = conn.transport.recv(conn.socket, 3, 3_000)
               StreamBackend.write(conn, bytes)
             end
           end},
          id: make_ref()
        )

      mount(context, path)

      result =
        driver(
          context,
          "native",
          Map.merge(lower_credentials(context), %{
            protocol: protocol,
            pool: "pool",
            volume_type: "custom",
            name: "v",
            read_initial: 3,
            payload: Base.encode64(<<255, 0, 42>>)
          }),
          :file
        )

      assert result["initial"] == Base.encode64(<<0, 255, 128>>)
      assert result["echo"] == Base.encode64(<<255, 0, 42>>)
      assert StreamBackend.accepted(backend) == 2
    end
  end

  test "native pkg/sftp read and write sessions use the consumer endpoint", context do
    parent = self()

    for kind <- ["instance", "volume"] do
      path = Path.join(context.root, "sftp-#{kind}.sock")

      start_supervised!(
        {StreamBackend,
         path: path,
         observer: self(),
         script: fn conn ->
           if URI.parse(conn.head.target).path == "/1.0" do
             StreamBackend.write(conn, StreamBackend.json(200, discovery().body))
           else
             StreamBackend.write(
               conn,
               "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: sftp\r\n\r\n"
             )

             assert packet(conn) == <<1, 3::32>>
             send_packet(conn, <<2, 3::32>>)
             sftp_packets(conn, parent)
           end
         end},
        id: make_ref()
      )

      mount(context, path)

      result =
        driver(
          context,
          "sftphelpers",
          Map.merge(credentials(context), %{
            Kind: kind,
            Name: "file",
            Pool: "pool",
            VolumeType: "custom",
            Steps: [
              %{Op: "open", Path: "binary", Mode: "create"},
              %{Op: "read", Count: 5, Offset: 3},
              %{Op: "write", Offset: 9, Data: Base.encode64(<<255, 0, 128, 13, 10>>)},
              %{Op: "close_file"}
            ]
          })
        )

      assert result["accepted"] and result["close_ok"]
      assert Enum.all?(result["steps"], & &1["ok"])
      assert Enum.at(result["steps"], 1)["data"] == Base.encode64(<<0, 255, 128, 13, 10>>)
      assert_receive {:sftp_written, <<255, 0, 128, 13, 10>>}, 2_000
    end
  end

  @tag timeout: 180_000, migration: true
  test "unmodified CLI copies and moves instances and snapshots in every mode and gateway orientation",
       context do
    MigrationBackend.build!()
    peer_identity = TLSIdentity.generate(context.root, "peer", "localhost")

    for kind <- [:instance, :snapshot],
        action <- ~w(copy move),
        mode <- ~w(relay pull push),
        orientation <- [:source, :target] do
      log = start_supervised!({Agent, fn -> [] end}, id: make_ref())

      source =
        MigrationBackend.start(context, "source",
          log: log,
          transport:
            if(orientation == :source, do: :unix, else: {:https, peer_identity, context.client})
        )

      target =
        MigrationBackend.start(context, "target",
          log: log,
          transport:
            if(orientation == :target, do: :unix, else: {:https, peer_identity, context.client})
        )

      gateway_side = if orientation == :source, do: source, else: target

      identity = %{
        origin: "https://gateway.example.com:#{context.port}",
        addresses: ["gateway.example.com:#{context.port}"],
        certificate: File.read!(context.server.certfile),
        connection: gateway_side.connection,
        api_extensions: MigrationBackend.extensions()
      }

      gateway =
        Gateway.new!(
          connection: gateway_side.connection,
          admission: context.admission,
          host: MigrationHost,
          host_config: %{identity: identity, client: context.client, operation: gateway_side.name}
        )

      GatewayRouter.configure(gateway)

      source_url =
        if orientation == :source,
          do: "https://localhost:#{context.port}",
          else: source.endpoint.url

      target_url =
        if orientation == :target,
          do: "https://localhost:#{context.port}",
          else: target.endpoint.url

      conf = System.fetch_env!("INCUS_CONF")

      File.cp!(
        if(orientation == :source, do: context.server.certfile, else: peer_identity.certfile),
        Path.join(conf, "servercerts/source.crt")
      )

      File.cp!(
        if(orientation == :target, do: context.server.certfile, else: peer_identity.certfile),
        Path.join(conf, "servercerts/target.crt")
      )

      File.write!(
        Path.join(conf, "config.yml"),
        "config: {}\nremotes:\n  source:\n    addr: #{source_url}\n    auth_type: tls\n    project: migration-project\n  target:\n    addr: #{target_url}\n    auth_type: tls\n    project: migration-project\ndefault-remote: source\n"
      )

      resource = if kind == :instance, do: "source", else: "source/snapshot"

      {output, status} =
        cli([action, "source:#{resource}", "target:destination", "--mode", mode, "--quiet"])

      assert status == 0,
             inspect({kind, action, mode, orientation, output, MigrationBackend.events(source)})

      for side <- [source, target] do
        assert Enum.count(MigrationBackend.requests(side), &(&1.method == "POST")) == 1
      end

      deleted = Enum.filter(MigrationBackend.requests(source), &(&1.method == "DELETE"))
      assert length(deleted) == if(action == "move", do: 1, else: 0)

      if action == "move",
        do:
          assert(
            hd(deleted).target ==
              if(kind == :instance,
                do: "/1.0/instances/source?project=migration-project",
                else: "/1.0/instances/source/snapshots/snapshot?project=migration-project"
              )
          )

      refute Enum.any?(MigrationBackend.requests(target), &(&1.method == "DELETE"))
      assert Enum.any?(MigrationBackend.events(source), &match?({:frame, _, _, _}, &1))
      # The finite matrix owns these fixture listeners under the test
      # supervisor; none can survive this test's teardown.
    end
  end

  defp sftp_packets(conn, parent) do
    case packet(conn) do
      <<3, id::32, _::binary>> ->
        send_packet(conn, <<102, id::32, 1::32, "h">>)
        sftp_packets(conn, parent)

      <<5, id::32, _::binary>> ->
        send_packet(conn, <<103, id::32, 5::32, 0, 255, 128, 13, 10>>)
        sftp_packets(conn, parent)

      <<6, id::32, 1::32, "h", _::64, size::32, data::binary-size(size)>> ->
        send(parent, {:sftp_written, data})
        send_packet(conn, <<101, id::32, 0::32, 0::32, 0::32>>)
        sftp_packets(conn, parent)

      <<4, id::32, _::binary>> ->
        send_packet(conn, <<101, id::32, 0::32, 0::32, 0::32>>)
        conn.transport.recv(conn.socket, 0, 3_000)
    end
  end

  defp packet(conn) do
    {:ok, <<size::32>>} = conn.transport.recv(conn.socket, 4, 3_000)
    {:ok, bytes} = conn.transport.recv(conn.socket, size, 3_000)
    bytes
  end

  defp send_packet(conn, bytes),
    do: conn.transport.send(conn.socket, <<byte_size(bytes)::32, bytes::binary>>)

  defp fixture(context, handler),
    do:
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(context.root, "http-#{System.unique_integer([:positive])}.sock"),
         handler: handler},
        id: make_ref()
      )

  defp mount(context, path) do
    connection = Connection.unix!(path, owner: :consumer_fixture)

    gateway =
      Gateway.new!(
        connection: connection,
        admission: context.admission,
        host: CertificateHost,
        host_config: %{
          state: context.trust,
          identity: %{
            origin: "https://gateway.example.com:#{context.port}",
            addresses: ["gateway.example.com:#{context.port}"],
            certificate: File.read!(context.server.certfile),
            connection: connection,
            api_extensions: @extensions
          }
        }
      )

    GatewayRouter.configure(gateway)
    gateway
  end

  defp credentials(context),
    do: %{
      URL: "https://localhost:#{context.port}",
      CA: File.read!(context.server.cafile),
      Cert: File.read!(context.client.certfile),
      Key: File.read!(context.client.keyfile),
      ServerCert: File.read!(context.server.certfile)
    }

  defp lower_credentials(context),
    do: %{
      url: "https://localhost:#{context.port}",
      ca: File.read!(context.server.cafile),
      tls_ca: File.read!(context.server.cafile),
      server_cert: File.read!(context.server.certfile),
      cert: File.read!(context.client.certfile),
      key: File.read!(context.client.keyfile),
      client_cert: File.read!(context.client.certfile),
      client_key: File.read!(context.client.keyfile)
    }

  defp cli(args),
    do: System.cmd(System.fetch_env!("OPSMARU_INCUS_FIXTURE_CLI"), args, stderr_to_stdout: true)

  defp driver(context, name, input, mode \\ :stdin) do
    path = Path.join(context.root, "input-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(input))
    File.chmod!(path, 0o600)
    binary = Path.expand(".integration/#{name}")

    {output, status} =
      if mode == :file,
        do: System.cmd(binary, [path], stderr_to_stdout: true),
        else:
          System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "consumer-driver", binary, path],
            stderr_to_stdout: true
          )

    assert status == 0, output
    Jason.decode!(output)
  end

  defp tls_request(context, method, target, body \\ "", authenticated \\ true) do
    opts = [
      :binary,
      active: false,
      verify: :verify_peer,
      cacertfile: String.to_charlist(context.server.cafile),
      server_name_indication: ~c"localhost"
    ]

    opts =
      if authenticated,
        do:
          opts ++
            [
              certfile: String.to_charlist(context.client.certfile),
              keyfile: String.to_charlist(context.client.keyfile)
            ],
        else: opts

    {:ok, socket} = :ssl.connect(~c"localhost", context.port, opts, 5_000)

    :ok =
      :ssl.send(socket, [
        Opsmaru.TestSupport.RawHTTP.head(method, target, [
          {"content-length", Integer.to_string(byte_size(body))},
          {"connection", "close"}
        ]),
        body
      ])

    response = receive_response(socket, "")
    :ssl.close(socket)
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    %{status: head |> String.split(" ") |> Enum.at(1) |> String.to_integer(), body: body}
  end

  defp receive_response(socket, data) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, bytes} -> receive_response(socket, data <> bytes)
      {:error, :closed} -> data
    end
  end

  defp sync(metadata),
    do: %{
      status: 200,
      body: %{type: "sync", status: "Success", status_code: 200, metadata: metadata}
    }

  defp discovery,
    do:
      sync(%{
        api_version: "1.0",
        auth: "trusted",
        api_status: "stable",
        public: false,
        api_extensions: @extensions,
        environment: %{
          addresses: ["10.0.2.15:8443"],
          certificate: "private guest",
          server: "incus",
          server_version: "7.0.1"
        }
      })
end
