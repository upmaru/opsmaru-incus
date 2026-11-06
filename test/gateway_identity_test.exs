defmodule Opsmaru.Incus.GatewayIdentityTest do
  use Opsmaru.TestSupport.GatewayCase, async: true

  alias Opsmaru.Incus.Gateway.{Identity, Policy}
  alias Opsmaru.TestSupport.{CertificateHost, TLSIdentity}

  defmodule NoIdentity do
    @behaviour Opsmaru.Incus.Gateway.Host
    @impl true
    def ready?(_), do: true
    @impl true
    def authorize(_, _), do: {:ok, :grant}
    @impl true
    def valid?(_, _, _), do: true
  end

  @driver Path.expand("../.integration/incus-gateway-identity", __DIR__)

  setup_all do
    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./gatewayidentity"],
        cd: Path.expand("reference", __DIR__),
        stderr_to_stdout: true,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    assert status == 0, output
    :ok
  end

  defp metadata do
    %{
      "auth" => "trusted",
      "api_version" => "1.0",
      "public" => false,
      "auth_methods" => ["tls"],
      "api_extensions" => [
        "certificate_update",
        "instance_nbd",
        "migration",
        "unknown_backend_feature"
      ],
      "environment" => %{
        "addresses" => ["10.0.2.15:8443", "/private/incus.sock", "127.0.0.1:8443"],
        "certificate" => "guest certificate",
        "server_name" => "guest",
        "server" => "incus",
        "server_version" => "7.0.1",
        "storage" => "zfs",
        "extra" => [1, nil, %{"preserved" => true}]
      },
      "config" => %{"core.https_address" => ":8443"},
      "future" => %{"native" => true}
    }
  end

  test "anonymous root and API discovery are native, bounded and backend-free", context do
    {backend, connection} = backend(context, reply(500, %{}))
    gateway = mount(context, connection)
    root = get(context, "/", [])
    assert native(root.body) == Identity.envelope(["/1.0"])
    response = get(context, "/1.0", [])
    assert response.status == 200

    assert native(response.body) ==
             Identity.envelope(%{
               "api_version" => "1.0",
               "api_status" => "stable",
               "auth" => "untrusted",
               "public" => false,
               "auth_methods" => ["tls"],
               "api_extensions" => ["certificate_update"]
             })

    assert byte_size(response.body) <= gateway.max_identity_bytes
    refute response.body =~ "environment"
    assert get(context, "/1.0/instances", []).status == 403
    assert get(context, "/1.0/", []).status == 403
    assert StreamBackend.accepted(backend) == 0
  end

  test "authenticated server identity changes only public identity and supported extensions",
       context do
    envelope = Identity.envelope(metadata()) |> Map.put("future_envelope", [1, 2])

    {backend, connection} =
      backend(context, reply(200, envelope, [{"etag", "\"guest\""}, {"x-native", "kept"}]))

    gateway = mount(context, connection)
    response = get(context, "/1.0?project=allowed")
    assert response.status == 200
    result = native(response.body)

    expected =
      put_in(
        envelope,
        ["metadata", "environment", "addresses"],
        gateway.host_config.identity.addresses
      )
      |> put_in(["metadata", "environment", "certificate"], context.public_certificate)
      |> put_in(["metadata", "api_extensions"], ["certificate_update"])

    assert result == expected
    assert RawHTTP.header(response, "x-native") == ["kept"]
    assert RawHTTP.header(response, "etag") == []

    assert RawHTTP.header(response, "content-length") == [
             Integer.to_string(byte_size(response.body))
           ]

    assert StreamBackend.accepted(backend) == 1
    assert_receive {:backend_request, %{target: "/1.0?project=allowed", headers: headers}}
    refute List.keymember?(headers, "authorization", 0)
  end

  test "identity is bound to verified backend metadata and refuses literal private endpoints",
       context do
    {backend, connection} = backend(context, reply(200, Identity.envelope(metadata())))
    gateway = mount(context, connection)
    identity = gateway.host_config.identity

    for invalid <- [
          %{
            identity
            | connection: Connection.unix!("/not-the-selected-backend", owner: :fixture)
          },
          %{identity | origin: "http://gateway.example.com"},
          %{identity | addresses: ["10.0.2.15:8443"]},
          %{identity | addresses: ["127.0.0.1:8443"]},
          %{identity | addresses: ["[::1]:8443"]},
          %{identity | addresses: ["unix:///private/incus.sock"]},
          %{identity | addresses: ["public.example.com:8443/private"]},
          %{identity | certificate: "not a certificate"}
        ] do
      mount(context, connection, host_config: %{identity: invalid})
      assert get(context, "/1.0").status == 503
      assert get(context, "/1.0", []).status == 503
    end

    assert StreamBackend.accepted(backend) == 0
  end

  test "missing, malformed, raising and late identity callbacks deny without backend access",
       context do
    {backend, connection} = backend(context, reply(200, %{}))
    parent = self()

    for callback <- [
          fn -> :bad end,
          fn -> raise "secret" end,
          fn ->
            send(parent, {:identity_callback, self()})
            Process.sleep(300)
            send(parent, :late_identity)
            {:ok, %{}}
          end
        ] do
      mount(context, connection, callback_timeout: 30, host_config: %{identity: callback})
      assert get(context, "/1.0", []).status == 503
    end

    assert_receive {:identity_callback, pid}
    refute Process.alive?(pid)
    refute_receive :late_identity, 350
    assert StreamBackend.accepted(backend) == 0
  end

  test "an absent optional identity callback denies rather than forwarding server identity",
       context do
    {backend, connection} = backend(context, reply(200, Identity.envelope(metadata())))
    gateway = mount(context, connection)
    GatewayServer.put_gateway(%{gateway | host: NoIdentity})
    assert get(context, "/1.0").status == 503
    assert StreamBackend.accepted(backend) == 0
  end

  test "identity success bodies buffer with strict bounds; native errors remain unchanged",
       context do
    for body <- ["not json", Jason.encode!(%{"metadata" => %{}}), :binary.copy("x", 2049)] do
      {_, connection} =
        backend(context, fn conn ->
          StreamBackend.write(conn, [
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n",
            body
          ])
        end)

      mount(context, connection, max_identity_bytes: 2048)
      response = get(context, "/1.0")
      assert response.status == 502
      assert native(response.body)["type"] == "error"
      refute response.body =~ "guest certificate"
    end

    error = %{
      "type" => "error",
      "error" => "native backend error",
      "error_code" => 412,
      "metadata" => %{"native" => [1, 2]}
    }

    {_, connection} = backend(context, reply(412, error, [{"etag", "native"}]))
    mount(context, connection)
    response = get(context, "/1.0")
    assert {response.status, native(response.body)} == {412, error}
    assert RawHTTP.header(response, "etag") == ["native"]
  end

  test "certificate routes never reach guest trust and reject unsupported restricted claims",
       context do
    {backend, connection} = backend(context, reply(200, %{}))
    mount(context, connection)

    for claims <- [
          %{"restricted" => true},
          %{"projects" => ["allowed"]},
          %{"type" => "server"},
          %{"token" => true},
          %{"unknown" => true}
        ] do
      response =
        RawHTTP.request(
          context.port,
          "POST",
          "/1.0/certificates",
          [auth()],
          Jason.encode!(claims)
        )

      assert response.status == 400
      assert native(response.body)["error"] =~ "not enforceable"
    end

    for {method, path} <- [
          {"GET", "/1.0/certificates"},
          {"GET", "/1.0/certificates?recursion=1"},
          {"POST", "/1.0/certificates"},
          {"GET", "/1.0/%63ertificates"},
          {"GET", "/1.0/certificates%2F" <> String.duplicate("a", 64)}
        ] do
      response = RawHTTP.request(context.port, method, path, [auth()])
      assert response.status in [403, 405]
    end

    assert StreamBackend.accepted(backend) == 0
  end

  test "certificate input and output are bounded, native failures and ETag conditions are delegated",
       context do
    {backend, connection} = backend(context, reply(200, %{}))
    gateway = mount(context, connection, max_identity_bytes: 1024)

    response =
      RawHTTP.request(
        context.port,
        "POST",
        "/1.0/certificates",
        [auth()],
        Jason.encode!(%{"name" => String.duplicate("x", 2048)})
      )

    assert response.status == 413
    assert StreamBackend.accepted(backend) == 0
    # A missing optional callback is denial, never backend trust fallback.
    assert gateway.host == GatewayHost
    assert get(context, "/1.0/certificates").status == 403
  end

  test "certificate callbacks enforce deadlines and reject oversized or restricted output",
       context do
    {backend, connection} = backend(context, reply(200, %{}))

    for result <- [
          {:ok, %{"restricted" => true}, []},
          {:ok, %{"name" => String.duplicate("x", 2048)}, []},
          {:ok, %{}, [{"etag", "bad\r\nheader"}]},
          {:ok, %{}, [{"set-cookie", "forbidden"}]}
        ] do
      mount(context, connection,
        max_identity_bytes: 1024,
        host_config: %{certificates: fn _, _, _, _ -> result end}
      )

      assert get(context, "/1.0/certificates").status == 502
    end

    observer = self()

    mount(context, connection,
      callback_timeout: 30,
      host_config: %{
        certificates: fn _, _, _, _ ->
          send(observer, {:certificate_callback, self()})
          Process.sleep(300)
          send(observer, :late_certificate)
          {:ok, %{}, []}
        end
      }
    )

    response = RawHTTP.request(context.port, "POST", "/1.0/certificates", [auth()], "{}")
    assert response.status == 403
    assert native(response.body)["metadata"]["gateway"]["outcome"] == "uncertain"
    assert_receive {:certificate_callback, worker}
    refute Process.alive?(worker)
    refute_receive :late_certificate, 350
    assert StreamBackend.accepted(backend) == 0
  end

  test "chunked certificate JSON and native ETag preconditions reach only host policy", context do
    {backend, connection} = backend(context, reply(200, %{}))
    observer = self()
    fingerprint = String.duplicate("a", 64)

    mount(context, connection,
      host_config: %{
        certificates: fn action, request, grant, input ->
          send(observer, {:certificate_input, action, request.query, grant, input})
          if input.if_match == "wrong", do: {:error, 412}, else: {:ok, %{}, [{"etag", "new"}]}
        end
      }
    )

    client = RawHTTP.connect(context.port)

    RawHTTP.send!(
      client,
      RawHTTP.head("PUT", "/1.0/certificates/" <> fingerprint, [
        auth(),
        {"if-match", "old"},
        {"transfer-encoding", "chunked"},
        {"connection", "close"}
      ])
    )

    body = Jason.encode!(%{"name" => "renamed"})
    RawHTTP.send!(client, [Integer.to_string(byte_size(body), 16), "\r\n", body, "\r\n0\r\n\r\n"])
    response = RawHTTP.read(client)
    assert response.status == 200
    assert RawHTTP.header(response, "etag") == ["new"]

    assert_receive {:certificate_input, :update, "", :fixture_grant,
                    %{body: %{"name" => "renamed"}, fingerprint: ^fingerprint, if_match: "old"}}

    assert RawHTTP.request(context.port, "DELETE", "/1.0/certificates/" <> fingerprint, [
             auth(),
             {"if-match", "wrong"}
           ]).status == 412

    assert StreamBackend.accepted(backend) == 0
  end

  test "unsized trust bodies obey both identity and general body budgets", context do
    {backend, connection} = backend(context, reply(200, %{}))
    observer = self()

    mount(context, connection,
      max_identity_bytes: 1024,
      host_config: %{
        certificates: fn _, _, _, _ ->
          send(observer, :unexpected_enrollment)
          {:ok, %{}, []}
        end
      }
    )

    client = RawHTTP.connect(context.port)

    RawHTTP.send!(
      client,
      RawHTTP.head("POST", "/1.0/certificates", [
        auth(),
        {"transfer-encoding", "chunked"},
        {"connection", "close"}
      ])
    )

    body = Jason.encode!(%{"name" => String.duplicate("x", 2048)})
    RawHTTP.send!(client, [Integer.to_string(byte_size(body), 16), "\r\n", body, "\r\n0\r\n\r\n"])
    assert RawHTTP.read(client).status == 413
    refute_received :unexpected_enrollment

    for body <- ["not json", "[]"] do
      assert RawHTTP.request(context.port, "POST", "/1.0/certificates", [auth()], body).status ==
               400
    end

    mount(context, connection, max_request_bytes: 1)

    assert RawHTTP.request(context.port, "POST", "/1.0/certificates", [auth()], "{}").status ==
             413

    mount(context, connection, max_response_bytes: 1)
    assert get(context, "/", []).status == 502
    assert StreamBackend.accepted(backend) == 0
  end

  test "unmodified pinned client enrolls, updates, deletes and gets only gateway addresses",
       context do
    server = TLSIdentity.generate(context.root, "enrollment-server", "localhost")
    client = TLSIdentity.generate(context.root, "enrollment-client", "incus-client")
    {ref, port} = GatewayServer.start_https(server, client.cafile)
    on_exit(fn -> GatewayServer.stop(ref) end)
    {backend, connection} = backend(context, reply(200, Identity.envelope(metadata())))
    gateway = mount(context, connection)
    state = start_supervised!({CertificateHost, trust: %{}, token: "fixture-enrollment-token"})
    identity = %{gateway.host_config.identity | certificate: File.read!(server.certfile)}

    GatewayServer.put_gateway(%{
      gateway
      | host: CertificateHost,
        host_config: %{state: state, identity: identity}
    })

    input = %{
      "URL" => "https://localhost:#{port}",
      "ServerCertificate" => identity.certificate,
      "ClientCertificate" => File.read!(client.certfile),
      "ClientKey" => File.read!(client.keyfile),
      "Token" => "fixture-enrollment-token",
      "Fingerprint" => CertificateHost.fingerprint(client.der)
    }

    path = Path.join(context.root, "enrollment.json")
    File.write!(path, Jason.encode!(input))
    File.chmod!(path, 0o600)
    {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
    assert status == 0, output
    result = native(output)
    assert result["before"]["auth"] == "untrusted"
    assert result["after"]["auth"] == "trusted"
    assert result["final"]["auth"] == "untrusted"

    assert result["info"]["Addresses"] == [
             "https://localhost:#{port}",
             "https://gateway.example.com:8443"
           ]

    assert result["info"]["Certificate"] == identity.certificate
    assert result["after"]["environment"]["certificate"] == identity.certificate
    assert result["updated"]["name"] == "updated by pinned client"
    assert [%{"restricted" => false, "projects" => []}] = result["certificates"]
    assert Agent.get(state, & &1.trust) == %{}
    assert Agent.get(state, & &1.token) == nil
    assert StreamBackend.accepted(backend) >= 1

    for _ <- 1..StreamBackend.accepted(backend) do
      assert_receive {:backend_request, %{method: "GET", target: "/1.0", headers: headers}}
      refute List.keymember?(headers, "authorization", 0)
    end

    refute_receive {:backend_request, _}, 50
  end

  test "wrong enrollment tokens and restricted certificate identities never acquire guest trust",
       context do
    server = TLSIdentity.generate(context.root, "denial-server", "localhost")
    client = TLSIdentity.generate(context.root, "denial-client", "incus-client")
    {ref, port} = GatewayServer.start_https(server, client.cafile)
    on_exit(fn -> GatewayServer.stop(ref) end)
    {backend, connection} = backend(context, reply(200, Identity.envelope(metadata())))
    gateway = mount(context, connection)
    state = start_supervised!({CertificateHost, trust: %{}, token: "single-use"})
    identity = %{gateway.host_config.identity | certificate: File.read!(server.certfile)}

    GatewayServer.put_gateway(%{
      gateway
      | host: CertificateHost,
        host_config: %{state: state, identity: identity}
    })

    tls = [
      verify: :verify_peer,
      cacertfile: String.to_charlist(server.cafile),
      certfile: String.to_charlist(client.certfile),
      keyfile: String.to_charlist(client.keyfile)
    ]

    for body <- [
          %{"trust_token" => "wrong", "type" => "client"},
          %{"trust_token" => "single-use", "restricted" => true},
          %{"trust_token" => "single-use", "certificate" => Base.encode64(server.der)}
        ] do
      response = RawHTTP.request(port, "POST", "/1.0/certificates", [], Jason.encode!(body), tls)
      assert response.status in [400, 403]
      assert Agent.get(state, & &1.trust) == %{}
      assert Agent.get(state, & &1.token) == "single-use"
    end

    fingerprint = CertificateHost.fingerprint(client.der)
    Agent.update(state, &%{&1 | trust: %{fingerprint => %{role: :restricted}}})
    assert RawHTTP.request(port, "GET", "/1.0", [], "", tls).status == 403
    assert RawHTTP.request(port, "GET", "/1.0/certificates", [], "", tls).status == 403
    assert StreamBackend.accepted(backend) == 0
  end

  test "policy callback workers die if their exchange disappears", _context do
    observer = self()

    owner =
      spawn(fn ->
        Policy.callback(
          fn ->
            send(observer, {:worker, self()})
            Process.sleep(:infinity)
          end,
          1000
        )
      end)

    assert_receive {:worker, worker}
    monitor = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 200
  end
end
