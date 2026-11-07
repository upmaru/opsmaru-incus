defmodule Opsmaru.TestSupport.RawGatewayRouter do
  @moduledoc false
  alias Opsmaru.Incus.Gateway.Plug, as: GatewayPlug

  def call(%{request_path: "/runtime"} = conn, _),
    do: Plug.Conn.send_resp(conn, 200, "host-runtime")

  def call(%{request_path: "/echo"} = conn, _) do
    Plug.Conn.upgrade_adapter(
      conn,
      :websocket,
      {Opsmaru.TestSupport.RawFallbackWebSocket, %{}, %{idle_timeout: 2_000}}
    )
  end

  def call(conn, gateway), do: GatewayPlug.call(conn, {:static, gateway})
end

defmodule Opsmaru.TestSupport.RawFallbackWebSocket do
  @moduledoc false
  def websocket_init(state), do: {:ok, state}
  def websocket_handle({:text, bytes}, state), do: {:reply, {:text, bytes}, state}
  def websocket_info(_, state), do: {:ok, state}
end

defmodule Opsmaru.TestSupport.RawForeignHandler do
  @moduledoc false
  def init(req, state), do: {Opsmaru.TestSupport.RawForeignProtocol, req, state, %{}}
end

defmodule Opsmaru.TestSupport.RawForeignProtocol do
  @moduledoc false
  alias Opsmaru.TestSupport.RawForeignHandler

  def upgrade(req, env, RawForeignHandler, :host_state, %{}) do
    body = "host-" <> :cowboy_req.header("upgrade", req)
    {:ok, :cowboy_req.reply(200, %{}, body, req), env}
  end
end

defmodule Opsmaru.Incus.GatewayRawUpgradeTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.Incus.Gateway.CowboyHandler
  alias Opsmaru.TestSupport.RawGatewayRouter
  @driver Path.expand("../.integration/incus-gateway-raw-driver", __DIR__)
  @initial <<0, 255, 128>>
  @sftp_driver Path.expand("../.integration/incus-gateway-sftp-driver", __DIR__)

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @sftp_driver, "./sftphelpers"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    :ok
  end

  for protocol <- ["sftp", "nbd"] do
    test "#{protocol}: both prefetched buffers arrive exactly once and full duplex stays native",
         context do
      protocol = unquote(protocol)
      parent = self()

      {backend, connection} =
        backend(context, fn conn ->
          StreamBackend.write(conn, upgrade(protocol, @initial))
          assert {:ok, "client-prefetch"} = conn.transport.recv(conn.socket, 15, 2_000)
          send(parent, :prefetch_once)
          assert {:ok, bytes} = conn.transport.recv(conn.socket, 5, 2_000)
          StreamBackend.write(conn, bytes)
          assert {:error, :closed} = conn.transport.recv(conn.socket, 0, 2_000)
        end)

      port = listener(mount(context, connection))
      socket = connect(port)

      :ok =
        :gen_tcp.send(socket, [
          head("/1.0/instances/a%2Fb/#{protocol}?project=allowed&reuse=1", protocol),
          "client-prefetch"
        ])

      {response, initial} = read_head(socket)
      assert response =~ "101 Switching Protocols"
      assert read_bytes(socket, initial, 3) == @initial
      assert_receive :prefetch_once, 2_000
      :ok = :gen_tcp.send(socket, <<255, 0, 1, 2, 3>>)
      assert {:ok, <<255, 0, 1, 2, 3>>} = :gen_tcp.recv(socket, 5, 2_000)
      :gen_tcp.close(socket)
      assert_receive {:backend_request, request}, 2_000
      assert request.target == "/1.0/instances/a%2Fb/#{protocol}?project=allowed&reuse=1"
      refute List.keymember?(request.headers, "authorization", 0)
      assert StreamBackend.accepted(backend) == 1
      assert_receive {:backend_closed, _}, 3_000
      await_empty(context.admission)
    end
  end

  test "ordinary requests stay on the same listener and direct Plug raw mounts fail explicitly",
       context do
    {backend, connection} = backend(context, reply(200, %{metadata: "native"}))
    gateway = mount(context, connection)
    port = listener(gateway)
    assert RawHTTP.request(port, "GET", "/runtime").body == "host-runtime"
    assert RawHTTP.request(port, "GET", "/1.0/instances", [auth()]).status == 200

    assert get(context, "/1.0/instances/a/sftp", [
             auth(),
             {"upgrade", "sftp"},
             {"connection", "upgrade"}
           ]).status == 501

    assert StreamBackend.accepted(backend) == 1
  end

  test "foreign host upgrade routes retain protocol and handler ownership", context do
    {backend, connection} = backend(context, fn _ -> flunk("foreign upgrade touched backend") end)
    gateway = mount(context, connection)
    port = listener(gateway, nil, {Opsmaru.TestSupport.RawForeignHandler, :host_state})

    for protocol <- ["custom", "h2c", "sftp"] do
      response =
        RawHTTP.request(port, "GET", "/custom", [{"connection", "upgrade"}, {"upgrade", protocol}])

      assert response.status == 200
      assert response.body == "host-" <> protocol
    end

    assert StreamBackend.accepted(backend) == 0
    refute_receive {:host_authorize, _}
  end

  test "fallback WebSocket protocol receives its original Cowboy handler identity", context do
    {backend, connection} = backend(context, fn _ -> flunk("host WebSocket touched backend") end)
    socket = connect(listener(mount(context, connection)))

    :gen_tcp.send(
      socket,
      RawHTTP.head("GET", "/echo", [
        {"connection", "upgrade"},
        {"upgrade", "websocket"},
        {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="},
        {"sec-websocket-version", "13"}
      ])
    )

    {response, ""} = read_head(socket)
    assert response =~ "101"
    # Masked RFC6455 text "hi"; host echo comes back unmasked.
    :gen_tcp.send(socket, <<129, 130, 1, 2, 3, 4, 105, 107>>)
    assert {:ok, <<129, 2, 104, 105>>} = :gen_tcp.recv(socket, 4, 2_000)
    :gen_tcp.close(socket)
    assert StreamBackend.accepted(backend) == 0
  end

  test "authorization, readiness and canonical protocol validation deny without backend access",
       context do
    {backend, connection} = backend(context, fn _ -> flunk("denied request reached backend") end)
    port = listener(mount(context, connection))

    cases = [
      {"/1.0/instances/a/sftp", "sftp", [], "GET", "HTTP/1.1", "upgrade", ""},
      {"/1.0/instances/a/sftp?project=forbidden", "sftp", [auth()], "GET", "HTTP/1.1", "upgrade",
       ""},
      {"/1.0/instances/a/nbd", "sftp", [auth()], "GET", "HTTP/1.1", "upgrade", ""},
      {"/1.0/not-a-raw-route", "sftp", [auth()], "GET", "HTTP/1.1", "upgrade", ""},
      {"/1.0/instances/a/sftp", "sftp", [auth()], "POST", "HTTP/1.1", "upgrade", ""},
      {"/1.0/instances/a/sftp", "sftp", [auth()], "GET", "HTTP/1.0", "upgrade", ""},
      {"/1.0/instances/a/sftp", "sftp", [auth()], "GET", "HTTP/1.1", "upgrade,,", ""},
      {"/1.0/instances/a/sftp", "sftp,nbd", [auth()], "GET", "HTTP/1.1", "upgrade", ""},
      {"/1.0/instances/a/sftp", "sftp", [auth()], "GET", "HTTP/1.1", "upgrade",
       "Content-Length: 1\r\n"}
    ]

    for {path, protocol, auth, method, version, connection_header, extra} <- cases do
      socket = connect(port)

      :ok =
        :gen_tcp.send(socket, [
          method,
          " ",
          path,
          " ",
          version,
          "\r\nHost: localhost\r\nUpgrade: ",
          protocol,
          "\r\nConnection: ",
          connection_header,
          ",close\r\n",
          Enum.map(auth, fn {k, v} -> [k, ": ", v, "\r\n"] end),
          extra,
          "\r\n"
        ])

      {response, _} = read_head(socket)
      refute response =~ "101"
      :gen_tcp.close(socket)
    end

    assert StreamBackend.accepted(backend) == 0
    port = listener(mount(context, connection, host_config: %{ready: false}))
    socket = connect(port)
    :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
    {response, _} = read_head(socket)
    assert response =~ "503"
    :gen_tcp.close(socket)
    assert StreamBackend.accepted(backend) == 0
  end

  test "native rejection and malformed upgrade do not switch or retry", context do
    for {response, expected} <- [
          {StreamBackend.json(
             403,
             %{
               type: "error",
               error_code: 403,
               error: "native-denied",
               operation: "/1.0/operations/native"
             },
             [{"x-incus-fixture", "first"}, {"x-incus-fixture", "second"}]
           ), 403},
          {"HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: nbd\r\n\r\n",
           502},
          {"HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: sftp\r\nContent-Length: 0\r\n\r\n",
           502}
        ] do
      {backend, connection} = backend(context, fn conn -> StreamBackend.write(conn, response) end)
      port = listener(mount(context, connection))

      result =
        RawHTTP.request(port, "GET", "/1.0/instances/a/sftp", [
          auth(),
          {"upgrade", "sftp"},
          {"connection", "upgrade"}
        ])

      assert result.status == expected

      if result.status == 403 do
        assert Jason.decode!(result.body)["error"] == "native-denied"
        assert Jason.decode!(result.body)["operation"] == "/1.0/operations/native"

        assert List.keyfind(result.headers, "x-incus-fixture", 0) ==
                 {"x-incus-fixture", "first, second"}
      end

      assert StreamBackend.accepted(backend) == 1
      await_empty(context.admission)
    end
  end

  test "native chunked rejection retains original headers and validates trailers", context do
    body =
      Jason.encode!(%{
        type: "error",
        error_code: 403,
        error: "native-chunked",
        operation: "/1.0/operations/rejected"
      })

    for trailer <- ["X-Safe: yes", "Connection: bad"] do
      {backend, connection} =
        backend(context, fn conn ->
          StreamBackend.write(conn, [
            "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nETag: \"native-etag\"\r\nLocation: /1.0/operations/rejected\r\nTransfer-Encoding: chunked\r\nTrailer: X-Safe\r\n\r\n",
            Integer.to_string(byte_size(body), 16),
            "\r\n",
            body,
            "\r\n0\r\n",
            trailer,
            "\r\n\r\n"
          ])
        end)

      result =
        RawHTTP.request(listener(mount(context, connection)), "GET", "/1.0/instances/a/sftp", [
          auth(),
          {"connection", "upgrade"},
          {"upgrade", "sftp"}
        ])

      if trailer == "X-Safe: yes" do
        assert result.status == 403
        assert result.body == body
        assert List.keyfind(result.headers, "etag", 0) == {"etag", "\"native-etag\""}

        assert List.keyfind(result.headers, "location", 0) ==
                 {"location", "/1.0/operations/rejected"}

        assert List.keyfind(result.headers, "content-type", 0) ==
                 {"content-type", "application/json"}
      else
        assert result.status == 502
      end

      assert StreamBackend.accepted(backend) == 1
      await_empty(context.admission)
    end
  end

  test "Unix backend half-close preserves caller writes until finite drain", context do
    parent = self()

    {_, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, upgrade("sftp", @initial))
        :ok = conn.transport.shutdown(conn.socket, :write)

        case conn.transport.recv(conn.socket, 4, 2_000) do
          {:ok, bytes} -> send(parent, {:after_eof, bytes})
          error -> send(parent, error)
        end
      end)

    socket = connect(listener(mount(context, connection)))
    :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
    {_, initial} = read_head(socket)
    assert read_bytes(socket, initial, 3) == @initial
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
    assert :ok = :gen_tcp.send(socket, <<255, 0, 1, 2>>)
    assert_receive {:after_eof, <<255, 0, 1, 2>>}, 2_000
    :gen_tcp.close(socket)
    await_empty(context.admission)
  end

  test "silent timeout and byte overflow release only their own exchange", context do
    parent = self()

    {_, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, upgrade("sftp", ""))
        send(parent, :ready)
        conn.transport.recv(conn.socket, 0, 3_000)
      end)

    gateway = mount(context, connection, idle_timeout: 200, max_request_bytes: 3)
    port = listener(gateway)
    socket = connect(port)
    :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
    assert {response, ""} = read_head(socket)
    assert response =~ "101"
    assert_receive :ready
    :gen_tcp.send(socket, "four")
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
    await_empty(context.admission)
    socket = connect(port)
    :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
    read_head(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
    await_empty(context.admission)
    assert RawHTTP.request(port, "GET", "/runtime").body == "host-runtime"
  end

  test "revocation and admission loss interrupt silent raw access without another backend",
       context do
    for reason <- [:revoked, :admission] do
      valid = :atomics.new(1, [])
      :atomics.put(valid, 1, 1)

      {backend, connection} =
        backend(context, fn conn ->
          StreamBackend.write(conn, upgrade("sftp", ""))
          conn.transport.recv(conn.socket, 0, 5_000)
        end)

      admission = start_supervised!({Admission, max_exchanges: 2}, id: make_ref())

      gateway =
        mount(%{context | admission: admission}, connection,
          recheck_interval: 500,
          host_config: %{valid: fn _, _ -> :atomics.get(valid, 1) == 1 end}
        )

      socket = connect(listener(gateway))
      :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
      {response, _} = read_head(socket)
      assert response =~ "101"
      started = System.monotonic_time(:millisecond)
      if reason == :revoked, do: :atomics.put(valid, 1, 0), else: Process.exit(admission, :kill)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      assert System.monotonic_time(:millisecond) - started < 1_500
      assert_receive {:backend_closed, _}, 2_000
      assert StreamBackend.accepted(backend) == 1
      :gen_tcp.close(socket)
      if reason == :revoked, do: await_empty(admission)
    end
  end

  test "lifetime expiring during policy is not_sent with zero backend access", context do
    {backend, connection} = backend(context, fn _ -> flunk("expired policy reached backend") end)

    gateway =
      mount(context, connection,
        max_lifetime: 500,
        callback_timeout: 1_500,
        host_config: %{
          ready: fn ->
            Process.sleep(1_000)
            true
          end
        }
      )

    result =
      RawHTTP.request(listener(gateway), "GET", "/1.0/instances/a/sftp", [
        auth(),
        {"connection", "upgrade"},
        {"upgrade", "sftp"}
      ])

    assert result.status == 504
    assert native(result.body)["metadata"]["gateway"]["outcome"] == "not_sent"
    assert StreamBackend.accepted(backend) == 0
    await_empty(context.admission)
  end

  test "lifetime covers silent negotiation", context do
    {backend, connection} =
      backend(context, fn conn ->
        conn.transport.recv(conn.socket, 0, 5_000)
      end)

    gateway = mount(context, connection, max_lifetime: 500, idle_timeout: 5_000)

    result =
      RawHTTP.request(listener(gateway), "GET", "/1.0/instances/a/sftp", [
        auth(),
        {"connection", "upgrade"},
        {"upgrade", "sftp"}
      ])

    assert result.status == 504
    assert StreamBackend.accepted(backend) == 1
    assert_receive {:backend_closed, _}, 2_000
    await_empty(context.admission)
  end

  test "revocation after backend101 preserves the sent negotiation outcome", context do
    checks = :atomics.new(1, [])

    {backend, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, upgrade("sftp", ""))
        conn.transport.recv(conn.socket, 0, 3_000)
      end)

    gateway =
      mount(context, connection,
        recheck_interval: 1_000,
        host_config: %{valid: fn _, _ -> :atomics.add_get(checks, 1, 1) == 1 end}
      )

    result =
      RawHTTP.request(listener(gateway), "GET", "/1.0/instances/a/sftp", [
        auth(),
        {"connection", "upgrade"},
        {"upgrade", "sftp"}
      ])

    assert result.status == 403
    assert native(result.body)["metadata"]["gateway"]["outcome"] == "sent"
    assert StreamBackend.accepted(backend) == 1
    assert_receive {:backend_closed, _}, 2_000
    await_empty(context.admission)
  end

  test "caller loss during negotiation closes its backend and releases admission", context do
    parent = self()

    {backend, connection} =
      backend(context, fn conn ->
        send(parent, :negotiating)
        conn.transport.recv(conn.socket, 0, 5_000)
      end)

    gateway = mount(context, connection)
    socket = connect(listener(gateway))
    :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
    assert_receive :negotiating, 2_000
    :gen_tcp.close(socket)
    assert_receive {:backend_closed, _}, 2_000
    await_empty(context.admission)
    assert StreamBackend.accepted(backend) == 1
  end

  test "repeated upgrade handoffs survive immediate HTTP worker exit", context do
    {backend, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, upgrade("nbd", "hello"))
        {:ok, bytes} = conn.transport.recv(conn.socket, 3, 2_000)
        StreamBackend.write(conn, bytes)
      end)

    port = listener(mount(context, connection))

    for _ <- 1..30 do
      socket = connect(port)
      :gen_tcp.send(socket, head("/1.0/instances/a/nbd", "nbd"))
      {response, bytes} = read_head(socket)
      assert response =~ "101"
      assert read_bytes(socket, bytes, 5) == "hello"
      :gen_tcp.send(socket, "end")
      assert {:ok, "end"} = :gen_tcp.recv(socket, 3, 2_000)
      :gen_tcp.close(socket)
    end

    await_empty(context.admission)
    assert StreamBackend.accepted(backend) == 30
  end

  test "verified HTTPS backend preserves bytes and rejects wrong server or client trust",
       context do
    server = TLSIdentity.generate(context.root, "raw-backend", "localhost")
    client = TLSIdentity.generate(context.root, "raw-backend-client", "gateway")
    wrong = TLSIdentity.generate(context.root, "raw-wrong", "wrong")
    parent = self()

    backend =
      start_supervised!(
        {StreamBackend,
         tls: server,
         client_ca: client.cafile,
         observer: parent,
         script: fn conn ->
           StreamBackend.write(conn, upgrade("sftp", @initial))
           {:ok, data} = conn.transport.recv(conn.socket, 3, 2_000)
           StreamBackend.write(conn, data)
         end},
        id: make_ref()
      )

    for {server_ca, identity, success} <- [
          {server.cafile, client, true},
          {wrong.cafile, client, false},
          {server.cafile, wrong, false}
        ] do
      connection =
        Connection.https!("https://localhost:#{StreamBackend.port(backend)}",
          owner: :fixture,
          tls: [cacertfile: server_ca, certfile: identity.certfile, keyfile: identity.keyfile]
        )

      socket = connect(listener(mount(context, connection)))
      :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
      {response, initial} = read_head(socket)

      if success do
        assert response =~ "101"
        assert read_bytes(socket, initial, 3) == @initial
        :gen_tcp.send(socket, "tls")
        assert {:ok, "tls"} = :gen_tcp.recv(socket, 3, 2_000)
      else
        assert response =~ "502"
      end

      :gen_tcp.close(socket)
      await_empty(context.admission)
    end

    assert StreamBackend.accepted(backend) == 1
  end

  test "tighter response header and byte budgets reject before switching", context do
    for {reply, limits} <- [
          {[
             "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: sftp\r\nX-Huge: ",
             String.duplicate("x", 1200),
             "\r\n\r\n"
           ], [max_header_bytes: 1024]},
          {upgrade("sftp", "1234"), [max_response_bytes: 3]}
        ] do
      {backend, connection} = backend(context, fn conn -> StreamBackend.write(conn, reply) end)

      result =
        RawHTTP.request(
          listener(mount(context, connection, limits)),
          "GET",
          "/1.0/instances/a/sftp",
          [auth(), {"connection", "upgrade"}, {"upgrade", "sftp"}]
        )

      assert result.status == 502
      assert StreamBackend.accepted(backend) == 1
      await_empty(context.admission)
    end
  end

  for protocol <- ["sftp", "nbd", "volume_sftp", "volume_nbd"] do
    test "unchanged pinned official #{protocol} helper negotiates and exchanges native bytes",
         context do
      protocol = unquote(protocol)
      raw_protocol = if String.ends_with?(protocol, "sftp"), do: "sftp", else: "nbd"

      {backend, connection} =
        backend(context, fn conn ->
          if URI.parse(conn.head.target).path == "/1.0" do
            StreamBackend.write(
              conn,
              StreamBackend.json(200, %{
                type: "sync",
                status: "Success",
                status_code: 200,
                metadata: %{
                  api_version: "1.0",
                  api_status: "stable",
                  auth: "trusted",
                  public: false,
                  api_extensions: ["instance_nbd", "custom_volume_sftp", "storage_volume_nbd"],
                  environment: %{}
                }
              })
            )
          else
            StreamBackend.write(conn, upgrade(raw_protocol, ""))
            # Approved oracle exception: pinned rawConn drops bytes prefetched by
            # net/http. Separate delivery only for the unchanged official client.
            Process.sleep(150)
            StreamBackend.write(conn, @initial)
            {:ok, bytes} = conn.transport.recv(conn.socket, 5, 3_000)
            StreamBackend.write(conn, bytes)
          end
        end)

      server = TLSIdentity.generate(context.root, "raw-public-#{protocol}", "localhost")
      client = TLSIdentity.generate(context.root, "raw-client-#{protocol}", "raw-client")

      host_config = %{
        authorize: fn req ->
          if req.peer.certificate == client.der, do: {:ok, :grant}, else: {:error, :forbidden}
        end
      }

      gateway = mount(context, connection, host_config: host_config)

      gateway =
        put_in(gateway.host_config.identity.api_extensions, [
          "certificate_update",
          "instance_nbd",
          "custom_volume_sftp",
          "storage_volume_nbd"
        ])

      port = listener(gateway, {server, client})

      input = %{
        url: "https://localhost:#{port}",
        server_cert: File.read!(server.certfile),
        client_cert: File.read!(client.certfile),
        client_key: File.read!(client.keyfile),
        protocol: protocol,
        pool: "pool",
        volume_type: "custom",
        name: "v",
        project: "allowed",
        reuse: true,
        writable: true,
        read_initial: 3,
        payload: Base.encode64(<<255, 0, 1, 2, 3>>)
      }

      path = Path.join(context.root, "#{protocol}.json")
      File.write!(path, Jason.encode!(input))
      {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
      assert status == 0, output
      result = Jason.decode!(output)
      assert Base.decode64!(result["initial"]) == @initial
      assert Base.decode64!(result["echo"]) == <<255, 0, 1, 2, 3>>
      assert StreamBackend.accepted(backend) == 2
      assert_receive {:backend_request, %{target: "/1.0"}}, 2_000
      assert_receive {:backend_request, req}, 2_000

      assert req.target =~
               if(String.starts_with?(protocol, "volume"),
                 do: "/1.0/storage-pools/pool/volumes/custom/v/",
                 else: "/1.0/instances/fixture/"
               )
    end
  end

  test "revocation interrupts a blocked write in either direction", context do
    for direction <- [:upload, :download] do
      valid = :atomics.new(1, [])
      :atomics.put(valid, 1, 1)
      parent = self()

      {backend, connection} =
        backend(context, fn conn ->
          StreamBackend.write(conn, upgrade("sftp", ""))
          send(parent, {:blocked_peer, self()})

          if direction == :download do
            conn.transport.send(conn.socket, :binary.copy(<<0>>, 16_777_216))
          else
            receive do
              :finish -> :ok
            after
              5_000 -> :ok
            end
          end
        end)

      gateway =
        mount(context, connection,
          recheck_interval: 500,
          idle_timeout: 5_000,
          host_config: %{valid: fn _, _ -> :atomics.get(valid, 1) == 1 end}
        )

      socket = connect(listener(gateway))
      :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
      read_head(socket)
      assert_receive {:blocked_peer, peer}, 2_000

      writer =
        if direction == :upload do
          :inet.setopts(socket, send_timeout: 2_000, send_timeout_close: true)
          Task.async(fn -> :gen_tcp.send(socket, :binary.copy(<<1>>, 16_777_216)) end)
        end

      Process.sleep(100)
      started = System.monotonic_time(:millisecond)
      :atomics.put(valid, 1, 0)
      await_empty(context.admission)
      assert System.monotonic_time(:millisecond) - started < 1_500
      :gen_tcp.close(socket)
      if writer, do: Task.await(writer, 3_000)
      send(peer, :finish)
      assert_receive {:backend_closed, _}, 2_000
      assert StreamBackend.accepted(backend) == 1
    end
  end

  test "busy raw traffic cannot refresh the absolute lifetime", context do
    {backend, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, upgrade("nbd", ""))
        repeat_bytes(conn)
      end)

    gateway = mount(context, connection, max_lifetime: 500, idle_timeout: 5_000)
    socket = connect(listener(gateway))
    :gen_tcp.send(socket, head("/1.0/instances/a/nbd", "nbd"))
    read_head(socket)
    started = System.monotonic_time(:millisecond)
    assert drain_until_close(socket, 0) > 0
    assert System.monotonic_time(:millisecond) - started < 1_500
    await_empty(context.admission)
    assert StreamBackend.accepted(backend) == 1
  end

  defp repeat_bytes(conn) do
    case conn.transport.send(conn.socket, <<0, 255>>) do
      :ok ->
        Process.sleep(10)
        repeat_bytes(conn)

      _ ->
        :ok
    end
  end

  defp drain_until_close(socket, count) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, bytes} -> drain_until_close(socket, count + byte_size(bytes))
      {:error, :closed} -> count
    end
  end

  def dying_resolver, do: exit(:private_fixture_config)
  def throwing_resolver, do: throw(:private_fixture_config)

  test "caller authenticated assertion cannot replace host backend connection identity",
       context do
    for authenticated <- [false, true] do
      {_, connection} =
        backend(context, fn conn -> StreamBackend.write(conn, upgrade("sftp", "")) end,
          require_authenticated: authenticated
        )

      socket = connect(listener(mount(context, connection)))

      :gen_tcp.send(
        socket,
        RawHTTP.head("GET", "/1.0/instances/a/sftp", [
          auth(),
          {"connection", "upgrade"},
          {"upgrade", "sftp"},
          {"x-incus-authenticated", "caller-spoof"}
        ])
      )

      read_head(socket)
      assert_receive {:backend_request, req}, 2_000

      assert for({"x-incus-authenticated", value} <- req.headers, do: value) ==
               if(authenticated, do: ["true"], else: [])

      :gen_tcp.close(socket)
      await_empty(context.admission)
    end
  end

  test "unchanged pinned pkg/sftp clients exchange binary file packets through instance and volume upgrades",
       context do
    parent = self()

    for kind <- ["instance", "volume"] do
      {backend, connection} =
        backend(context, fn conn ->
          if URI.parse(conn.head.target).path == "/1.0" do
            StreamBackend.write(conn, discovery())
          else
            StreamBackend.write(conn, upgrade("sftp", ""))
            assert read_packet(conn) == <<1, 3::32>>
            send_packet(conn, <<2, 3::32>>)
            sftp_packets(conn, parent)
          end
        end)

      server = TLSIdentity.generate(context.root, "sftp-public-#{kind}", "localhost")
      client = TLSIdentity.generate(context.root, "sftp-client-#{kind}", "client")

      gateway =
        mount(context, connection,
          host_config: %{
            authorize: fn req ->
              if(req.peer.certificate == client.der,
                do: {:ok, :grant},
                else: {:error, :forbidden}
              )
            end
          }
        )

      gateway = put_in(gateway.host_config.identity.api_extensions, ["custom_volume_sftp"])
      port = listener(gateway, {server, client})

      input = %{
        URL: "https://localhost:#{port}",
        CA: File.read!(server.cafile),
        Cert: File.read!(client.certfile),
        Key: File.read!(client.keyfile),
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
      }

      process =
        Port.open({:spawn_executable, String.to_charlist(@sftp_driver)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout
        ])

      Port.command(process, Jason.encode!(input))
      {output, status} = port_result(process, "")
      assert status == 0, output
      result = Jason.decode!(output)
      assert result["accepted"], inspect(result)
      assert result["close_ok"], inspect(result)
      assert Enum.all?(result["steps"], & &1["ok"])
      assert Enum.at(result["steps"], 1)["data"] == Base.encode64(<<0, 255, 128, 13, 10>>)
      assert_receive {:sftp_write, <<255, 0, 128, 13, 10>>}, 2_000
      assert StreamBackend.accepted(backend) == 2
      await_empty(context.admission)
    end
  end

  defp sftp_packets(conn, parent) do
    case read_packet(conn) do
      <<3, id::32, _::binary>> ->
        send_packet(conn, <<102, id::32, 1::32, "h">>)
        sftp_packets(conn, parent)

      <<5, id::32, _::binary>> ->
        send_packet(conn, <<103, id::32, 5::32, 0, 255, 128, 13, 10>>)
        sftp_packets(conn, parent)

      <<6, id::32, 1::32, "h", _offset::64, size::32, data::binary-size(size)>> ->
        send(parent, {:sftp_write, data})
        send_packet(conn, <<101, id::32, 0::32, 0::32, 0::32>>)
        sftp_packets(conn, parent)

      <<4, id::32, _::binary>> ->
        send_packet(conn, <<101, id::32, 0::32, 0::32, 0::32>>)
        conn.transport.recv(conn.socket, 0, 3_000)
    end
  end

  defp read_packet(conn) do
    {:ok, <<size::32>>} = conn.transport.recv(conn.socket, 4, 3_000)
    {:ok, bytes} = conn.transport.recv(conn.socket, size, 3_000)
    bytes
  end

  defp send_packet(conn, bytes),
    do: conn.transport.send(conn.socket, <<byte_size(bytes)::32, bytes::binary>>)

  defp discovery,
    do:
      StreamBackend.json(200, %{
        type: "sync",
        status: "Success",
        status_code: 200,
        metadata: %{
          api_version: "1.0",
          api_status: "stable",
          auth: "trusted",
          public: false,
          api_extensions: ["custom_volume_sftp"],
          environment: %{}
        }
      })

  defp port_result(process, output) do
    receive do
      {^process, {:data, bytes}} -> port_result(process, output <> bytes)
      {^process, {:exit_status, status}} -> {output, status}
    after
      10_000 ->
        Port.close(process)
        flunk("pinned SFTP helper timed out")
    end
  end

  test "missing and dying dynamic configuration fails closed", context do
    {backend, _} = backend(context, fn _ -> flunk("configuration failure reached backend") end)

    for gateway <- [nil, {__MODULE__, :dying_resolver, []}, {__MODULE__, :throwing_resolver, []}] do
      result =
        RawHTTP.request(listener(gateway), "GET", "/1.0/instances/a/sftp", [
          auth(),
          {"connection", "upgrade"},
          {"upgrade", "sftp"}
        ])

      assert result.status == 503
      refute result.body =~ "private_fixture_config"
    end

    assert StreamBackend.accepted(backend) == 0
  end

  test "simultaneous large upload and echo cannot deadlock small Unix buffers", context do
    payload = :binary.copy(<<0, 255, 128, 13, 10>>, 400_000)

    {_, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, upgrade("sftp", ""))
        echo_exact(conn, byte_size(payload))
      end)

    socket = connect(listener(mount(context, connection, idle_timeout: 2_000)))
    :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
    {_, ""} = read_head(socket)
    writer = Task.async(fn -> :gen_tcp.send(socket, payload) end)
    assert recv_exact(socket, byte_size(payload), []) == payload
    assert Task.await(writer, 5_000) == :ok
    :gen_tcp.close(socket)
    await_empty(context.admission)
  end

  test "nonreading backend bounds blocked writer and leaves host requests usable", context do
    parent = self()

    {_, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, upgrade("sftp", ""))
        send(parent, {:blocked_backend, self()})

        receive do
          :finish -> :ok
        after
          3_000 -> :ok
        end
      end)

    gateway = mount(context, connection, idle_timeout: 500)
    port = listener(gateway)
    socket = connect(port)
    :gen_tcp.send(socket, head("/1.0/instances/a/sftp", "sftp"))
    read_head(socket)
    assert_receive {:blocked_backend, backend}, 2_000
    :inet.setopts(socket, send_timeout: 1_000, send_timeout_close: true)
    writer = Task.async(fn -> :gen_tcp.send(socket, :binary.copy(<<0>>, 16_777_216)) end)
    assert RawHTTP.request(port, "GET", "/runtime").body == "host-runtime"
    assert Task.await(writer, 3_000) in [:ok, {:error, :closed}, {:error, :timeout}]
    await_empty(context.admission)
    send(backend, :finish)
    :gen_tcp.close(socket)
  end

  defp echo_exact(_, 0), do: :ok

  defp echo_exact(conn, remaining) do
    {:ok, bytes} = conn.transport.recv(conn.socket, 0, 3_000)
    :ok = conn.transport.send(conn.socket, bytes)
    echo_exact(conn, remaining - byte_size(bytes))
  end

  defp recv_exact(_, 0, chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp recv_exact(socket, remaining, chunks) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 3_000)
    recv_exact(socket, remaining - byte_size(bytes), [bytes | chunks])
  end

  defp listener(gateway, tls \\ nil, fallback \\ nil) do
    ref = {__MODULE__, make_ref()}

    opts = %{
      gateway: gateway,
      fallback: fallback || {Plug.Cowboy.Handler, {RawGatewayRouter, gateway}}
    }

    dispatch = :cowboy_router.compile([{:_, [{:_, CowboyHandler, opts}]}])
    protocol = %{env: %{dispatch: dispatch}, idle_timeout: 10_000}
    socket = [ip: {127, 0, 0, 1}, port: 0]

    {:ok, _} =
      case tls do
        nil ->
          :cowboy.start_clear(ref, %{socket_opts: socket}, protocol)

        {server, client} ->
          :cowboy.start_tls(
            ref,
            %{
              socket_opts:
                socket ++
                  [
                    certfile: String.to_charlist(server.certfile),
                    keyfile: String.to_charlist(server.keyfile),
                    cacertfile: String.to_charlist(client.cafile),
                    verify: :verify_peer,
                    fail_if_no_peer_cert: false,
                    alpn_preferred_protocols: ["http/1.1"]
                  ]
            },
            protocol
          )
      end

    on_exit(fn -> :cowboy.stop_listener(ref) end)
    :ranch.get_port(ref)
  end

  defp head(path, protocol),
    do: RawHTTP.head("GET", path, [auth(), {"connection", "upgrade"}, {"upgrade", protocol}])

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, exit_on_close: false])

    socket
  end

  defp upgrade(protocol, bytes),
    do: [
      "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: ",
      protocol,
      "\r\n\r\n",
      bytes
    ]

  defp read_head(socket, bytes \\ "") do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        {head, body}

      [_] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 3_000)
        read_head(socket, bytes <> chunk)
    end
  end

  defp read_bytes(_, bytes, count) when byte_size(bytes) == count, do: bytes

  defp read_bytes(socket, bytes, count) do
    {:ok, more} = :gen_tcp.recv(socket, count - byte_size(bytes), 2_000)
    bytes <> more
  end

  defp await_empty(admission, attempts \\ 100)

  defp await_empty(admission, attempts) when attempts > 0 do
    case Admission.count(admission) do
      0 ->
        :ok

      _ ->
        Process.sleep(10)
        await_empty(admission, attempts - 1)
    end
  end

  defp await_empty(admission, _), do: assert(Admission.count(admission) == 0)
end
