defmodule Opsmaru.Incus.EventListenerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Opsmaru.Incus

  alias Opsmaru.Incus.{
    Connection,
    Context,
    Error,
    EventListener,
    Events,
    Model,
    RequestContext,
    Server,
    WebSocket
  }

  alias Opsmaru.TestSupport.{CleanupAssertions, HTTPFixture, TLSIdentity, WebSocketFixture}
  @driver Path.expand("../.integration/event-handlers-driver", __DIR__)
  @event %{"type" => "logging", "timestamp" => "2026-10-11T12:00:00Z", "metadata" => %{}}

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./eventhandlers"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-listen-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https],
      {phase, peer_delay} <- [{:upgrade, 0}, {:upgrade, 600}, {:write, 0}] do
    test "#{transport} caller loss closes an event listener blocked in #{phase} (peer delay #{peer_delay} ms)",
         %{root: root} do
      parent = self()

      tls =
        if unquote(transport) == :https, do: TLSIdentity.generate(root, "blocked", "localhost")

      server =
        if tls,
          do: [
            transport: :ssl,
            certfile: tls.certfile,
            keyfile: tls.keyfile,
            peer_options: [
              cacertfile: tls.cafile,
              verify: :verify_peer,
              fail_if_no_peer_cert: true
            ]
          ],
          else: [transport: :gen_tcp, path: Path.join(root, "blocked-listener")]

      fixture =
        start_supervised!({HTTPFixture,
         server ++
           [
             handler: fn request ->
               %{
                 upgrade: fn transport, socket ->
                   if unquote(phase) == :upgrade do
                     send(parent, :listener_negotiating)
                     result = transport.recv(socket, 0, 30_000)
                     send(parent, {:listener_socket_closed, result})
                     Process.sleep(unquote(peer_delay))
                     send(parent, {:listener_peer_closed, result})
                   else
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

                     send(parent, {:listener_upgraded, self()})

                     # Hold reads until the caller is gone, then drain to observe closure.
                     receive do
                       :drain -> send(parent, {:listener_peer_closed, drain(transport, socket)})
                     after
                       30_000 -> :ok
                     end
                   end
                 end
               }
             end
           ]})

      options = [
        owner: :fixture,
        timeout: 30_000,
        stream_timeout: 30_000,
        max_stream_bytes: 67_108_864
      ]

      connection =
        if tls,
          do:
            Connection.https!(
              HTTPFixture.endpoint(fixture).url,
              options ++
                [tls: [cacertfile: tls.cafile, certfile: tls.certfile, keyfile: tls.keyfile]]
            ),
          else: Connection.unix!(HTTPFixture.endpoint(fixture).socket, options)

      client = %Incus{
        connection: connection,
        context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
        server: %Server{api_extensions: []}
      }

      caller =
        spawn(fn ->
          {:ok, listener} = EventListener.open(client)
          send(parent, {:blocked_listener, listener})

          receive do
            :write -> :ok
          end

          event = put_in(@event, ["metadata", "message"], String.duplicate("x", 1_000_000))

          Enum.reduce_while(1..64, nil, fn _, _ ->
            case EventListener.send_event(listener, event) do
              :ok -> {:cont, nil}
              error -> {:halt, error}
            end
          end)
        end)

      on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

      case unquote(phase) do
        :upgrade ->
          assert_receive :listener_negotiating, 5_000
          Process.exit(caller, :kill)
          assert_receive {:listener_socket_closed, {:error, :closed}}, 5_000
          assert_receive {:listener_peer_closed, {:error, :closed}}, 5_000

        :write ->
          assert_receive {:blocked_listener, listener}, 5_000
          channel = :sys.get_state(listener.pid).channel

          on_exit(fn ->
            for pid <- [listener.pid, channel.pid],
                Process.alive?(pid),
                do: Process.exit(pid, :kill)
          end)

          assert_receive {:listener_upgraded, peer}, 5_000
          socket = :sys.get_state(channel.pid).conn |> Mint.HTTP.get_socket()

          :ok =
            if tls,
              do: :ssl.setopts(socket, sndbuf: 1024),
              else: :inet.setopts(socket, sndbuf: 1024)

          send(caller, :write)
          await_listener_write(channel.pid, System.monotonic_time(:millisecond) + 5_000)
          monitors = CleanupAssertions.monitor([listener.pid, channel.pid])
          Process.exit(caller, :kill)
          assert :ok = CleanupAssertions.assert_stopped(monitors)
          send(peer, :drain)
          assert_receive {:listener_peer_closed, {:error, :closed}}, 10_000
      end

      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end
  end

  defp drain(transport, socket) do
    case transport.recv(socket, 0, 10_000) do
      {:ok, _} -> drain(transport, socket)
      other -> other
    end
  end

  # gen_tcp blocks in prim_inet; ssl blocks the caller in a call to its TLS sender.
  # Two consecutive samples distinguish a blocked write from one in progress.
  defp await_listener_write(pid, deadline) do
    unless blocked_write?(pid) and blocked_write_after?(pid, 50) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      await_listener_write(pid, deadline)
    end
  end

  defp blocked_write_after?(pid, delay) do
    Process.sleep(delay)
    blocked_write?(pid)
  end

  defp blocked_write?(pid) do
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)

    Enum.any?(stack, fn {module, function, _, _} ->
      {module, function} in [{:prim_inet, :send}, {:tls_sender, :call}]
    end)
  end

  for transport <- [:unix, :https] do
    test "#{transport} handler registration/removal, native callback data and repeatable wait match pinned listener",
         %{root: root} do
      {client, fixture} = fixture(unquote(transport), root)
      expected = oracle(Map.put(native_connection(client), :event, @event))
      assert_peer_closed()
      assert {:ok, listener} = EventListener.open(client)
      assert EventListener.active?(listener) == expected["active_before"]
      parent = self()

      assert {:ok, _} =
               EventListener.add_handler(listener, ["logging"], &send(parent, {:event, &1}))

      assert {:ok, removed} =
               EventListener.add_handler(listener, [], &send(parent, {:removed, &1}))

      assert :ok = EventListener.remove_handler(listener, removed)
      assert expected["remove"]

      assert {:error, %Error{kind: :invalid_event_target}} =
               EventListener.remove_handler(listener, removed)

      refute expected["remove_again"]

      assert {:error, %Error{kind: :invalid_event_handler}} =
               EventListener.add_handler(listener, [], nil)

      assert expected["invalid_handler"]
      assert :ok = EventListener.send_event(listener, @event)
      assert_receive {:event, %Model{data: event}}, 1_000
      assert event == expected["event"]
      refute_receive {:removed, _}, 30
      assert :ok = EventListener.disconnect(listener)
      assert EventListener.active?(listener) == expected["active_after"]
      assert :ok = EventListener.wait(listener)
      assert :ok = EventListener.wait(listener)
      assert expected["wait"] and expected["wait_again"]
      assert_peer_closed()

      assert Enum.count(
               WebSocketFixture.requests(fixture),
               &String.starts_with?(&1.target, "/1.0/events")
             ) == 2
    end

    test "#{transport} filters, capacity and targets are isolated between explicit listeners", %{
      root: root
    } do
      {client, _} = fixture(unquote(transport), root, queue_limit: 2)
      {:ok, first} = EventListener.open(client)
      {:ok, second} = EventListener.open(client)
      parent = self()

      {:ok, target} =
        EventListener.add_handler(first, ["logging"], &send(parent, {:selected, &1}))

      {:ok, _} = EventListener.add_handler(first, [], fn _ -> :ok end)

      assert {:error, %Error{kind: :handler_capacity}} =
               EventListener.add_handler(first, [], fn _ -> :ok end)

      assert {:error, %Error{kind: :invalid_event_target}} =
               EventListener.remove_handler(second, target)

      assert :ok = EventListener.send_event(first, %{@event | "type" => "operation"})
      refute_receive {:selected, _}, 150
      assert EventListener.active?(second)
      assert :ok = EventListener.remove_handler(first, target)
      assert :ok = EventListener.disconnect(first)
      assert_peer_closed()
      assert :ok = EventListener.disconnect(second)
      assert_peer_closed()
    end

    test "#{transport} local wait timeout leaves a live subscription active and sends no backend cancellation",
         %{root: root} do
      {client, fixture} = fixture(unquote(transport), root)
      {:ok, listener} = EventListener.open(client)
      assert {:error, %Error{kind: :deadline}} = EventListener.wait(listener, 5)
      assert EventListener.active?(listener)
      assert {:error, %Error{kind: :invalid_listener_wait}} = EventListener.wait(listener, 0)
      refute_received {:websocket_peer, _}
      assert :ok = EventListener.disconnect(listener)
      assert :ok = EventListener.wait(listener)
      assert_peer_closed()
      assert Enum.all?(WebSocketFixture.requests(fixture), &(&1.method == "GET"))
    end

    test "#{transport} callback exceptions are redacted and release the socket, without damaging another listener",
         %{root: root} do
      {client, _} = fixture(unquote(transport), root)
      {:ok, independent} = EventListener.open(client)

      log =
        capture_log(fn ->
          {:ok, listener} = EventListener.open(client)

          {:ok, _} =
            EventListener.add_handler(listener, [], fn _ -> raise "private-callback-secret" end)

          assert :ok = EventListener.send_event(listener, @event)
          assert {:error, %Error{kind: :callback_failed}} = EventListener.wait(listener)
          refute EventListener.active?(listener)
        end)

      refute log =~ "private-callback-secret"
      assert_peer_closed()
      assert EventListener.active?(independent)
      refute_received {:websocket_peer, _}
      assert :ok = EventListener.disconnect(independent)
      assert_peer_closed()
    end

    test "#{transport} blocked callback is killed within its budget and result remains repeatable",
         %{root: root} do
      {client, _} = fixture(unquote(transport), root, timeout: 100)
      {:ok, listener} = EventListener.open(client)
      parent = self()

      {:ok, _} =
        EventListener.add_handler(listener, [], fn _ ->
          send(parent, {:callback, self()})

          receive do
            :never -> :ok
          end
        end)

      assert :ok = EventListener.send_event(listener, @event)
      assert_receive {:callback, worker}, 1_000
      monitor = Process.monitor(worker)
      assert {:error, %Error{kind: :callback_timeout}} = EventListener.wait(listener)
      assert {:error, %Error{kind: :callback_timeout}} = EventListener.wait(listener)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
      assert_peer_closed()
    end

    test "#{transport} native EOF, malformed events and lifetime terminate the local listener", %{
      root: root
    } do
      for {opts, budgets, expected} <- [
            {[close_after: 150], [], :ok},
            {[wire: WebSocketFixture.frame(1, "bad")], [], :invalid_event},
            {[], [stream_timeout: 150], :deadline}
          ] do
        {client, _} = fixture(unquote(transport), root, budgets, opts)
        assert {:ok, listener} = EventListener.open(client)

        if expected == :ok,
          do: assert(:ok == EventListener.wait(listener)),
          else: assert({:error, %Error{kind: expected}} == EventListener.wait(listener))

        refute EventListener.active?(listener)
        assert_peer_closed()
      end
    end

    test "#{transport} owner loss kills an active callback and raw process calls cannot bypass owner binding",
         %{
           root: root
         } do
      {client, _} = fixture(unquote(transport), root)
      parent = self()

      owner =
        spawn(fn ->
          {:ok, listener} = EventListener.open(client)

          {:ok, _} =
            EventListener.add_handler(listener, [], fn _ ->
              send(parent, {:blocked, self()})

              receive do
                :never -> :ok
              end
            end)

          send(parent, {:listener, listener})

          receive do
            :send -> EventListener.send_event(listener, @event)
          end

          receive do
            :never -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
      assert_receive {:listener, listener}, 5_000
      assert {:error, %Error{kind: :owner_mismatch}} = EventListener.disconnect(listener)
      assert {:error, %Error{kind: :owner_mismatch}} = GenServer.call(listener.pid, :disconnect)
      send(owner, :send)
      assert_receive {:blocked, worker}, 1_000
      worker_monitor = Process.monitor(worker)
      listener_monitor = Process.monitor(listener.pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
      assert_receive {:DOWN, ^listener_monitor, :process, _, :normal}, 1_000
      assert_peer_closed()
    end

    test "#{transport} brutal listener loss kills even a callback trapping exits", %{root: root} do
      {client, _} = fixture(unquote(transport), root)
      {:ok, listener} = EventListener.open(client)
      parent = self()

      {:ok, _} =
        EventListener.add_handler(listener, [], fn _ ->
          Process.flag(:trap_exit, true)
          send(parent, {:trapping_callback, self()})

          receive do
            :never -> :ok
          end
        end)

      assert :ok = EventListener.send_event(listener, @event)
      assert_receive {:trapping_callback, worker}, 1_000
      monitor = Process.monitor(worker)
      Process.exit(listener.pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
      assert_peer_closed()
    end

    test "#{transport} queued final events are delivered before native EOF completes the listener",
         %{root: root} do
      {client, _} =
        fixture(unquote(transport), root, [],
          response_frames: fn _, _ ->
            Enum.map(1..3, fn index ->
              WebSocketFixture.frame(
                1,
                Jason.encode!(%{@event | "metadata" => %{"index" => index}})
              )
            end) ++ [WebSocketFixture.frame(8, <<1000::16>>)]
          end
        )

      {:ok, listener} = EventListener.open(client)
      parent = self()

      {:ok, _} =
        EventListener.add_handler(
          listener,
          [],
          &send(parent, {:tail_event, &1.data["metadata"]["index"]})
        )

      assert :ok = EventListener.send_event(listener, @event)
      for index <- 1..3, do: assert_receive({:tail_event, ^index}, 1_000)
      assert :ok = EventListener.wait(listener)
      refute EventListener.active?(listener)
      assert_peer_closed()
    end

    test "#{transport} cancellation is reported whichever context watcher ends the stream first",
         %{root: root} do
      scope = RequestContext.new!(timeout: 30_000)
      {client, _} = fixture(unquote(transport), root)
      {:ok, listener} = EventListener.open(Incus.with_context(client, scope))
      channel = :sys.get_state(listener.pid).channel

      # Stop the listener's own watcher (the one monitoring this owner), so only
      # the channel's watcher reacts and the listener sees a failed read.
      {:monitored_by, watchers} = Process.info(listener.pid, :monitored_by)

      for pid <- watchers,
          pid != channel.pid,
          {:monitors, monitors} = Process.info(pid, :monitors),
          {:process, self()} in monitors,
          do: Process.exit(pid, :kill)

      RequestContext.cancel(scope)
      assert {:error, %Error{kind: :canceled}} = EventListener.wait(listener)
      refute Process.alive?(channel.pid)
      assert_peer_closed()
    end

    test "#{transport} a slow channel reply is a local read deadline that keeps the listener and every frame",
         %{root: root} do
      {client, _} = fixture(unquote(transport), root)
      {:ok, listener} = EventListener.open(client)
      parent = self()
      {:ok, _} = EventListener.add_handler(listener, [], &send(parent, {:event, &1.data}))

      # Pause the channel beyond the listener's read bound (100 ms plus margin).
      channel = :sys.get_state(listener.pid).channel
      :sys.suspend(channel.pid)
      Process.sleep(400)
      :sys.resume(channel.pid)
      assert EventListener.active?(listener)
      assert :ok = EventListener.send_event(listener, @event)
      assert_receive {:event, event}, 2_000
      assert event["type"] == @event["type"]

      # A raw subscription reports the overrun as a deadline and still delivers the frame.
      {:ok, raw} = Events.subscribe(client)
      :sys.suspend(raw.pid)
      started = System.monotonic_time(:millisecond)
      assert {:error, %Error{kind: :deadline}} = WebSocket.recv(raw, 50)
      assert System.monotonic_time(:millisecond) - started < 1_000
      :sys.resume(raw.pid)
      assert :ok = Events.send(raw, @event)
      assert {:ok, %Model{type: "Event", data: data}} = next_event(raw, 20)
      assert data["type"] == @event["type"]
      assert :ok = Events.close(raw)
      assert_peer_closed()
      assert :ok = EventListener.disconnect(listener)
      assert_peer_closed()
    end

    test "#{transport} context cancellation and inbound byte bounds end the listener and close the peer",
         %{root: root} do
      scope = RequestContext.new!(timeout: 30_000)
      {client, _} = fixture(unquote(transport), root)
      {:ok, listener} = EventListener.open(Incus.with_context(client, scope))
      RequestContext.cancel(scope)
      assert {:error, %Error{kind: :canceled}} = EventListener.wait(listener)
      refute EventListener.active?(listener)
      assert_peer_closed()

      large = Jason.encode!(%{@event | "metadata" => %{"pad" => String.duplicate("x", 2_048)}})

      # Bytes coalesced with the 101 are bounded during negotiation.
      {client, _} =
        fixture(unquote(transport), root, [max_response_bytes: 1_024],
          wire: WebSocketFixture.frame(1, large)
        )

      assert {:error, %Error{kind: :frame_limit}} = EventListener.open(client)
      assert_peer_closed()

      # Later frames are bounded per frame and across the stream lifetime.
      for {budgets, frames, kind} <- [
            {[max_response_bytes: 1_024], 1, :overflow},
            {[max_stream_bytes: 4_096], 3, :frame_limit}
          ] do
        {client, _} =
          fixture(unquote(transport), root, budgets,
            response_frames: fn _, _ ->
              List.duplicate(WebSocketFixture.frame(1, large), frames)
            end
          )

        {:ok, listener} = EventListener.open(client)
        assert :ok = EventListener.send_event(listener, @event)
        assert {:error, %Error{kind: ^kind}} = EventListener.wait(listener)
        refute EventListener.active?(listener)
        assert_peer_closed()
      end
    end
  end

  # Every fixture reports how the client ended the stream to the test process.
  defp fixture(transport, root, budgets \\ [], opts \\ []) do
    # Unique names: TLS material is cached by path, so identities are never rewritten.
    tls =
      if transport == :https,
        do:
          TLSIdentity.generate(root, "events-#{System.unique_integer([:positive])}", "localhost")

    server =
      if tls,
        do: [
          transport: :ssl,
          certfile: tls.certfile,
          keyfile: tls.keyfile,
          peer_options: [cacertfile: tls.cafile, verify: :verify_peer, fail_if_no_peer_cert: true]
        ],
        else: [path: Path.join(root, "#{System.unique_integer([:positive])}.sock")]

    fixture =
      start_supervised!(
        {WebSocketFixture, Keyword.merge(server ++ [wire: <<>>, notify: self()], opts)},
        id: make_ref()
      )

    options = [owner: :fixture] ++ budgets

    connection =
      if tls,
        do:
          Connection.https!(
            WebSocketFixture.endpoint(fixture).url,
            options ++
              [tls: [cacertfile: tls.cafile, certfile: tls.certfile, keyfile: tls.keyfile]]
          ),
        else: Connection.unix!(WebSocketFixture.path(fixture), options)

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{}
    }

    {client, fixture}
  end

  defp native_connection(%{connection: %{transport: :unix} = connection}),
    do: %{socket: connection.address}

  # Fixture identities are self-issued, so the client certificate is also the server's.
  defp native_connection(%{connection: connection}) do
    %{
      url: URI.to_string(connection.address),
      server_cert: File.read!(connection.tls[:certfile]),
      tls_ca: File.read!(connection.tls[:cacertfile]),
      client_cert: File.read!(connection.tls[:certfile]),
      client_key: File.read!(connection.tls[:keyfile])
    }
  end

  # An outstanding read may first report its own local deadline.
  defp next_event(channel, attempts) when attempts > 0 do
    case Events.next(channel, 100) do
      {:error, %Error{kind: :deadline}} -> next_event(channel, attempts - 1)
      other -> other
    end
  end

  defp assert_peer_closed do
    assert_receive {:websocket_peer, outcome}, 5_000
    assert outcome in [:closed, :close_frame]
  end

  defp oracle(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)

      {^port, {:exit_status, status}} ->
        flunk("native event handler oracle failed #{status}: #{data}")
    after
      5_000 ->
        Port.close(port)
        flunk("native event handler oracle deadline")
    end
  end
end
