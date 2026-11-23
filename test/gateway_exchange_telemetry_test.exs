defmodule Opsmaru.Incus.GatewayExchangeTelemetryTest do
  # add-gateway-exchange-telemetry: one start and exactly one stop per gateway
  # exchange, bounded secret-free metadata, and passive emission.
  #
  # Telemetry handlers are global to the VM, so this module runs serially.
  use Opsmaru.TestSupport.GatewayCase, async: false

  @moduletag :capture_log

  alias Opsmaru.Incus.Gateway.{CowboyHandler, Exchange, Failure, Request}
  alias Opsmaru.Incus.{Telemetry, Upgrade}
  alias Opsmaru.TestSupport.WebSocketFixture

  defmodule Router do
    @moduledoc false
    alias Opsmaru.Incus.Gateway.Plug, as: GatewayPlug

    def init(gateway), do: gateway

    def call(%{request_path: "/runtime"} = conn, _),
      do: Plug.Conn.send_resp(conn, 200, "host-runtime")

    def call(conn, gateway), do: GatewayPlug.call(conn, {:static, gateway})
  end

  @start [:opsmaru_incus, :gateway, :exchange, :start]
  @stop [:opsmaru_incus, :gateway, :exchange, :stop]

  @start_keys ~w(telemetry_span_context host protocol method peer_address peer_port peer_fingerprint)a
  @stop_keys @start_keys ++
               ~w(path project target all_projects operation admitted_as status outcome reason)a

  @operation_target "/1.0/operations/native/websocket?project=allowed&secret=private%2Bkey"

  setup do
    attach(fn event, measurements, metadata, test ->
      send(test, {:exchange, event, measurements, metadata})
    end)

    :ok
  end

  describe "exchange observer (1.2)" do
    test "no observer exists while no handler is attached" do
      detach_all()
      exchange = Exchange.start(%{host: nil, protocol: :http, method: "GET", peer: %{}})
      refute Exchange.active?(exchange)
      assert Exchange.finish(exchange, :ended) == exchange
      refute_receive {:exchange, _, _, _}, 100
    end

    test "a normal finish reports exactly one stop with the recorded facts" do
      run(fn exchange ->
        exchange
        |> Exchange.request(request("/1.0/instances", project: "p", target: "n1"))
        |> Exchange.admitted(:caller)
        |> Exchange.status(200)
        |> Exchange.request_bytes(5)
        |> Exchange.response_bytes(40)
        |> Exchange.response_bytes(2)
        |> Exchange.finish(:ended)
      end)

      {start, start_meta} = start!()
      assert Map.keys(start_meta) |> Enum.sort() == Enum.sort(@start_keys)
      assert is_integer(start.system_time) and is_integer(start.monotonic_time)

      {stop, meta} = stop!()
      assert meta.telemetry_span_context == start_meta.telemetry_span_context
      assert stop.duration >= 0
      assert %{request_bytes: 5, response_bytes: 42} = stop

      assert %{
               path: "/1.0/instances",
               project: "p",
               target: "n1",
               all_projects: false,
               operation: nil,
               admitted_as: :caller,
               status: 200,
               outcome: :ok,
               reason: nil
             } = meta

      no_more_stops()
    end

    test "a killed owner reports the sent outcome and :killed, or the recorded reason" do
      for {recorded, expected} <- [{nil, :killed}, {:revoked, :revoked}] do
        pid =
          run(fn exchange ->
            Exchange.sent(exchange, :uncertain)
            if recorded, do: Exchange.interrupt(exchange, recorded)
            Process.sleep(:infinity)
          end)

        start!()
        Process.sleep(20)
        Process.exit(pid, :kill)
        {_, meta} = stop!()
        assert %{outcome: :uncertain, reason: ^expected, status: nil} = meta
        no_more_stops()
      end
    end

    test "the first interruption wins and a Failure keeps the status sent" do
      run(fn exchange ->
        exchange
        |> Exchange.interrupt(:idle)
        |> Exchange.interrupt(:backend)
        |> Exchange.finish(:ended)
      end)

      start!()
      assert {_, %{outcome: :not_sent, reason: :idle}} = stop!()

      failure = Failure.new(502, "x", :sent, reason: :backend)
      run(fn exchange -> exchange |> Exchange.status(200) |> Exchange.finish(failure) end)
      start!()
      assert {_, %{outcome: :sent, reason: :backend, status: 200}} = stop!()

      run(fn exchange -> Exchange.finish(exchange, failure) end)
      start!()
      assert {_, %{status: 502}} = stop!()
    end

    test "a finish racing a kill and a transfer followed by a kill each report once" do
      parent = self()

      for _ <- 1..20 do
        run(fn exchange ->
          send(parent, {:running, self()})
          Exchange.finish(exchange, :ended)
          Process.sleep(:infinity)
        end)

        assert_receive {:running, pid}
        Process.exit(pid, :kill)
        start!()
        stop!()
        no_more_stops(20)
      end

      next = spawn(fn -> Process.sleep(:infinity) end)

      run(fn exchange ->
        Exchange.transfer(exchange, next)
        send(parent, :transferred)
      end)

      start!()
      assert_receive :transferred
      # The first owner has exited; the new owner still holds the exchange.
      refute_receive {:exchange, @stop, _, _}, 100
      Process.exit(next, :kill)
      assert {_, %{reason: :killed}} = stop!()
      no_more_stops()
    end

    test "a handler attached mid-exchange produces no unpaired stop" do
      detach_all()
      parent = self()

      pid =
        spawn(fn ->
          exchange = Exchange.start(%{host: nil, protocol: :http, method: "GET", peer: %{}})
          send(parent, :started)
          receive do: (:finish -> Exchange.finish(exchange, :ended))
        end)

      assert_receive :started
      attach(fn event, _, _, test -> send(test, {:exchange, event, %{}, %{}}) end)
      send(pid, :finish)
      refute_receive {:exchange, _, _, _}, 200
    end

    test "the peer fingerprint is the SHA-256 of the presented certificate and methods are bounded" do
      der = :crypto.strong_rand_bytes(64)
      expected = :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)
      peer = %{address: {127, 0, 0, 1}, port: 1, certificate: der}

      run(fn e -> Exchange.finish(e, :ended) end, %{method: "BREW", peer: peer})
      assert {_, %{peer_fingerprint: ^expected, method: nil, peer_port: 1}} = start!()
      stop!()

      run(fn e -> Exchange.finish(e, :ended) end)
      assert {_, %{peer_fingerprint: nil, method: "GET"}} = start!()
      stop!()
    end
  end

  describe "Failure reasons (1.3)" do
    test "a reason outside the closed set is refused and encoding is unchanged" do
      assert_raise ArgumentError, fn -> Failure.new(500, "x", :not_sent, reason: :other) end
      assert_raise KeyError, fn -> Failure.new(500, "x", :not_sent, []) end

      failure =
        Failure.new(502, "Backend failed", :uncertain,
          reason: :backend,
          operation: "/1.0/operations/a"
        )

      {502, [{"content-type", "application/json"}], body} = Failure.encode(failure)

      assert Jason.decode!(body) == %{
               "type" => "error",
               "status" => "",
               "status_code" => 0,
               "operation" => "",
               "error_code" => 502,
               "error" => "Backend failed",
               "metadata" => %{
                 "gateway" => %{"outcome" => "uncertain", "operation" => "/1.0/operations/a"}
               }
             }
    end

    test "every reason is documented and the catalogue has only start and stop" do
      docs = File.read!("docs/gateway.md")
      for reason <- Failure.reasons(), do: assert(docs =~ "`#{inspect(reason)}`")

      emitted =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file ->
          Regex.scan(~r/Telemetry\.execute\(\s*([^,\s]+),/, File.read!(file),
            capture: :all_but_first
          )
        end)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.sort()

      assert emitted == ["@start", "@stop"]
      assert docs =~ "[:opsmaru_incus, :gateway, :exchange, :start]"
      assert docs =~ "[:opsmaru_incus, :gateway, :exchange, :stop]"
    end
  end

  describe "native HTTP (2.1)" do
    test "a relayed read reports the native status, admission and response bytes", context do
      body = %{"type" => "sync", "metadata" => ["a"]}
      {_, connection} = backend(context, reply(200, body))
      gateway = mount(context, connection)

      response = get(context, "/1.0/instances?project=allowed&recursion=1")
      assert response.status == 200

      {_, start} = start!()
      assert %{protocol: :http, method: "GET", peer_address: {127, 0, 0, 1}} = start
      assert start.host == gateway.host

      {stop, meta} = stop!()

      assert %{
               path: "/1.0/instances",
               project: "allowed",
               admitted_as: :caller,
               status: 200,
               outcome: :ok,
               reason: nil
             } = meta

      assert stop.response_bytes == byte_size(response.body)
      assert stop.request_bytes == 0
    end

    test "a relayed mutation counts request bytes and a native error stays :ok", context do
      {_, connection} = backend(context, reply(404, %{"error" => "not found"}))
      mount(context, connection)
      payload = ~s({"name":"c1"})

      assert RawHTTP.request(context.port, "POST", "/1.0/instances", [auth()], payload).status ==
               404

      {stop, meta} = stop!()
      assert %{method: "POST", status: 404, outcome: :ok, reason: nil} = meta
      assert stop.request_bytes == byte_size(payload)
    end

    test "pre-admission refusals report their status, reason and no backend", context do
      {backend, connection} = backend(context, reply(200, %{}))

      cases = [
        {"unauthorized", %{}, "/1.0/instances?project=other", [auth()], 403, :unauthorized},
        {"invalid path", %{}, "/1.0/instances/../certificates", [auth()], 400, :invalid_request},
        {"invalid selection", %{}, "/1.0/instances?project=a&project=b", [auth()], 400,
         :invalid_request},
        {"not ready", %{ready: false}, "/1.0/instances", [auth()], 503, :not_ready},
        {"raw on the Plug", %{}, "/1.0/instances/a/sftp",
         [auth(), {"upgrade", "sftp"}, {"connection", "upgrade"}], 501, :unsupported}
      ]

      for {label, host_config, target, headers, status, reason} <- cases do
        mount(context, connection, host_config: host_config)
        assert get(context, target, headers).status == status, label
        {stop, meta} = stop!()
        assert %{status: ^status, outcome: :not_sent, reason: ^reason} = meta, label
        # Only the raw upgrade passes policy before its adapter is refused.
        assert meta.admitted_as == if(reason == :unsupported, do: :caller), label
        assert stop.response_bytes > 0, label
      end

      gateway = mount(context, connection)
      get(context, "/1.0/instances/../certificates", [auth()])
      assert {_, %{path: nil, project: nil}} = stop!()

      # Cowboy joins repeated headers, so ambiguous authorization is driven directly.
      conn = Plug.Test.conn(:get, "/1.0/instances")
      conn = %{conn | req_headers: [auth(), auth() | conn.req_headers]}
      assert Router.call(conn, gateway).status == 400
      assert {_, %{status: 400, reason: :invalid_request, outcome: :not_sent}} = stop!()
      assert StreamBackend.accepted(backend) == 0
    end

    test "an unresolved gateway, capacity and a parsed body are refused", context do
      assert get(context, "/1.0/instances").status == 503
      assert {_, %{host: nil, reason: :not_configured, status: 503}} = stop!()

      {_, connection} = backend(context, reply(200, %{}))
      admission = start_supervised!({Admission, max_exchanges: 1}, id: make_ref())
      mount(%{context | admission: admission}, connection)
      {:ok, _slot} = Admission.acquire(admission, self())
      assert get(context, "/1.0/instances").status == 503
      assert {_, %{reason: :capacity, outcome: :not_sent}} = stop!()

      mount(context, connection)

      response =
        RawHTTP.request(
          context.port,
          "POST",
          "/parsed",
          [auth(), {"content-type", "application/json"}],
          "{}"
        )

      assert response.status == 500
      assert {_, %{reason: :not_configured}} = stop!()
    end

    test "anonymous discovery reports :anonymous", context do
      {_, connection} = backend(context, reply(200, %{}))
      mount(context, connection)
      assert get(context, "/", []).status == 200
      assert {_, %{admitted_as: :anonymous, status: 200, outcome: :ok, path: "/"}} = stop!()
    end

    test "a trust action answered by the host reports its status and body bytes", context do
      {backend, connection} = backend(context, reply(200, %{}))

      mount(context, connection,
        host_config: %{certificates: fn _, _, _, _ -> {:ok, %{}, []} end}
      )

      response = RawHTTP.request(context.port, "POST", "/1.0/certificates", [auth()], "{}")
      assert response.status in 200..299
      status = response.status
      {stop, meta} = stop!()

      assert %{
               path: "/1.0/certificates",
               admitted_as: :caller,
               status: ^status,
               outcome: :ok,
               reason: nil
             } = meta

      assert stop.request_bytes == 2
      assert stop.response_bytes == byte_size(response.body)
      assert StreamBackend.accepted(backend) == 0
    end

    test "an interrupted mutation reports :uncertain", context do
      {backend, connection} =
        backend(context, fn conn -> {_conn, _, _} = StreamBackend.read_body(conn) end)

      mount(context, connection)
      response = RawHTTP.request(context.port, "POST", "/1.0/instances", [auth()], "{}")
      assert response.status == 502
      assert {_, %{outcome: :uncertain, reason: :backend, status: 502}} = stop!()
      assert StreamBackend.accepted(backend) == 1
    end

    test "a response aborted after its head reports the head status", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)

          StreamBackend.write(
            conn,
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n4\r\npart\r\n"
          )
        end)

      mount(context, connection)
      get(context, "/1.0/events")
      {stop, meta} = stop!()
      assert %{status: 200, outcome: :sent, reason: :backend} = meta
      assert stop.response_bytes == 4
    end

    test "a caller disconnect mid-download reports one stop", context do
      {_, connection} =
        backend(context, fn conn ->
          {conn, _, _} = StreamBackend.read_body(conn)
          StreamBackend.write(conn, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
          StreamBackend.await_close(conn)
        end)

      mount(context, connection)
      {:gen_tcp, socket} = client = RawHTTP.connect(context.port)
      RawHTTP.send!(client, RawHTTP.head("GET", "/1.0/events", [auth()]))
      {:ok, _} = :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.close(socket)

      {_, meta} = stop!(3_000)
      assert %{status: 200, outcome: :sent} = meta
      assert meta.reason in [:killed, :caller_closed]
      no_more_stops()
    end
  end

  describe "WebSocket (2.2)" do
    test "a normal close reports 101, payload bytes and the operation", context do
      fixture = ws_backend(context, wire: WebSocketFixture.frame(1, "hello"))
      mount_ws(context, fixture)
      channel = open(context)
      assert {:text, "hello"} = recv_frame(channel)
      channel = send_frame(channel, {:text, "abc"})
      assert {:text, "abc"} = recv_frame(channel)
      channel = send_frame(channel, {:close, 1000, ""})
      recv_frame(channel)
      close(channel)

      {_, start} = start!()
      assert start.protocol == :websocket

      {stop, meta} = stop!(5_000)

      assert %{
               path: "/1.0/operations/native/websocket",
               operation: "native",
               project: "allowed",
               admitted_as: :caller,
               status: 101,
               outcome: :ok,
               reason: nil
             } = meta

      assert stop.request_bytes == 3
      assert stop.response_bytes == 8
      no_more_stops()
    end

    test "a backend close is :ok and a caller dropping its socket is :caller_closed", context do
      wire = WebSocketFixture.frame(1, "tail") <> WebSocketFixture.frame(8, <<1001::16, "bye">>)
      fixture = ws_backend(context, wire: wire)
      mount_ws(context, fixture)
      channel = open(context)
      assert {:text, "tail"} = recv_frame(channel)
      assert {:close, 1001, "bye"} = recv_frame(channel)
      assert {stop, %{outcome: :ok, reason: nil, status: 101}} = stop!(3_000)
      assert stop.response_bytes == 4
      close(channel)
      no_more_stops()

      fixture = ws_backend(context, wire: "")
      mount_ws(context, fixture)
      channel = open(context)
      close(channel)
      assert {_, %{outcome: :sent, reason: :caller_closed}} = stop!(3_000)
      no_more_stops()
    end

    test "a failed upgrade finishes in the Plug process", context do
      fixture = ws_backend(context, wire: "")
      mount_ws(context, fixture)
      assert {:error, 403, _, _} = negotiate(context, "/1.0/events?project=other", [auth()])
      assert {_, %{status: 403, reason: :unauthorized, outcome: :not_sent}} = stop!()

      assert {:error, 400, _, _} = negotiate(context, "/1.0/instances", [auth()])
      assert {_, %{status: 400, reason: :invalid_request}} = stop!()
      no_more_stops()
    end

    test "revocation reports :revoked with the bytes moved before it", context do
      flag = :atomics.new(1, [])
      :atomics.put(flag, 1, 1)
      fixture = ws_backend(context, wire: WebSocketFixture.frame(1, "hi"), notify: self())

      mount_ws(context, fixture,
        recheck_interval: 100,
        host_config: %{valid: fn _, _ -> :atomics.get(flag, 1) == 1 end}
      )

      channel = open(context)
      assert {:text, "hi"} = recv_frame(channel)
      :atomics.put(flag, 1, 0)
      {stop, meta} = stop!(3_000)
      assert %{reason: :revoked, outcome: :sent, status: 101} = meta
      assert stop.response_bytes == 2
      assert stop.duration > 0
      no_more_stops()
      close(channel)
    end

    test "idle and lifetime expiry report their deadline", context do
      for {limits, reason} <- [
            {[idle_timeout: 150], :idle},
            {[idle_timeout: 5_000, max_lifetime: 150], :lifetime}
          ] do
        fixture = ws_backend(context, wire: "", notify: self())
        mount_ws(context, fixture, limits)
        channel = open(context)
        recv_frame(channel)
        assert {_, %{reason: ^reason, status: 101}} = stop!(3_000)
        no_more_stops()
        close(channel)
      end
    end

    test "a backend loss reports :backend and an admission stop reports :admission",
         context do
      drop = fn t, socket ->
        spawn(fn ->
          Process.sleep(100)
          t.close(socket)
        end)
      end

      fixture = ws_backend(context, wire: WebSocketFixture.frame(1, "hi"), on_upgrade: drop)
      mount_ws(context, fixture)
      channel = open(context)
      assert {:text, "hi"} = recv_frame(channel)
      assert {stop, %{reason: :backend, outcome: :sent, status: 101}} = stop!(3_000)
      assert stop.response_bytes == 2
      no_more_stops()
      close(channel)

      admission = start_supervised!({Admission, max_exchanges: 2}, id: make_ref())
      fixture = ws_backend(context, wire: "")
      mount_ws(%{context | admission: admission}, fixture)
      channel = open(context)
      eventually(fn -> Admission.count(admission) == 1 end)
      Process.exit(admission, :kill)
      assert {_, %{reason: :admission, outcome: :sent, status: 101}} = stop!(3_000)
      no_more_stops()
      close(channel)
    end

    test "a killed relay reports one stop", context do
      fixture = ws_backend(context, wire: "")
      mount_ws(context, fixture)
      channel = open(context)
      relay = eventually_relay(context)
      Process.exit(relay, :kill)
      assert {_, %{reason: :killed, outcome: :sent, status: 101}} = stop!()
      no_more_stops()
      close(channel)
    end
  end

  describe "raw upgrades (2.3)" do
    test "a tunnel closed by the caller reports 101 and tunnelled bytes", context do
      {_, connection} =
        backend(context, fn conn ->
          StreamBackend.write(conn, raw_upgrade("sftp", "hi"))
          {:ok, "abc"} = conn.transport.recv(conn.socket, 3, 2_000)
          conn.transport.recv(conn.socket, 0, 2_000)
        end)

      gateway = mount(context, connection)
      socket = connect(listener(gateway))
      :ok = :gen_tcp.send(socket, raw_head("/1.0/instances/a/sftp?project=allowed", "sftp"))
      {response, initial} = read_head(socket)
      assert response =~ "101"
      assert read_bytes(socket, initial, 2) == "hi"
      :ok = :gen_tcp.send(socket, "abc")
      Process.sleep(50)
      :gen_tcp.close(socket)

      {_, start} = start!()
      assert %{protocol: :raw, method: "GET"} = start
      {stop, meta} = stop!(3_000)

      assert %{
               path: "/1.0/instances/a/sftp",
               project: "allowed",
               admitted_as: :caller,
               status: 101,
               outcome: :ok,
               reason: nil
             } = meta

      assert %{request_bytes: 3, response_bytes: 2} = stop
      no_more_stops()
    end

    test "an NBD tunnel closed by the backend first reports :ok", context do
      {_, connection} =
        backend(context, fn conn ->
          StreamBackend.write(conn, raw_upgrade("nbd", "hello"))
          {:ok, "ab"} = conn.transport.recv(conn.socket, 2, 2_000)
        end)

      socket = connect(listener(mount(context, connection)))
      :ok = :gen_tcp.send(socket, raw_head("/1.0/instances/a/nbd?project=allowed", "nbd"))
      {response, initial} = read_head(socket)
      assert response =~ "101"
      assert read_bytes(socket, initial, 5) == "hello"
      :ok = :gen_tcp.send(socket, "ab")
      # The backend's EOF half-closes the tunnel; the caller then closes its side.
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 3_000)
      :gen_tcp.close(socket)

      {stop, meta} = stop!(3_000)
      assert %{path: "/1.0/instances/a/nbd", status: 101, outcome: :ok, reason: nil} = meta
      assert %{request_bytes: 2, response_bytes: 5} = stop
      no_more_stops()
    end

    test "a killed raw relay reports one stop", context do
      {_, connection} =
        backend(context, fn conn ->
          StreamBackend.write(conn, raw_upgrade("sftp", ""))
          conn.transport.recv(conn.socket, 0, 5_000)
        end)

      socket = connect(listener(mount(context, connection)))
      :ok = :gen_tcp.send(socket, raw_head("/1.0/instances/a/sftp", "sftp"))
      {response, _} = read_head(socket)
      assert response =~ "101"
      Process.exit(eventually_relay(context), :kill)
      assert {_, %{reason: :killed, outcome: :sent, status: 101}} = stop!(3_000)
      no_more_stops()
      :gen_tcp.close(socket)
    end

    test "rejected and invalid raw upgrades finish in the handler", context do
      {backend, connection} = backend(context, reply(200, %{}))
      port = listener(mount(context, connection))

      socket = connect(port)
      :ok = :gen_tcp.send(socket, raw_head("/1.0/instances/a/sftp?project=other", "sftp"))
      {response, _} = read_head(socket)
      assert response =~ "403"
      assert {_, %{status: 403, reason: :unauthorized, protocol: :raw}} = stop!()

      socket = connect(port)
      :ok = :gen_tcp.send(socket, raw_head("/1.0/instances/a/../sftp", "sftp"))
      {response, _} = read_head(socket)
      assert response =~ "400"
      assert {_, %{status: 400, reason: :invalid_request, path: nil}} = stop!()
      assert StreamBackend.accepted(backend) == 0
    end

    test "revocation and lifetime report their reason; fallback routes emit nothing", context do
      valid = :atomics.new(1, [])
      :atomics.put(valid, 1, 1)

      {_, connection} =
        backend(context, fn conn ->
          StreamBackend.write(conn, raw_upgrade("sftp", ""))
          conn.transport.recv(conn.socket, 0, 5_000)
        end)

      gateway =
        mount(context, connection,
          recheck_interval: 200,
          host_config: %{valid: fn _, _ -> :atomics.get(valid, 1) == 1 end}
        )

      port = listener(gateway)
      socket = connect(port)
      :ok = :gen_tcp.send(socket, raw_head("/1.0/instances/a/sftp", "sftp"))
      {response, _} = read_head(socket)
      assert response =~ "101"
      :atomics.put(valid, 1, 0)
      assert {_, %{reason: :revoked, outcome: :sent, status: 101}} = stop!(3_000)
      no_more_stops()

      gateway = mount(context, connection, max_lifetime: 300)
      socket = connect(listener(gateway))
      :ok = :gen_tcp.send(socket, raw_head("/1.0/instances/a/sftp", "sftp"))
      read_head(socket)
      assert {_, %{reason: :lifetime}} = stop!(3_000)
      no_more_stops()

      flush()
      assert RawHTTP.request(port, "GET", "/runtime").body == "host-runtime"
      refute_receive {:exchange, _, _, _}, 200
    end
  end

  describe "passivity (2.4)" do
    test "a raising handler changes no wire bytes and later exchanges still complete",
         context do
      {_, connection} = backend(context, reply(200, %{"metadata" => "native"}))
      mount(context, connection)
      baseline = get(context, "/1.0/instances")
      stop!()

      attach(fn _, _, _, _ -> raise "handler failure" end)
      raised = get(context, "/1.0/instances")
      assert {raised.status, raised.body} == {baseline.status, baseline.body}
      again = get(context, "/1.0/instances")
      assert {again.status, again.body} == {baseline.status, baseline.body}
      eventually(fn -> Admission.count(context.admission) == 0 end)
    end

    test "a blocked stop handler holds no backend socket or admission slot", context do
      test = self()
      gate = make_ref()

      attach(fn
        @stop, _, _, _ ->
          send(test, {:blocked, self()})
          receive do: (^gate -> :ok)

        _, _, _, _ ->
          :ok
      end)

      fixture = ws_backend(context, wire: "", notify: self())
      mount_ws(context, fixture, idle_timeout: 150)
      channel = open(context)
      recv_frame(channel)
      assert_receive {:blocked, handler}, 3_000
      assert_receive {:websocket_peer, _}, 1_000
      eventually(fn -> Admission.count(context.admission) == 0 end)
      assert Process.alive?(handler)
      send(handler, gate)
      close(channel)
    end

    test "a loaded but unstarted :telemetry never raises into a request", context do
      {_, connection} = backend(context, reply(200, %{}))
      mount(context, connection)
      :ok = Application.stop(:telemetry)
      on_exit(fn -> {:ok, _} = Application.ensure_all_started(:telemetry) end)

      assert Telemetry.list_handlers([:opsmaru_incus]) == []
      assert Telemetry.execute(@stop, %{}, %{}) == :ok
      refute Exchange.active?(Exchange.start(%{protocol: :http, method: "GET"}))
      assert get(context, "/1.0/instances").status == 200
    end

    test "no exchange event or observer exists when no handler is attached", context do
      detach_all()
      {_, connection} = backend(context, reply(200, %{}))
      mount(context, connection)
      assert get(context, "/1.0/instances").status == 200
      refute_receive {:exchange, _, _, _}, 100
    end
  end

  describe "redaction (3.1, 3.2)" do
    test "no metadata value carries a credential, query, secret, header, grant or address",
         context do
      {_, connection} = backend(context, reply(200, %{"metadata" => "body-marker"}))
      mount(context, connection, host_config: %{marker: "host-config-marker"})

      get(context, "/1.0/instances?project=allowed&filter=name%3Dsecret-filter", [
        auth(),
        {"x-private", "header-marker"},
        {"cookie", "cookie-marker"}
      ])

      get(context, "/1.0/instances/../x", [auth()])

      fixture = ws_backend(context, wire: WebSocketFixture.frame(1, "frame-marker"))
      mount_ws(context, fixture)
      channel = open(context)
      recv_frame(channel)
      close(channel)

      events = collect(6, 5_000)
      assert length(events) == 6

      for {_, _, metadata} <- events do
        text = inspect(metadata, limit: :infinity, printable_limit: :infinity)

        for forbidden <- [
              "fixture-token",
              "Bearer",
              "private",
              "secret",
              "filter",
              "header-marker",
              "cookie-marker",
              "body-marker",
              "frame-marker",
              "host-config-marker",
              "fixture_grant",
              "observer",
              "/../",
              ".sock",
              "ws-",
              "?"
            ] do
          refute text =~ forbidden, "#{forbidden} in #{text}"
        end

        refute Enum.any?(Map.values(metadata), &is_pid/1)
      end
    end
  end

  defp attach(fun) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, [@start, @stop], fun, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp detach_all do
    for %{id: id} <- :telemetry.list_handlers([:opsmaru_incus, :gateway, :exchange]),
        do: :telemetry.detach(id)
  end

  defp run(fun, fields \\ %{}) do
    fields =
      Map.merge(
        %{host: __MODULE__, protocol: :http, method: "GET", peer: %{address: {127, 0, 0, 1}}},
        fields
      )

    spawn(fn -> fields |> Exchange.start() |> fun.() end)
  end

  defp request(path, opts) do
    %Request{
      protocol: :http,
      method: "GET",
      path: path,
      query: "",
      peer: %{},
      project: opts[:project],
      target: opts[:target]
    }
  end

  defp start!(timeout \\ 2_000) do
    assert_receive {:exchange, @start, measurements, metadata}, timeout
    {measurements, metadata}
  end

  defp stop!(timeout \\ 2_000) do
    assert_receive {:exchange, @stop, measurements, metadata}, timeout
    assert Map.keys(metadata) |> Enum.sort() == Enum.sort(@stop_keys)
    {measurements, metadata}
  end

  defp no_more_stops(timeout \\ 200), do: refute_receive({:exchange, @stop, _, _}, timeout)

  defp flush do
    receive do
      {:exchange, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp collect(count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Enum.reduce_while(1..count, [], fn _, events ->
      receive do
        {:exchange, event, measurements, metadata} ->
          {:cont, [{event, measurements, metadata} | events]}
      after
        max(0, deadline - System.monotonic_time(:millisecond)) -> {:halt, events}
      end
    end)
  end

  defp eventually_relay(context) do
    eventually(fn -> Admission.count(context.admission) == 1 end)
    :sys.get_state(context.admission).slots |> Map.values() |> List.first()
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp ws_backend(context, opts) do
    start_supervised!(
      {WebSocketFixture,
       [path: Path.join(context.root, "ws-#{System.unique_integer([:positive])}")] ++ opts},
      id: make_ref()
    )
  end

  defp mount_ws(context, fixture, opts \\ []),
    do: mount(context, Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture), opts)

  defp open(context) do
    case negotiate(context, @operation_target, [auth(), {"cookie", "private"}]) do
      {:ok, channel} -> channel
      error -> flunk(inspect(error))
    end
  end

  defp negotiate(context, target, headers) do
    {:ok, conn} =
      Mint.HTTP.connect(:http, "localhost", context.port, mode: :passive, protocols: [:http1])

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, target, headers)

    {:ok, conn, status, response, data} =
      Upgrade.receive_response(conn, ref, System.monotonic_time(:millisecond) + 3_000, 1_048_576)

    if status == 101 do
      {:ok, conn, socket} = Mint.WebSocket.new(conn, ref, status, response, mode: :passive)

      {:ok, socket, frames} =
        Mint.WebSocket.decode(socket, IO.iodata_to_binary(Enum.reverse(data)))

      cursor = make_ref()
      Process.put(cursor, {conn, socket, frames})
      {:ok, %{conn: conn, ref: ref, cursor: cursor}}
    else
      Mint.HTTP.close(conn)
      {:error, status, response, IO.iodata_to_binary(Enum.reverse(data))}
    end
  end

  defp send_frame(channel, frame) do
    {conn, socket, frames} = Process.get(channel.cursor)
    {:ok, socket, bytes} = Mint.WebSocket.encode(socket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, channel.ref, bytes)
    Process.put(channel.cursor, {conn, socket, frames})
    channel
  end

  defp recv_frame(channel, timeout \\ 3_000) do
    case Process.get(channel.cursor) do
      {conn, socket, [frame | frames]} ->
        Process.put(channel.cursor, {conn, socket, frames})
        frame

      {conn, socket, []} ->
        case Mint.WebSocket.recv(conn, 0, timeout) do
          {:ok, conn, responses} ->
            bytes = for {:data, _, data} <- responses, into: <<>>, do: data
            {:ok, socket, frames} = Mint.WebSocket.decode(socket, bytes)
            Process.put(channel.cursor, {conn, socket, frames})
            recv_frame(channel, timeout)

          {:error, _, _, _} ->
            :closed
        end
    end
  end

  defp close(channel), do: Mint.HTTP.close(channel.conn)

  defp listener(gateway) do
    ref = {__MODULE__, make_ref()}
    opts = %{gateway: gateway, fallback: {Plug.Cowboy.Handler, {Router, gateway}}}
    dispatch = :cowboy_router.compile([{:_, [{:_, CowboyHandler, opts}]}])

    {:ok, _} =
      :cowboy.start_clear(ref, %{socket_opts: [ip: {127, 0, 0, 1}, port: 0]}, %{
        env: %{dispatch: dispatch},
        idle_timeout: 10_000
      })

    on_exit(fn -> :cowboy.stop_listener(ref) end)
    :ranch.get_port(ref)
  end

  defp raw_head(path, protocol),
    do: RawHTTP.head("GET", path, [auth(), {"connection", "upgrade"}, {"upgrade", protocol}])

  defp raw_upgrade(protocol, bytes),
    do: [
      "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: ",
      protocol,
      "\r\n\r\n",
      bytes
    ]

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, exit_on_close: false])

    socket
  end

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
end
