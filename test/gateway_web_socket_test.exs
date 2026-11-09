defmodule Opsmaru.Incus.GatewayWebSocketTest do
  use Opsmaru.TestSupport.GatewayCase, async: false
  alias Opsmaru.Incus.Upgrade
  alias Opsmaru.TestSupport.WebSocketFixture

  test "native binary and JSON controls remain intact and admission survives upgrade", context do
    fixture =
      ws_backend(context, wire: WebSocketFixture.frame(1, ~s({"command":"exit","return":7})))

    mount_ws(context, fixture)
    channel = open(context)
    assert Admission.count(context.admission) == 1
    assert {:text, ~s({"command":"exit","return":7})} = recv_frame(channel)
    binary = <<0, 255, 128, 42>>
    channel = send_frame(channel, {:binary, binary})
    assert {:binary, ^binary} = recv_frame(channel)
    text = ~s({"command":"window-resize","args":{"width":"120","height":"40"}})
    channel = send_frame(channel, {:text, text})
    assert {:text, ^text} = recv_frame(channel)
    close(channel)
    eventually(fn -> Admission.count(context.admission) == 0 end)

    assert [
             %{
               target: "/1.0/operations/native/websocket?project=allowed&secret=private%2Bkey",
               headers: headers
             }
           ] = WebSocketFixture.requests(fixture)

    refute headers["authorization"]
    refute headers["cookie"]
    refute headers["forwarded"]
    refute headers["x-forwarded-for"]
  end

  test "active and quiet channels do not repeat host checks before the next lease interval",
       context do
    checks = :atomics.new(1, [])
    fixture = ws_backend(context, wire: "")

    mount_ws(context, fixture,
      callback_timeout: 25,
      recheck_interval: 5_000,
      max_lifetime: 4_000,
      host_config: %{
        valid: fn _, _ ->
          :atomics.add_get(checks, 1, 1)
          true
        end
      }
    )

    channel = open(context)
    send_frame(channel, {:text, "attached"})
    assert {:text, "attached"} = recv_frame(channel)
    initial_checks = :atomics.get(checks, 1)
    assert initial_checks > 0

    for n <- 1..12 do
      payload = "native-#{n}"
      send_frame(channel, {:text, payload})
      assert {:text, ^payload} = recv_frame(channel)
    end

    # The next scheduled lease check is later than this channel's lifetime.
    # Let quiet polling run too, without asserting a throughput timing target.
    Process.sleep(100)
    assert :atomics.get(checks, 1) == initial_checks
    close(channel)
    eventually(fn -> Admission.count(context.admission) == 0 end)
  end

  test "backend close codes and final text are preserved", context do
    wire =
      WebSocketFixture.frame(1, "tail") <>
        WebSocketFixture.frame(8, <<1001::16, "native shutdown">>)

    fixture = ws_backend(context, wire: wire)
    mount_ws(context, fixture)
    channel = open(context)
    assert {:text, "tail"} = recv_frame(channel)
    assert {:close, 1001, "native shutdown"} = recv_frame(channel)
    close(channel)
    eventually(fn -> Admission.count(context.admission) == 0 end)
  end

  test "ping payloads are answered independently on each hop", context do
    observer = self()

    fixture =
      ws_backend(context,
        wire: WebSocketFixture.frame(9, "backend-ping"),
        frame_handler: fn opcode, data -> send(observer, {:backend_frame, opcode, data}) end
      )

    mount_ws(context, fixture)
    channel = open(context)
    assert_receive {:backend_frame, 10, "backend-ping"}, 2_000
    channel = send_frame(channel, {:ping, "frontend-ping"})
    assert {:pong, "frontend-ping"} = recv_frame(channel)
    refute_receive {:backend_frame, 9, "frontend-ping"}, 50
    close(channel)
  end

  test "denied authority and malformed negotiation contact no backend", context do
    fixture = ws_backend(context, wire: "")
    mount_ws(context, fixture)

    for {target, headers} <- [
          {"/1.0/events", []},
          {"/1.0/events?project=denied", [auth()]},
          {"/1.0/operations/wrong/websocket", [{"authorization", "Bearer wrong"}]}
        ] do
      assert {:error, status, _, _} = rejected(context, target, headers)
      assert status in [401, 403]
    end

    for {target, headers} <- [
          {"/1.0/not-a-websocket", [auth()]},
          {"/1.0/events", [auth(), {"sec-websocket-protocol", "unsupported"}]},
          {"/1.0/events", [auth(), {"content-length", "1"}]}
        ] do
      assert {:error, 400, _, _} = rejected(context, target, headers)
    end

    assert [] == WebSocketFixture.requests(fixture)
    eventually(fn -> Admission.count(context.admission) == 0 end)
  end

  test "revocation during backend negotiation is checked before frontend commitment", context do
    grant = :atomics.new(1, [])
    :atomics.put(grant, 1, 1)

    {backend, connection} =
      backend(context, fn conn ->
        {_, key} = List.keyfind(conn.head.headers, "sec-websocket-key", 0)
        accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        :atomics.put(grant, 1, 0)

        StreamBackend.write(conn, [
          "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
          accept,
          "\r\n\r\n"
        ])

        StreamBackend.await_close(conn)
      end)

    mount(context, connection,
      callback_timeout: 25,
      recheck_interval: 5_000,
      max_lifetime: 4_000,
      host_config: %{valid: fn _, _ -> :atomics.get(grant, 1) == 1 end}
    )

    assert {:error, 502, _, _} = rejected(context, "/1.0/events", [auth()])
    assert StreamBackend.accepted(backend) == 1
    assert_receive {:backend_closed, _}, 1_000
    eventually(fn -> Admission.count(context.admission) == 0 end)
  end

  test "native upgrade rejection preserves status bytes ETag and operation identity", context do
    body =
      ~s({"type":"error","error":"Denied natively","error_code":403,"operation":"/1.0/operations/known"})

    {_backend, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, [
          "HTTP/1.1 403 Forbidden\r\nContent-Length: #{byte_size(body)}\r\nETag: native-etag\r\nX-Native: unchanged\r\n\r\n",
          body
        ])
      end)

    mount(context, connection)
    assert {:error, 403, headers, ^body} = rejected(context, "/1.0/events", [auth()])
    assert {"etag", "native-etag"} in headers
    assert {"x-native", "unchanged"} in headers
    assert_receive {:backend_request, %{method: "GET"}}, 1_000
    refute_receive {:backend_request, _}, 20
    eventually(fn -> Admission.count(context.admission) == 0 end)
  end

  test "malformed and oversized backend handshakes fail once and release ownership", context do
    for reply <- [
          "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: wrong\r\n\r\n",
          "HTTP/1.1 101 Switching Protocols\r\nX-Oversize: " <>
            String.duplicate("x", 70_000) <> "\r\n\r\n"
        ] do
      {_backend, connection} = backend(context, fn conn -> StreamBackend.write(conn, reply) end)
      mount(context, connection)
      assert {:error, 502, _, _} = rejected(context, "/1.0/events", [auth()])
      assert_receive {:backend_request, %{method: "GET"}}, 1_000
      refute_receive {:backend_request, _}, 20
      eventually(fn -> Admission.count(context.admission) == 0 end)
    end
  end

  test "silent channel revocation closes both peers without reconnect or cancellation", context do
    flag = :atomics.new(1, [])
    :atomics.put(flag, 1, 1)
    fixture = ws_backend(context, wire: "", notify: self())

    mount_ws(context, fixture,
      recheck_interval: 100,
      host_config: %{valid: fn _, _ -> :atomics.get(flag, 1) == 1 end}
    )

    channel = open(context)
    revoked_at = System.monotonic_time(:millisecond)
    :atomics.put(flag, 1, 0)

    # Revocation has a hard 25ms frontend grace at this interval. Under load
    # the guard may close Cowboy before it can flush the best-effort frame.
    # Both outcomes must end access; native backend close frames are tested
    # separately and must retain their exact code and reason.
    case recv_frame(channel) do
      {:close, code, _} -> assert code in [1008, 1011]
      :closed -> :ok
    end

    assert System.monotonic_time(:millisecond) - revoked_at < 1_000
    assert_receive {:websocket_peer, outcome}, 1_000
    assert outcome in [:closed, :close_frame]
    eventually(fn -> Admission.count(context.admission) == 0 end)
    assert [%{method: "GET"}] = WebSocketFixture.requests(fixture)
    close(channel)
  end

  test "silent idle and absolute lifetime end local access", context do
    for limits <- [[idle_timeout: 150], [idle_timeout: 5_000, max_lifetime: 150]] do
      fixture = ws_backend(context, wire: "", notify: self())
      mount_ws(context, fixture, limits)
      channel = open(context)
      assert {:close, code, _} = recv_frame(channel)
      assert code in [1008, 1011]
      assert_receive {:websocket_peer, outcome}, 1_000
      assert outcome in [:closed, :close_frame]
      eventually(fn -> Admission.count(context.admission) == 0 end)
      assert length(WebSocketFixture.requests(fixture)) == 1
      close(channel)
    end
  end

  test "coalesced event overflow is visible and another request remains usable", context do
    fixture = ws_backend(context, wire: :binary.copy(WebSocketFixture.frame(1, "{}"), 8))
    connection = Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture, queue_limit: 2)
    mount(context, connection)
    assert {:error, 502, _, _} = rejected(context, "/1.0/events", [auth()])
    eventually(fn -> Admission.count(context.admission) == 0 end)
    other = ws_backend(context, wire: WebSocketFixture.frame(1, "independent"))
    mount_ws(context, other)
    channel = open(context, "/1.0/events")
    assert {:text, "independent"} = recv_frame(channel)
    close(channel)
  end

  test "caller loss and admission restart release relay sockets", context do
    fixture = ws_backend(context, wire: "", notify: self())
    mount_ws(context, fixture)
    channel = open(context)
    Mint.HTTP.close(channel.conn)
    assert_receive {:websocket_peer, outcome}, 1_000
    assert outcome in [:closed, :close_frame]
    eventually(fn -> Admission.count(context.admission) == 0 end)
    channel = open(context)
    relay = relay(context)
    eventually(fn -> :sys.get_state(relay).attached end)
    state = :sys.get_state(relay)
    lost_at = System.monotonic_time(:millisecond)
    Process.exit(context.admission, :kill)
    # Admission loss has a finite frontend grace; a busy Cowboy may be killed
    # before its best-effort close frame is flushed.
    case recv_frame(channel) do
      {:close, code, _} -> assert code in [1008, 1011]
      :closed -> :ok
    end

    assert System.monotonic_time(:millisecond) - lost_at < 1_000

    eventually(fn ->
      not Process.alive?(relay) and not Process.alive?(state.writer) and
        not Process.alive?(state.owner)
    end)

    assert_receive {:websocket_peer, outcome}, 1_000
    assert outcome in [:closed, :close_frame]
    assert [%{method: "GET"}, %{method: "GET"}] = WebSocketFixture.requests(fixture)
    close(channel)
  end

  test "admission loss force-closes a blocked Cowboy after its finite frontend grace", context do
    fixture = ws_backend(context, wire: "", notify: self())
    mount_ws(context, fixture)
    channel = open(context)
    relay = relay(context)
    eventually(fn -> :sys.get_state(relay).attached end)
    state = :sys.get_state(relay)
    owner = state.owner
    owner_ref = Process.monitor(owner)
    :erlang.suspend_process(owner)
    on_exit(fn -> Process.exit(owner, :kill) end)

    lost_at = System.monotonic_time(:millisecond)
    Process.exit(context.admission, :kill)
    # The independent guard must end access even when Cowboy cannot flush a
    # best-effort close frame. Backend-native close-frame fidelity is separate.
    assert :closed == recv_frame(channel)
    assert System.monotonic_time(:millisecond) - lost_at < 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert_receive {:websocket_peer, outcome}, 1_000
    assert outcome in [:closed, :close_frame]
    eventually(fn -> not Process.alive?(relay) and not Process.alive?(state.writer) end)
    refute Process.alive?(context.admission)
    assert [%{method: "GET"}] = WebSocketFixture.requests(fixture)
    close(channel)
  end

  test "native chunked upgrade rejection retains original headers and drops safe trailers",
       context do
    body = ~s({"type":"error","error":"native denied","operation":"/1.0/operations/known"})

    {_backend, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, [
          "HTTP/1.1 409 Conflict\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\nETag: retained\r\nLocation: /1.0/operations/known\r\nTrailer: X-Checksum\r\n\r\n",
          Integer.to_string(byte_size(body), 16),
          "\r\n",
          body,
          "\r\n0\r\nX-Checksum: safe\r\n\r\n"
        ])
      end)

    mount(context, connection)
    assert {:error, 409, headers, ^body} = rejected(context, "/1.0/events", [auth()])
    assert {"etag", "retained"} in headers
    assert {"location", "/1.0/operations/known"} in headers
    assert {"content-type", "application/json"} in headers
    refute List.keymember?(headers, "x-checksum", 0)
  end

  test "tightened gateway native rejection body budget fails before commit", context do
    body = String.duplicate("x", 1024)

    {_backend, connection} =
      backend(context, fn conn ->
        StreamBackend.write(conn, ["HTTP/1.1 403 Forbidden\r\nContent-Length: 1024\r\n\r\n", body])
      end)

    mount(context, connection, max_response_bytes: 64)
    assert {:error, 502, _, failure} = rejected(context, "/1.0/events", [auth()])
    refute failure == body
    assert_receive {:backend_request, %{method: "GET"}}, 1_000
    refute_receive {:backend_request, _}, 20
  end

  test "simultaneous large duplex traffic drains output while backend input writer is blocked",
       context do
    output = :binary.copy(<<255, 0>>, 8192)
    wire = :binary.copy(WebSocketFixture.frame(2, output), 256)
    fixture = ws_backend(context, wire: wire)

    connection =
      Connection.unix!(WebSocketFixture.path(fixture),
        owner: :fixture,
        queue_limit: 1024,
        max_response_bytes: 16_777_216
      )

    mount(context, connection, idle_timeout: 10_000)
    channel = open(context)
    :ok = :inet.setopts(Mint.HTTP.get_socket(channel.conn), sndbuf: 4096)
    {_conn, socket, _frames} = Process.get(channel.cursor)
    input = :binary.copy(<<1, 128>>, 8192)
    {:ok, _socket, frame} = Mint.WebSocket.encode(socket, {:binary, input})

    writer =
      Task.async(fn ->
        Enum.each(1..256, fn _ ->
          {:ok, _} = Mint.WebSocket.stream_request_body(channel.conn, channel.ref, frame)
        end)
      end)

    # This peer writes its entire multi-MiB output before it reads any input.
    # Both streams exceed the small caller send buffer, so a relay that waits
    # synchronously for backend writes cannot reach this output drain.
    for _ <- 1..256, do: assert({:binary, ^output} = recv_frame(channel))
    for _ <- 1..256, do: assert({:binary, ^input} = recv_frame(channel))
    assert :ok = Task.await(writer, 10_000)
    close(channel)
    eventually(fn -> Admission.count(context.admission) == 0 end)
  end

  test "default queue pauses input while reverse output and a complete upload drain", context do
    {fixture, connection} = gated_backend(context)
    assert connection.queue_limit == 64

    mount(context, connection,
      max_request_bytes: 1_073_741_824,
      max_response_bytes: 1_073_741_824,
      idle_timeout: 10_000
    )

    {channel, relay, gate, transport, backend_socket, writer, payload} = paused_upload(context)
    state = :sys.get_state(relay)
    assert :queue.len(state.write_queue) in 32..64
    assert state.queued_bytes <= connection.max_response_bytes
    # The frontend remains able to write while its socket input is passive.
    reverse = <<255, 0, 128, "reverse while paused">>
    :ok = transport.send(backend_socket, WebSocketFixture.frame(2, reverse))
    assert {:binary, ^reverse} = recv_frame(channel)
    assert :sys.get_state(relay).input_paused != nil
    send(gate, :release)
    # One initial frame and 256 further frames retain exact bytes and order.
    for _ <- 1..257, do: assert({:binary, ^payload} = recv_frame(channel))
    assert 256 == Task.await(writer, 10_000)

    eventually(fn ->
      state = :sys.get_state(relay)
      state.input_paused == nil and :queue.is_empty(state.write_queue) and state.writing == nil
    end)

    close(channel)
    eventually(fn -> Admission.count(context.admission) == 0 end)
    assert length(WebSocketFixture.requests(fixture)) == 1
  end

  test "paused default-queue input still ends on revocation, deadline and owner loss", context do
    for stop <- [:revocation, :deadline, :owner_loss] do
      flag = :atomics.new(1, [])
      :atomics.put(flag, 1, 1)
      {fixture, connection} = gated_backend(context)

      mount(context, connection,
        max_request_bytes: 1_073_741_824,
        max_response_bytes: 1_073_741_824,
        idle_timeout: 10_000,
        max_lifetime: 2_000,
        recheck_interval: 200,
        host_config: %{valid: fn _, _ -> :atomics.get(flag, 1) == 1 end}
      )

      {channel, relay, gate, _, _, writer, _} = paused_upload(context)
      state = :sys.get_state(relay)
      if stop == :revocation, do: :atomics.put(flag, 1, 0)
      if stop == :owner_loss, do: Process.exit(state.owner, :kill)

      case recv_frame(channel) do
        {:close, code, _} -> assert code in [1008, 1011]
        :closed -> :ok
      end

      eventually(fn -> Admission.count(context.admission) == 0 end)
      assert Task.await(writer, 3_000) in 0..256
      eventually(fn -> not Process.alive?(relay) and not Process.alive?(state.writer) end)
      send(gate, :release)
      eventually(fn -> Port.info(Mint.HTTP.get_socket(state.conn)) == nil end)
      assert length(WebSocketFixture.requests(fixture)) == 1
      close(channel)
    end
  end

  test "already parsed tiny-frame bursts still respect the hard writer queue cap", context do
    alias Opsmaru.Incus.Gateway.WebSocket
    fixture = ws_backend(context, wire: "")
    connection = Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture)
    mount(context, connection)
    channel = open(context)
    relay = relay(context)
    eventually(fn -> :sys.get_state(relay).attached end)
    state = :sys.get_state(relay)
    {_, frontend, _} = :sys.get_state(state.owner)
    assert %{relay: ^relay, input_paused: nil, monitor: monitor} = frontend
    assert is_reference(monitor)
    :erlang.trace(relay, true, [:send, {:tracer, self()}])
    # Keep the real relay writer blocked independently of kernel buffer sizes.
    :erlang.suspend_process(state.writer)

    # Cowboy continues callbacks for frames already in its parser buffer after
    # active:false. Drive that parsed tail directly: a TCP write does not promise
    # one delivery, so socket coalescing cannot be the oracle for this hard cap.
    frontend =
      Enum.reduce(1..(connection.queue_limit + 1), frontend, fn _, frontend ->
        {commands, frontend} = WebSocket.websocket_handle({:binary, ""}, frontend)
        assert commands in [[], [{:active, false}]]
        frontend
      end)

    full = :sys.get_state(relay)
    assert :queue.len(full.write_queue) == connection.queue_limit
    assert full.writing == 0
    assert full.queued_bytes == 0
    assert frontend.input_paused != nil

    assert {[{:close, 1011, "Gateway channel ended"}], _} =
             WebSocket.websocket_handle({:binary, ""}, frontend)

    case recv_frame(channel) do
      {:close, 1011, _} -> :ok
      :closed -> :ok
    end

    assert_receive {:trace, ^relay, :send,
                    {:gateway_ws_close, ^relay, 1011, "Gateway WebSocket queue exceeded"}, _},
                   1_000

    eventually(fn -> Admission.count(context.admission) == 0 end)
    eventually(fn -> not Process.alive?(state.writer) end)
    assert length(WebSocketFixture.requests(fixture)) == 1
    close(channel)
  end

  test "a stale resume cannot reopen a newer frontend pause" do
    alias Opsmaru.Incus.Gateway.WebSocket
    relay = self()
    old = make_ref()
    current = make_ref()
    state = %{relay: relay, input_paused: current}
    assert {[], ^state} = WebSocket.websocket_info({:gateway_ws_resume, relay, old}, state)

    assert {[{:active, true}], %{input_paused: nil}} =
             WebSocket.websocket_info({:gateway_ws_resume, relay, current}, state)
  end

  test "handshake worker loss and uncompleted handoff release backend and slot", context do
    alias Opsmaru.Incus.Gateway.{Policy, WebSocketRelay}

    for stage <- [:negotiated, :committed] do
      fixture = ws_backend(context, wire: "", notify: self())
      gateway = mount_ws(context, fixture)
      parent = self()

      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      owner_ref = Process.monitor(owner)

      worker =
        spawn(fn ->
          {:ok, request} =
            Policy.request(%{
              protocol: :websocket,
              method: "GET",
              path: "/1.0/events",
              peer: %{},
              authorization: "Bearer fixture-token"
            })

          {:ok, admitted} = Policy.admit(gateway, request)
          {:ok, relay, _} = WebSocketRelay.open(gateway, request, admitted, owner, [])
          if stage == :committed, do: :ok = WebSocketRelay.commit(relay)
          send(parent, {:relay_ready, relay})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:relay_ready, relay}, 2_000
      relay_ref = Process.monitor(relay)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^relay_ref, :process, ^relay, _}, 1_000
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 1_000
      assert_receive {:websocket_peer, :closed}, 1_000
      eventually(fn -> Admission.count(context.admission) == 0 end)
    end
  end

  test "normal Plug handoff exit is tolerated only until bounded attachment", context do
    alias Opsmaru.Incus.Gateway.{Policy, WebSocketRelay}
    fixture = ws_backend(context, wire: "", notify: self())
    gateway = mount_ws(context, fixture)
    parent = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    owner_ref = Process.monitor(owner)

    spawn(fn ->
      {:ok, request} =
        Policy.request(%{
          protocol: :websocket,
          method: "GET",
          path: "/1.0/events",
          peer: %{},
          authorization: "Bearer fixture-token"
        })

      {:ok, admitted} = Policy.admit(gateway, request)
      {:ok, relay, _} = WebSocketRelay.open(gateway, request, admitted, owner, [])
      :ok = WebSocketRelay.commit(relay)
      send(parent, {:relay_ready, relay})
    end)

    assert_receive {:relay_ready, relay}, 2_000
    relay_ref = Process.monitor(relay)
    assert_receive {:DOWN, ^relay_ref, :process, ^relay, _}, 1_500
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 1_000
    eventually(fn -> Admission.count(context.admission) == 0 end)
  end

  test "active event overflow releases only its channel", context do
    fixture =
      ws_backend(context,
        wire: "",
        response_frames: fn opcode, payload ->
          if payload == "overflow",
            do: :binary.copy(WebSocketFixture.frame(1, "{}"), 8),
            else: WebSocketFixture.frame(opcode, payload)
        end
      )

    connection = Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture, queue_limit: 2)
    mount(context, connection)
    channel = open(context, "/1.0/events")
    channel = send_frame(channel, {:text, "overflow"})
    assert {:close, 1009, _} = recv_frame(channel)
    close(channel)
    eventually(fn -> Admission.count(context.admission) == 0 end)
    other = open(context)
    other = send_frame(other, {:binary, "independent"})
    assert {:binary, "independent"} = recv_frame(other)
    close(other)
  end

  test "revocation interrupts a confirmed blocked backend writer", context do
    flag = :atomics.new(1, [])
    :atomics.put(flag, 1, 1)
    observer = self()

    fixture =
      ws_backend(context,
        wire: "",
        frame_handler: fn _, _ ->
          send(observer, {:blocked_backend, self()})

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end
        end
      )

    connection =
      Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture, queue_limit: 1024)

    mount(context, connection,
      recheck_interval: 200,
      host_config: %{valid: fn _, _ -> :atomics.get(flag, 1) == 1 end}
    )

    channel = open(context)
    relay = relay(context)
    state = :sys.get_state(relay)
    :ok = :inet.setopts(Mint.HTTP.get_socket(state.conn), sndbuf: 1024)
    {_conn, socket, _frames} = Process.get(channel.cursor)
    {:ok, _, frame} = Mint.WebSocket.encode(socket, {:binary, :binary.copy(<<7>>, 16_384)})

    writer =
      Task.async(fn ->
        Enum.reduce_while(1..256, :ok, fn _, _ ->
          case Mint.WebSocket.stream_request_body(channel.conn, channel.ref, frame) do
            {:ok, _} -> {:cont, :ok}
            _ -> {:halt, :closed}
          end
        end)
      end)

    assert_receive {:blocked_backend, gate}, 2_000
    eventually(fn -> blocked_writer?(state.writer) end)
    :atomics.put(flag, 1, 0)

    case recv_frame(channel) do
      {:close, code, _} -> assert code in [1008, 1011]
      :closed -> :ok
    end

    eventually(fn -> Admission.count(context.admission) == 0 end)
    send(gate, :release)
    assert Task.await(writer, 3_000) in [:ok, :closed]
    assert length(WebSocketFixture.requests(fixture)) == 1
    close(channel)
  end

  test "backend verified TLS is separate from gateway caller trust", context do
    server = TLSIdentity.generate(context.root, "ws-backend", "localhost")
    client = TLSIdentity.generate(context.root, "ws-backend-client", "backend-client")
    wrong = TLSIdentity.generate(context.root, "ws-wrong", "localhost")

    fixture =
      start_supervised!(
        {WebSocketFixture,
         transport: :ssl,
         certfile: server.certfile,
         keyfile: server.keyfile,
         peer_options: [
           cacertfile: client.cafile,
           verify: :verify_peer,
           fail_if_no_peer_cert: true
         ]},
        id: make_ref()
      )

    endpoint = WebSocketFixture.endpoint(fixture).url
    tls = [cacertfile: server.cafile, certfile: client.certfile, keyfile: client.keyfile]
    mount(context, Connection.https!(endpoint, owner: :fixture, tls: tls))
    channel = open(context)
    assert {:binary, <<0, 255, 128>>} = recv_frame(channel)
    close(channel)
    eventually(fn -> Admission.count(context.admission) == 0 end)

    for bad_tls <- [
          Keyword.put(tls, :cacertfile, wrong.cafile),
          Keyword.put(tls, :keyfile, wrong.keyfile)
        ] do
      mount(context, Connection.https!(endpoint, owner: :fixture, tls: bad_tls))
      assert {:error, 502, _, failure} = rejected(context, "/1.0/events", [auth()])
      assert native(failure)["metadata"]["gateway"]["outcome"] in ["not_sent", "sent"]
    end

    assert length(WebSocketFixture.requests(fixture)) == 1
  end

  test "relay status redacts secrets and worker loss closes its frontend", context do
    fixture = ws_backend(context, wire: "", notify: self())
    mount_ws(context, fixture)
    channel = open(context)
    relay = relay(context)
    status = inspect(:sys.get_status(relay), limit: :infinity)
    refute status =~ "private%2Bkey"
    refute status =~ "fixture-token"
    refute status =~ context.root
    state = :sys.get_state(relay)
    writer_ref = Process.monitor(state.writer)
    Process.exit(relay, :kill)
    assert {:close, 1011, _} = recv_frame(channel)
    assert_receive {:DOWN, ^writer_ref, :process, _, _}, 1_000
    assert_receive {:websocket_peer, :closed}, 1_000
    eventually(fn -> Admission.count(context.admission) == 0 end)
    close(channel)
  end

  test "slow frontend bounds backend progress and revocation interrupts blocked Cowboy output",
       context do
    flag = :atomics.new(1, [])
    :atomics.put(flag, 1, 1)
    payload = :binary.copy(<<0, 255>>, 8192)
    wire = :binary.copy(WebSocketFixture.frame(2, payload), 2048)
    fixture = ws_backend(context, wire: wire)

    connection =
      Connection.unix!(WebSocketFixture.path(fixture),
        owner: :fixture,
        max_response_bytes: 67_108_864,
        queue_limit: 4096
      )

    mount(context, connection,
      recheck_interval: 200,
      idle_timeout: 5_000,
      host_config: %{valid: fn _, _ -> :atomics.get(flag, 1) == 1 end}
    )

    channel = open(context)
    :ok = :inet.setopts(Mint.HTTP.get_socket(channel.conn), recbuf: 1024)
    relay = relay(context)
    relay_ref = Process.monitor(relay)

    eventually(fn ->
      state = :sys.get_state(relay)

      not is_nil(state.pending) and
        System.monotonic_time(:millisecond) - :atomics.get(state.clock, 1) > 100
    end)

    state = :sys.get_state(relay)
    owner_ref = Process.monitor(state.owner)
    assert state.received < byte_size(wire)
    Process.sleep(50)
    assert :sys.get_state(relay).received == state.received
    assert {:message_queue_len, count} = Process.info(state.owner, :message_queue_len)
    assert count <= 8
    :atomics.put(flag, 1, 0)
    assert_receive {:DOWN, ^relay_ref, :process, ^relay, _}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, _, _}, 1_000
    eventually(fn -> Admission.count(context.admission) == 0 end)
    assert length(WebSocketFixture.requests(fixture)) == 1
    close(channel)
  end

  test "busy WebSocket traffic cannot refresh the absolute lifetime", context do
    fixture = ws_backend(context, wire: "")
    mount_ws(context, fixture, idle_timeout: 5_000, max_lifetime: 300)
    started = System.monotonic_time(:millisecond)
    channel = open(context)

    count =
      Enum.reduce_while(1..100, 0, fn _, count ->
        send_frame(channel, {:text, "active"})

        case recv_frame(channel) do
          {:text, "active"} -> {:cont, count + 1}
          {:close, _, _} -> {:halt, count}
          :closed -> {:halt, count}
        end
      end)

    assert count > 0 and count < 100
    assert System.monotonic_time(:millisecond) - started < 1_000
    eventually(fn -> Admission.count(context.admission) == 0 end)
    assert length(WebSocketFixture.requests(fixture)) == 1
    close(channel)
  end

  test "backend writer failure closes its channel without leaking admission", context do
    fixture = ws_backend(context, wire: "", notify: self())
    mount_ws(context, fixture)
    channel = open(context)
    relay = relay(context)
    Process.exit(:sys.get_state(relay).writer, :kill)
    assert {:close, 1011, _} = recv_frame(channel)
    assert_receive {:websocket_peer, :closed}, 1_000
    eventually(fn -> Admission.count(context.admission) == 0 end)
    close(channel)
  end

  defp gated_backend(context) do
    observer = self()

    fixture =
      ws_backend(context,
        wire: "",
        on_upgrade: fn transport, socket ->
          send(observer, {:backend_socket, transport, socket})
        end,
        response_frames: fn opcode, data ->
          unless Process.get(:released) do
            send(observer, {:backend_gated, self()})

            receive do
              :release -> Process.put(:released, true)
            after
              10_000 -> :ok
            end
          end

          WebSocketFixture.frame(opcode, data)
        end
      )

    {fixture, Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture)}
  end

  defp paused_upload(context) do
    channel = open(context)
    relay = relay(context)
    state = :sys.get_state(relay)
    :ok = :inet.setopts(Mint.HTTP.get_socket(state.conn), sndbuf: 1024)
    payload = :binary.copy(<<7>>, 32_768)
    channel = send_frame(channel, {:binary, payload})
    assert_receive {:backend_socket, transport, backend_socket}, 2_000
    assert_receive {:backend_gated, gate}, 2_000
    {_conn, socket, _frames} = Process.get(channel.cursor)
    {:ok, _, frame} = Mint.WebSocket.encode(socket, {:binary, payload})

    writer =
      Task.async(fn ->
        Enum.reduce_while(1..256, 0, fn _, count ->
          case Mint.WebSocket.stream_request_body(channel.conn, channel.ref, frame) do
            {:ok, _} -> {:cont, count + 1}
            _ -> {:halt, count}
          end
        end)
      end)

    eventually(fn ->
      try do
        Map.get(:sys.get_state(relay), :input_paused) != nil
      catch
        :exit, _ -> flunk("gateway closed a valid upload before applying backpressure")
      end
    end)

    eventually(fn -> blocked_writer?(state.writer) end)
    {channel, relay, gate, transport, backend_socket, writer, payload}
  end

  defp relay(context), do: :sys.get_state(context.admission).slots |> Map.values() |> List.first()

  defp blocked_writer?(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, frames} ->
        Enum.any?(frames, fn {module, function, _, _} ->
          module == :prim_inet and function == :send
        end)

      _ ->
        false
    end
  end

  defp ws_backend(context, opts) do
    start_supervised!(
      {WebSocketFixture,
       [path: Path.join(context.root, "ws-#{System.unique_integer([:positive])}")] ++ opts},
      id: make_ref()
    )
  end

  defp mount_ws(context, fixture, opts \\ []) do
    mount(context, Connection.unix!(WebSocketFixture.path(fixture), owner: :fixture), opts)
  end

  defp open(
         context,
         target \\ "/1.0/operations/native/websocket?project=allowed&secret=private%2Bkey"
       ) do
    case negotiate(context, target, [
           auth(),
           {"cookie", "private"},
           {"forwarded", "private"},
           {"x-forwarded-for", "private"}
         ]) do
      {:ok, channel} -> channel
      error -> flunk(inspect(error))
    end
  end

  defp rejected(context, target, headers), do: negotiate(context, target, headers)

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

      # Mutable test-local cursor keeps frame reads concise without changing production ownership.
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

  defp recv_frame(channel) do
    case Process.get(channel.cursor) do
      {conn, socket, [frame | frames]} ->
        Process.put(channel.cursor, {conn, socket, frames})
        frame

      {conn, socket, []} ->
        case Mint.WebSocket.recv(conn, 0, 3_000) do
          {:ok, conn, responses} ->
            bytes = for {:data, _, data} <- responses, into: <<>>, do: data
            {:ok, socket, frames} = Mint.WebSocket.decode(socket, bytes)
            Process.put(channel.cursor, {conn, socket, frames})
            recv_frame(channel)

          {:error, _, :closed, _} ->
            :closed
        end
    end
  end

  defp close(channel), do: Mint.HTTP.close(channel.conn)
  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
