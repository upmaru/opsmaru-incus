defmodule Opsmaru.Incus.TransportWatcherTest do
  use ExUnit.Case, async: false

  import Opsmaru.TestSupport.Monitor, only: [monitor!: 1]
  alias Opsmaru.Incus.{RequestContext, Transport}
  alias Opsmaru.Incus.RequestContext.Notifier

  @timeout 5_000

  for mode <- [:monitor_only, :scoped, :shared_owner] do
    test "#{mode} watcher gives a blocked channel at least 100 ms after opener exit" do
      owner = idle_owner()
      context = context(unquote(mode), owner)
      {worker, watcher} = start_channel(owner, context)
      assert_idle(watcher, owner, worker, context)
      worker_monitor = monitor!(worker)

      started = System.monotonic_time(:microsecond)
      send(owner, :stop)

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout
      assert System.monotonic_time(:microsecond) - started >= 100_000
    end
  end

  test "the opener can close normally inside the grace period" do
    owner = idle_owner()
    context = context(:shared_owner, owner)
    parent = self()

    {worker, watcher} =
      start_channel(owner, context, fn ->
        ref = Process.monitor(owner)

        receive do
          {:DOWN, ^ref, :process, ^owner, :normal} -> send(parent, :graceful_close)
        end
      end)

    assert_idle(watcher, owner, worker, context)
    worker_monitor = monitor!(worker)
    watcher_monitor = monitor!(watcher)
    send(owner, :stop)

    assert_receive :graceful_close, @timeout
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, @timeout
    assert_receive {:DOWN, ^watcher_monitor, :process, ^watcher, :normal}, @timeout
  end

  test "a scoped watcher sleeps until cancel and releases its subscription" do
    owner = idle_owner()
    context = context(:scoped, owner)
    {worker, watcher} = start_channel(owner, context)
    notifier = assert_idle(watcher, owner, worker, context)
    worker_monitor = monitor!(worker)
    watcher_monitor = monitor!(watcher)
    notifier_monitor = monitor!(notifier)

    assert :ok = RequestContext.cancel(context)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout
    assert_receive {:DOWN, ^watcher_monitor, :process, ^watcher, :normal}, @timeout
    assert_receive {:DOWN, ^notifier_monitor, :process, ^notifier, :normal}, @timeout
    assert RequestContext.status(context) == :canceled
    assert Process.alive?(owner)
  end

  test "a replacement notifier keeps the original channel deadline" do
    owner = idle_owner()
    context = RequestContext.new!(timeout: 1_000)
    {worker, watcher} = start_channel(owner, context)
    notifier = waiting_on(watcher, owner, worker, context)
    worker_monitor = monitor!(worker)
    Process.exit(notifier, :kill)

    replacement = waiting_on(watcher, owner, worker, context, notifier)
    refute replacement == notifier
    assert Process.alive?(worker)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout
    assert System.monotonic_time(:millisecond) >= context.deadline
    assert RequestContext.status(context) == :deadline
  end

  defp idle_owner do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp context(:monitor_only, _owner), do: nil
  defp context(:scoped, _owner), do: RequestContext.new!(timeout: @timeout)
  defp context(:shared_owner, owner), do: RequestContext.new!(timeout: @timeout, owner: owner)

  defp start_channel(owner, context, run \\ fn -> receive do: (:never -> :ok) end) do
    parent = self()

    worker =
      spawn(fn ->
        watcher = Transport.watch_owner(owner, context)
        send(parent, {:watching, self(), watcher})
        run.()
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:watching, ^worker, watcher}, @timeout
    on_exit(fn -> Process.exit(watcher, :kill) end)
    {worker, watcher}
  end

  defp assert_idle(watcher, owner, worker, context) do
    notifier = waiting_on(watcher, owner, worker, context)
    :erlang.trace(watcher, true, [:running])
    refute_receive {:trace, ^watcher, :in, _}, 100
    :erlang.trace(watcher, false, [:running])
    notifier
  end

  defp waiting_on(watcher, owner, worker, context, previous \\ nil) do
    deadline = System.monotonic_time(:millisecond) + @timeout

    await(deadline, fn ->
      notifier = if context, do: Process.whereis(Notifier)
      expected = for pid <- [owner, worker, notifier], is_pid(pid), do: {:process, pid}

      case Process.info(watcher, [:current_function, :status, :monitors]) do
        [current_function: {Transport, :watch_until, 4}, status: :waiting, monitors: monitors] ->
          if Enum.sort(monitors) == Enum.sort(expected) and
               (is_nil(context) or (is_pid(notifier) and notifier != previous)),
             do: {:ok, notifier}

        _ ->
          nil
      end
    end)
  end

  defp await(deadline, fun) do
    case fun.() do
      {:ok, result} ->
        result

      nil ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(1)
        await(deadline, fun)
    end
  end
end
