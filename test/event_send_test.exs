defmodule Opsmaru.Incus.EventSendTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Events, Server}
  alias Opsmaru.TestSupport.{TLSIdentity, WebSocketFixture}
  @driver Path.expand("../.integration/event-send-driver", __DIR__)
  @event %{"type" => "logging", "timestamp" => "2026-10-10T12:00:00Z", "metadata" => %{"x" => 1}}
  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./eventsend"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-esend-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} official SendEvent and explicit channel send agree on native JSON text frames",
         %{
           root: root
         } do
      {client, fixture} = fixture(unquote(transport), root, "native")
      assert oracle(Map.put(native_connection(client), :event, @event))["sent"]
      assert_peer_closed()
      assert_receive {:sent_event, 1, expected}, 1000
      assert Jason.decode!(expected) == @event
      assert {:ok, channel} = Events.subscribe(client)
      assert :ok = Events.send(channel, @event)
      assert_receive {:sent_event, 1, actual}, 1000
      assert Jason.decode!(actual) == Jason.decode!(expected)
      assert :ok = Events.close(channel)
      assert_peer_closed()
      # Both native and Opsmaru send one frame; no implicit global listener/replay.
      refute_receive {:sent_event, _, _}, 30

      assert Enum.count(
               WebSocketFixture.requests(fixture),
               &String.starts_with?(&1.target, "/1.0/events")
             ) == 2
    end

    test "#{transport} invalid events send nothing and frame overflow closes only the selected channel",
         %{
           root: root
         } do
      {client, _} = fixture(unquote(transport), root, "limited", max_response_bytes: 64)
      {other, _} = fixture(unquote(transport), root, "other")
      assert {:ok, channel} = Events.subscribe(client)
      assert {:ok, independent} = Events.subscribe(other)

      for event <- [nil, %{"type" => false}, %{"type" => "logging", "metadata" => self()}] do
        assert {:error, %Error{kind: :invalid_event}} = Events.send(channel, event)
      end

      refute_receive {:sent_event, _, _}, 30
      assert {:error, %Error{kind: :frame_limit}} = Events.send(channel, @event)
      assert_peer_closed()
      assert :ok = Events.send(independent, @event)
      assert_receive {:sent_event, 1, _}, 1000
      assert :ok = Events.close(independent)
      assert_peer_closed()
    end

    test "#{transport} owner death releases the listener and subsequent sends report closure", %{
      root: root
    } do
      {client, _} = fixture(unquote(transport), root, "owner", [], upgrade_delay: 150)
      parent = self()

      owner =
        spawn(fn ->
          {:ok, channel} = Events.subscribe(client)
          send(parent, {:channel, channel})

          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
      assert_receive {:channel, channel}, 5_000
      monitor = Process.monitor(channel.pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1000
      assert_peer_closed()
      assert {:error, %Error{kind: :channel_closed}} = Events.send(channel, @event)
      refute_receive {:sent_event, _, _}, 30
    end
  end

  defp fixture(transport, root, name, budgets \\ [], fixture_opts \\ []) do
    parent = self()

    # Unique names: TLS material is cached by path, so identities are never rewritten.
    tls =
      if transport == :https,
        do:
          TLSIdentity.generate(root, "#{name}-#{System.unique_integer([:positive])}", "localhost")

    server =
      if tls,
        do: [
          transport: :ssl,
          certfile: tls.certfile,
          keyfile: tls.keyfile,
          peer_options: [cacertfile: tls.cafile, verify: :verify_peer, fail_if_no_peer_cert: true]
        ],
        else: [path: Path.join(root, name <> ".sock")]

    fixture =
      start_supervised!(
        {WebSocketFixture,
         server ++
           [
             wire: <<>>,
             notify: parent,
             frame_handler: fn opcode, bytes -> send(parent, {:sent_event, opcode, bytes}) end
           ] ++ fixture_opts},
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

  defp assert_peer_closed do
    assert_receive {:websocket_peer, outcome}, 5_000
    assert outcome in [:closed, :close_frame]
  end

  defp oracle(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, out) do
    receive do
      {^port, {:data, bytes}} -> collect(port, out <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(out)
      {^port, {:exit_status, status}} -> flunk("native event send failed #{status}: #{out}")
    after
      10_000 ->
        Port.close(port)
        flunk("native event send deadline")
    end
  end
end
