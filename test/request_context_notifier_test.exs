defmodule Opsmaru.Incus.RequestContextNotifierTest do
  # The notifier is registered once per VM. Barriers pause only that process.
  use ExUnit.Case, async: false

  alias Opsmaru.Incus.RequestContext
  alias Opsmaru.Incus.RequestContext.Notifier

  @receive_timeout 5_000

  setup do
    on_exit(fn ->
      if pid = Process.whereis(Notifier) do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, @receive_timeout
      end
    end)
  end

  test "construction and cancellation before registration allocate no subscription resources" do
    owner = idle_process()
    test = self()

    creator =
      idle_process(fn ->
        send(test, {:context, RequestContext.new!(timeout: 60_000, owner: owner)})
      end)

    assert_receive {:context, context}, @receive_timeout
    assert :ok = RequestContext.validate!(context) |> RequestContext.check()
    assert Process.whereis(Notifier) == nil

    stop(owner)
    assert Process.alive?(creator)
    assert RequestContext.status(context) == :canceled
    assert {:error, :canceled} = RequestContext.subscribe(context)
    assert Process.whereis(Notifier) == nil

    canceled = RequestContext.new!(timeout: 60_000)
    assert :ok = RequestContext.cancel(canceled)
    assert {:error, :canceled} = RequestContext.subscribe(canceled)
    assert Process.whereis(Notifier) == nil
  end

  test "creator exit keeps the subscription usable and owner exit reclaims it" do
    owner = idle_process()

    context =
      Task.async(fn -> RequestContext.new!(timeout: 60_000, owner: owner) end) |> Task.await()

    {notifier, ref} = subscribe!(context)
    assert RequestContext.status(context) == :active

    stop(owner)
    assert_receive {:request_context_terminal, ^ref}, @receive_timeout
    assert {:error, :canceled} = RequestContext.check(context)
    assert_receive {:DOWN, ^ref, :process, ^notifier, :normal}, @receive_timeout
    assert :ok = RequestContext.unsubscribe({notifier, ref})
    assert Process.whereis(Notifier) == nil
  end

  test "owner exit reclaims records while a distinct creator is still alive" do
    owner = idle_process()
    test = self()

    creator =
      idle_process(fn ->
        send(test, {:context, RequestContext.new!(timeout: 60_000, owner: owner)})
      end)

    assert_receive {:context, context}, @receive_timeout
    {notifier, ref} = subscription = subscribe!(context)
    stop(owner)

    assert_receive {:request_context_terminal, ^ref}, @receive_timeout
    assert_receive {:DOWN, ^ref, :process, ^notifier, :normal}, @receive_timeout
    assert Process.alive?(creator)
    assert {:error, :canceled} = RequestContext.check(context)
    assert :ok = RequestContext.unsubscribe(subscription)
  end

  test "registration rechecks a terminal transition committed before it is handled" do
    {_, unrelated_ref} = unrelated = subscribe!(RequestContext.new!(timeout: 60_000))
    notifier = Process.whereis(Notifier)
    context = RequestContext.new!(timeout: 60_000)

    barrier =
      barrier(notifier, fn
        {:in, {:"$gen_call", _, {:subscribe, _, _, _}}} -> true
        _ -> false
      end)

    waiter = Task.async(fn -> RequestContext.subscribe(context) end)
    assert_receive {^barrier, _}, @receive_timeout
    assert :ok = RequestContext.cancel(context)
    send(notifier, {barrier, :continue})

    assert {:error, :canceled} = Task.await(waiter, @receive_timeout)
    assert map_size(:sys.get_state(notifier).contexts) == 1
    refute_received {:request_context_terminal, ^unrelated_ref}
    assert :ok = RequestContext.unsubscribe(unrelated)
  end

  test "cancellation during registration resolves both the existing and registering waiters" do
    context = RequestContext.new!(timeout: 60_000)
    {notifier, ref} = existing = subscribe!(context)

    barrier =
      barrier(notifier, fn
        {:in, {:"$gen_call", _, {:transition, _, _}}} -> true
        _ -> false
      end)

    caller = Task.async(fn -> RequestContext.cancel(context) end)
    assert_receive {^barrier, _}, @receive_timeout

    waiter = Task.async(fn -> RequestContext.subscribe(context) end)
    waiting_call(notifier, :subscribe)
    send(notifier, {barrier, :continue})

    assert :ok = Task.await(caller, @receive_timeout)
    assert {:error, :canceled} = Task.await(waiter, @receive_timeout)
    assert_receive {:request_context_terminal, ^ref}, @receive_timeout
    assert :ok = RequestContext.unsubscribe(existing)
    refute_received {:request_context_terminal, ^ref}
  end

  test "a cancel caller can die before the notifier commits the enqueued transition" do
    context = RequestContext.new!(timeout: 60_000)
    {notifier, ref} = subscription = subscribe!(context)

    barrier =
      barrier(notifier, fn
        {:in, {:"$gen_call", _, {:transition, _, _}}} -> true
        _ -> false
      end)

    caller = idle_process(fn -> RequestContext.cancel(context) end)
    assert_receive {^barrier, _}, @receive_timeout
    assert RequestContext.status(context) == :active
    stop(caller)
    send(notifier, {barrier, :continue})

    assert_receive {:request_context_terminal, ^ref}, @receive_timeout
    assert RequestContext.status(context) == :canceled
    assert :ok = RequestContext.unsubscribe(subscription)
  end

  test "cancel caller exit after commit does not stop delivery" do
    context = RequestContext.new!(timeout: 60_000)
    {notifier, ref} = subscription = subscribe!(context)
    barrier = barrier(notifier, &match?({:out, :ok, _, _}, &1))

    caller = idle_process(fn -> RequestContext.cancel(context) end)
    assert_receive {^barrier, _}, @receive_timeout
    assert RequestContext.status(context) == :canceled
    refute_received {:request_context_terminal, ^ref}
    stop(caller)
    send(notifier, {barrier, :continue})

    assert_receive {:request_context_terminal, ^ref}, @receive_timeout
    assert :ok = RequestContext.unsubscribe(subscription)
  end

  for {label, phase, expected} <- [
        {"before fanout", :before, 0},
        {"during fanout", :during, 1}
      ] do
    test "notifier exit #{label} wakes all waiters with one terminal outcome" do
      context = RequestContext.new!(timeout: 60_000)
      subscriptions = for _ <- 1..3, do: subscribe!(context)
      notifier = Process.whereis(Notifier)
      barrier = barrier(notifier, &delivery_phase?(&1, unquote(phase)))

      assert :ok = RequestContext.cancel(context)
      assert_receive {^barrier, _}, @receive_timeout
      assert RequestContext.status(context) == :canceled

      monitor = Process.monitor(notifier)
      stop(notifier)
      assert_receive {:DOWN, ^monitor, :process, ^notifier, :killed}, @receive_timeout

      notifications =
        for {^notifier, ref} = subscription <- subscriptions do
          # Both signals can be queued. The waiter reports one outcome and drops
          # the other signal during teardown.
          assert_receive {:DOWN, ^ref, :process, ^notifier, :killed}, @receive_timeout
          assert {:error, :canceled} = RequestContext.check(context)
          delivered = queued?(ref)
          assert :ok = RequestContext.unsubscribe(subscription)
          refute_received {:request_context_terminal, ^ref}
          delivered
        end

      assert Enum.count(notifications, & &1) == unquote(expected)
      assert Process.whereis(Notifier) == nil
    end
  end

  test "a starter that exits before registration leaves only a bounded empty notifier" do
    {:ok, notifier} = GenServer.start(Notifier, nil, name: Notifier)
    monitor = Process.monitor(notifier)
    assert_receive {:DOWN, ^monitor, :process, ^notifier, :normal}, @receive_timeout
    assert Process.whereis(Notifier) == nil
  end

  test "an active waiter can register again after notifier loss" do
    context = RequestContext.new!(timeout: 60_000)
    {notifier, ref} = subscription = subscribe!(context)
    stop(notifier)
    assert_receive {:DOWN, ^ref, :process, ^notifier, :killed}, @receive_timeout
    assert RequestContext.status(context) == :active
    assert :ok = RequestContext.unsubscribe(subscription)

    {replacement, new_ref} = next_subscription = subscribe!(context)
    assert notifier != replacement
    assert :ok = RequestContext.cancel(context)
    assert_receive {:request_context_terminal, ^new_ref}, @receive_timeout
    assert :ok = RequestContext.unsubscribe(next_subscription)
  end

  test "concurrent cancellation sends one notice and preserves the first terminal kind" do
    context = RequestContext.new!(timeout: 60_000)
    {notifier, ref} = subscription = subscribe!(context)
    gate = make_ref()
    test = self()

    callers =
      for _ <- 1..8 do
        Task.async(fn ->
          send(test, {gate, :ready})

          receive do
            ^gate -> RequestContext.cancel(context)
          end
        end)
      end

    for _ <- callers, do: assert_receive({^gate, :ready}, @receive_timeout)
    for task <- callers, do: send(task.pid, gate)
    assert Task.await_many(callers, @receive_timeout) == List.duplicate(:ok, 8)
    assert_receive {:request_context_terminal, ^ref}, @receive_timeout
    assert_receive {:DOWN, ^ref, :process, ^notifier, :normal}, @receive_timeout
    refute_received {:request_context_terminal, ^ref}

    expired_copy = %{context | deadline: System.monotonic_time(:millisecond)}
    assert RequestContext.status(expired_copy) == :canceled
    assert :ok = RequestContext.unsubscribe(subscription)
  end

  test "an observed deadline on a tightened copy wins before owner loss and preserves the original's state" do
    owner = idle_process()
    context = RequestContext.new!(timeout: 60_000, owner: owner)
    {notifier, ref} = subscription = subscribe!(context)
    expired_copy = %{context | deadline: System.monotonic_time(:millisecond)}
    :ok = :sys.suspend(notifier)
    stop(owner)

    observer = Task.async(fn -> RequestContext.status(expired_copy) end)
    waiting_call(notifier, :transition)
    :ok = :sys.resume(notifier)

    assert Task.await(observer, @receive_timeout) == :deadline
    assert :ok = RequestContext.cancel(context)
    assert {:error, :deadline} = RequestContext.check(context)
    assert_receive {:request_context_terminal, ^ref}, @receive_timeout
    assert :ok = RequestContext.unsubscribe(subscription)
  end

  test "completed and abandoned waits release their records and monitors" do
    context = RequestContext.new!(timeout: 60_000)
    {notifier, ref} = subscription = subscribe!(context)
    monitor = Process.monitor(notifier)

    assert :ok = RequestContext.unsubscribe(subscription)
    assert_receive {:DOWN, ^monitor, :process, ^notifier, :normal}, @receive_timeout
    refute_received {:DOWN, ^ref, :process, _, _}
    assert RequestContext.status(context) == :active

    test = self()

    waiter =
      idle_process(fn ->
        send(test, {:subscribed, subscribe!(context)})
      end)

    assert_receive {:subscribed, {replacement, _}}, @receive_timeout
    monitor = Process.monitor(replacement)
    stop(waiter)
    assert_receive {:DOWN, ^monitor, :process, ^replacement, :normal}, @receive_timeout
    assert RequestContext.status(context) == :active
  end

  test "cancellation queued after the last waiter leaves still commits" do
    context = RequestContext.new!(timeout: 60_000)
    {notifier, _} = subscription = subscribe!(context)
    monitor = Process.monitor(notifier)
    :ok = :sys.suspend(notifier)
    :ok = RequestContext.unsubscribe(subscription)

    caller = Task.async(fn -> RequestContext.cancel(context) end)
    waiting_call(notifier, :transition)
    :ok = :sys.resume(notifier)

    assert :ok = Task.await(caller, @receive_timeout)
    assert RequestContext.status(context) == :canceled
    assert_receive {:DOWN, ^monitor, :process, ^notifier, :normal}, @receive_timeout
  end

  test "teardown drains a queued notification and drops delivery after deactivation" do
    other_process = idle_process()
    other_monitor = Process.monitor(other_process)
    context = RequestContext.new!(timeout: 60_000)
    {notifier, ref} = subscription = subscribe!(context)
    unrelated = make_ref()
    send(self(), {:request_context_terminal, unrelated})

    barrier = barrier(notifier, &match?({:out, :ok, _, _}, &1))
    assert :ok = RequestContext.cancel(context)
    assert_receive {^barrier, _}, @receive_timeout

    # Use a separate sender to force one notification into the mailbox
    # before teardown, then release the notifier to attempt a late send.
    send(ref, {:request_context_terminal, ref})
    assert queued?(ref)
    monitor = Process.monitor(notifier)
    assert :ok = RequestContext.unsubscribe(subscription)
    send(notifier, {barrier, :continue})

    assert_receive {:DOWN, ^monitor, :process, ^notifier, :normal}, @receive_timeout
    assert_received {:request_context_terminal, ^unrelated}
    refute_received {:request_context_terminal, ^ref}
    refute_received {:DOWN, ^ref, :process, _, _}

    stop(other_process)
    assert_receive {:DOWN, ^other_monitor, :process, ^other_process, :killed}, @receive_timeout
  end

  defp queued?(ref) do
    {:messages, messages} = Process.info(self(), :messages)
    {:request_context_terminal, ref} in messages
  end

  defp subscribe!(context) do
    assert {:ok, subscription} = RequestContext.subscribe(context)
    subscription
  end

  defp idle_process(start \\ fn -> :ok end) do
    pid =
      spawn(fn ->
        start.()

        receive do
          run when is_function(run, 0) -> run.()
        end

        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, @receive_timeout
  end

  defp delivery_phase?({:out, :ok, _, _}, :before), do: true
  defp delivery_phase?({:continue, {:notify, [_ | _]}}, :during), do: true
  defp delivery_phase?(_, _), do: false

  defp barrier(notifier, match) do
    test = self()
    ref = make_ref()

    :ok =
      :sys.install(
        notifier,
        {fn state, event, _ ->
           if match.(event) do
             send(test, {ref, event})
             receive do: ({^ref, :continue} -> :done)
             :done
           else
             state
           end
         end, nil}
      )

    ref
  end

  defp waiting_call(pid, operation) do
    deadline = System.monotonic_time(:millisecond) + @receive_timeout

    wait_until(deadline, fn ->
      {:messages, messages} = Process.info(pid, :messages)

      Enum.any?(messages, fn
        {:"$gen_call", _, command} -> elem(command, 0) == operation
        _ -> false
      end)
    end)
  end

  defp wait_until(deadline, check) do
    unless check.() do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      wait_until(deadline, check)
    end
  end
end
