defmodule Opsmaru.Incus.EventListenerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, EventListener, Model, Server}
  alias Opsmaru.TestSupport.WebSocketFixture
  @driver Path.expand("../../.integration/event-handlers-driver", __DIR__)
  @event %{"type" => "logging", "timestamp" => "2026-10-11T12:00:00Z", "metadata" => %{}}

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./eventhandlers"],
        cd: Path.expand("../reference", __DIR__),
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

  test "handler registration/removal, native callback data and repeatable wait match pinned listener",
       %{root: root} do
    {client, fixture} = fixture(root)
    expected = oracle(%{socket: client.connection.address, event: @event})
    assert {:ok, listener} = EventListener.open(client)
    assert EventListener.active?(listener) == expected["active_before"]
    parent = self()

    assert {:ok, _} =
             EventListener.add_handler(listener, ["logging"], &send(parent, {:event, &1}))

    assert {:ok, removed} = EventListener.add_handler(listener, [], &send(parent, {:removed, &1}))
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

    assert Enum.count(
             WebSocketFixture.requests(fixture),
             &String.starts_with?(&1.target, "/1.0/events")
           ) == 2
  end

  test "filters, capacity and targets are isolated between explicit listeners", %{root: root} do
    {client, _} = fixture(root, queue_limit: 2)
    {:ok, first} = EventListener.open(client)
    {:ok, second} = EventListener.open(client)
    parent = self()
    {:ok, target} = EventListener.add_handler(first, ["logging"], &send(parent, {:selected, &1}))
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
    assert :ok = EventListener.disconnect(second)
  end

  test "local wait timeout leaves a live subscription active and sends no backend cancellation",
       %{root: root} do
    {client, fixture} = fixture(root)
    {:ok, listener} = EventListener.open(client)
    assert {:error, %Error{kind: :deadline}} = EventListener.wait(listener, 5)
    assert EventListener.active?(listener)
    assert {:error, %Error{kind: :invalid_listener_wait}} = EventListener.wait(listener, 0)
    assert :ok = EventListener.disconnect(listener)
    assert :ok = EventListener.wait(listener)
    assert Enum.all?(WebSocketFixture.requests(fixture), &(&1.method == "GET"))
  end

  test "callback exceptions are redacted and release the socket, without damaging another listener",
       %{root: root} do
    {client, _} = fixture(root)
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
    assert EventListener.active?(independent)
    assert :ok = EventListener.disconnect(independent)
  end

  test "blocked callback is killed within its budget and result remains repeatable", %{root: root} do
    {client, _} = fixture(root, timeout: 100)
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
  end

  test "native EOF, malformed events and lifetime terminate the local listener", %{root: root} do
    for {opts, budgets, expected} <- [
          {[close_after: 150], [], :ok},
          {[wire: WebSocketFixture.frame(1, "bad")], [], :invalid_event},
          {[], [stream_timeout: 150], :deadline}
        ] do
      {client, _} = fixture(root, budgets, opts)
      assert {:ok, listener} = EventListener.open(client)

      if expected == :ok,
        do: assert(:ok == EventListener.wait(listener)),
        else: assert({:error, %Error{kind: expected}} == EventListener.wait(listener))

      refute EventListener.active?(listener)
    end
  end

  test "owner loss kills an active callback and raw process calls cannot bypass owner binding", %{
    root: root
  } do
    {client, _} = fixture(root)
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
  end

  test "brutal listener loss kills even a callback trapping exits", %{root: root} do
    {client, _} = fixture(root)
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
  end

  defp fixture(root, budgets \\ [], opts \\ []) do
    fixture =
      start_supervised!(
        {WebSocketFixture,
         Keyword.merge(
           [path: Path.join(root, "#{System.unique_integer([:positive])}.sock"), wire: <<>>],
           opts
         )},
        id: make_ref()
      )

    client = %Incus{
      connection: Connection.unix!(WebSocketFixture.path(fixture), [owner: :fixture] ++ budgets),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{}
    }

    {client, fixture}
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
