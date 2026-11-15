defmodule Opsmaru.Incus.AdapterCallTest do
  use ExUnit.Case, async: true

  import Opsmaru.TestSupport.Monitor, only: [monitor!: 1]

  alias Opsmaru.Incus.{Error, RequestContext, WorkScope}
  alias Opsmaru.Incus.OCI.AdapterCall

  @timeout 5_000

  defmodule Adapter do
    def cleanup({test, workers}, id, outcome) do
      [{^id, worker}] = :ets.lookup(workers, id)
      send(test, {:cleaned, id, outcome, Process.alive?(worker)})
      :ok
    end
  end

  test "an idle adapter controller waits without scheduler wakeups until cancellation" do
    scope = RequestContext.new!(timeout: @timeout)
    call = start_call(scope)
    worker_monitor = monitor!(call.worker)

    controller = call.controller
    :erlang.trace(controller, true, [:running])
    refute_receive {:trace, ^controller, :in, _}, 100
    :erlang.trace(controller, false, [:running])

    assert :ok = RequestContext.cancel(scope)
    worker = call.worker
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout
    assert_result(call, {:error, %Error{kind: :adapter_canceled}})
    assert_cleanup(call, :canceled)
  end

  for {first, outcome, result} <- [
        {:result, :completed, :ok},
        {:cancel, :canceled, {:error, %Error{kind: :adapter_canceled}}}
      ] do
    test "a queued #{first} wins against the other adapter outcome" do
      scope = RequestContext.new!(timeout: @timeout)
      call = start_call(scope)

      # Both events are already in the controller's mailbox when it resumes.
      assert :erlang.suspend_process(call.controller)

      case unquote(first) do
        :result ->
          release_result(call)
          cancel(scope, call)

        :cancel ->
          cancel(scope, call)
          release_result(call)
      end

      assert :erlang.resume_process(call.controller)
      assert_result(call, unquote(Macro.escape(result)))
      assert_cleanup(call, unquote(outcome))
    end
  end

  test "caller loss still owns cleanup when the caller also owns its context" do
    call = start_call(:caller_owned)
    worker_monitor = monitor!(call.worker)
    Process.exit(call.caller, :kill)

    worker = call.worker
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, @timeout
    assert_cleanup(call, :owner_lost)
  end

  defp start_call(scope) do
    test = self()
    workers = :ets.new(__MODULE__, [:public])

    caller =
      spawn(fn ->
        scope = if scope == :caller_owned, do: RequestContext.new!(timeout: @timeout), else: scope

        client = %{
          connection: %{request_context: scope, queue_limit: 4, timeout: @timeout},
          adapter: Adapter,
          config: {test, workers}
        }

        result =
          AdapterCall.run(client, %{}, @timeout, fn %{call_id: id} ->
            Process.flag(:trap_exit, true)
            worker = self()
            {table, _} = WorkScope.current()
            controller = :ets.info(table, :owner)
            true = :ets.insert(workers, {id, worker})
            send(test, {:adapter_entered, controller, worker, id})

            receive do
              :complete -> :ok
            end
          end)

        send(test, {:adapter_result, self(), result})
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:adapter_entered, controller, worker, id}, @timeout
    on_exit(fn -> Process.exit(controller, :kill) end)
    monitor = monitor!(controller)
    await_controller(controller, System.monotonic_time(:millisecond) + @timeout)
    %{caller: caller, controller: controller, worker: worker, id: id, monitor: monitor}
  end

  defp await_controller(controller, deadline) do
    case Process.info(controller, [:status, :current_function]) do
      [status: :waiting, current_function: {AdapterCall, :await_result, 6}] ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(1)
        await_controller(controller, deadline)
    end
  end

  defp cancel(scope, call) do
    assert :ok = RequestContext.cancel(scope)

    await_message(call.controller, fn message ->
      match?({:request_context_terminal, _}, message)
    end)
  end

  defp release_result(%{worker: worker, controller: controller, id: id}) do
    send(worker, :complete)
    await_message(controller, fn message -> message == {id, :ok} end)
  end

  defp await_message(controller, match) do
    await_message(controller, match, System.monotonic_time(:millisecond) + @timeout)
  end

  defp await_message(controller, match, deadline) do
    {:messages, messages} = Process.info(controller, :messages)

    unless Enum.any?(messages, match) do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      await_message(controller, match, deadline)
    end
  end

  defp assert_result(%{caller: caller}, expected) do
    assert_receive {:adapter_result, ^caller, result}, @timeout

    case expected do
      {:error, %Error{kind: kind}} -> assert {:error, %Error{kind: ^kind}} = result
      :ok -> assert result == :ok
    end
  end

  defp assert_cleanup(%{id: id, controller: controller, monitor: monitor}, outcome) do
    assert_receive {:cleaned, ^id, ^outcome, false}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, @timeout
    refute_received {:cleaned, ^id, _, _}
  end
end
