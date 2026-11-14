defmodule Opsmaru.Incus.TransportGuardTest do
  use ExUnit.Case, async: false

  import Opsmaru.TestSupport.Monitor, only: [monitor!: 1]

  alias Opsmaru.Incus.{Error, RequestContext, Transport}
  alias Opsmaru.Incus.RequestContext.Notifier

  @timeout 5_000

  test "a subscribed guard sleeps until cancellation and releases its subscription" do
    context = RequestContext.new!(timeout: @timeout)
    {caller, worker, guard} = blocked_request(context, @timeout)
    notifier = registered_notifier(guard)
    worker_monitor = monitor!(worker)
    guard_monitor = monitor!(guard)
    notifier_monitor = monitor!(notifier)

    :erlang.trace(guard, true, [:running])
    refute_receive {:trace, ^guard, :in, _}, 100
    :erlang.trace(guard, false, [:running])

    assert :ok = RequestContext.cancel(context)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout
    assert_receive {:result, ^caller, {:error, %Error{kind: :canceled}}}, @timeout
    assert_receive {:DOWN, ^guard_monitor, :process, ^guard, :normal}, @timeout
    assert_receive {:DOWN, ^notifier_monitor, :process, ^notifier, :normal}, @timeout
  end

  test "loss of the notifier resubscribes an active guard" do
    context = RequestContext.new!(timeout: 30_000)
    {caller, worker, guard} = blocked_request(context, @timeout)
    notifier = registered_notifier(guard)
    worker_monitor = monitor!(worker)
    Process.exit(notifier, :kill)

    replacement = registered_notifier(guard, notifier)
    assert Process.alive?(replacement)
    assert Process.alive?(worker)
    assert :ok = RequestContext.cancel(context)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout
    assert_receive {:result, ^caller, {:error, %Error{kind: :canceled}}}, @timeout
  end

  test "the local deadline kills the worker while the caller cannot run" do
    context = RequestContext.new!(timeout: 30_000)
    {caller, worker, guard} = blocked_request(context, 1_000)
    registered_notifier(guard)
    worker_monitor = monitor!(worker)

    true = :erlang.suspend_process(caller)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout
    true = :erlang.resume_process(caller)
    assert_receive {:result, ^caller, {:error, %Error{kind: :deadline}}}, @timeout
    assert RequestContext.status(context) == :active
  end

  test "a distinct context owner ending cancels the request", do: assert_owner_loss(:context)

  test "caller exit kills the worker without cancelling the shared context",
    do: assert_owner_loss(:caller)

  defp assert_owner_loss(kind) do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    context = RequestContext.new!(timeout: @timeout, owner: owner)
    {caller, worker, guard} = blocked_request(context, @timeout)
    registered_notifier(guard)
    worker_monitor = monitor!(worker)

    case kind do
      :context -> send(owner, :stop)
      :caller -> Process.exit(caller, :kill)
    end

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout

    case kind do
      :context ->
        assert_receive {:result, ^caller, {:error, %Error{kind: :canceled}}}, @timeout

      :caller ->
        assert RequestContext.status(context) == :active
        refute_received {:result, ^caller, _}
    end
  end

  defp blocked_request(context, timeout) do
    parent = self()

    caller =
      spawn(fn ->
        receive do
          :start ->
            result =
              Transport.bounded(
                timeout,
                "GET",
                fn ->
                  send(parent, {:entered, self()})
                  receive do: (:never -> :ok)
                end,
                context
              )

            send(parent, {:result, self(), result})
        end
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    :erlang.trace(caller, true, [:procs, :set_on_spawn])
    send(caller, :start)
    assert_receive {:trace, ^caller, :spawn, worker, _}, @timeout
    assert_receive {:trace, ^worker, :spawn, guard, _}, @timeout
    assert_receive {:entered, ^worker}, @timeout
    for pid <- [caller, worker, guard], do: :erlang.trace(pid, false, [:procs, :set_on_spawn])
    {caller, worker, guard}
  end

  defp registered_notifier(guard, previous \\ nil) do
    until = System.monotonic_time(:millisecond) + @timeout
    await_guard(guard, previous, until)
  end

  defp await_guard(guard, previous, until) do
    notifier = Process.whereis(Notifier)

    if is_pid(notifier) and notifier != previous and waiting?(guard, notifier) do
      notifier
    else
      assert System.monotonic_time(:millisecond) < until
      Process.sleep(1)
      await_guard(guard, previous, until)
    end
  end

  defp waiting?(guard, notifier) do
    case Process.info(guard, [:current_function, :status, :monitors]) do
      [current_function: {Transport, :guard_until, 5}, status: :waiting, monitors: monitors] ->
        {:process, notifier} in monitors

      _ ->
        false
    end
  end
end
