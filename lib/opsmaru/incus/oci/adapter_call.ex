defmodule Opsmaru.Incus.OCI.AdapterCall do
  @moduledoc false
  alias Opsmaru.Incus.{Error, RequestContext, WorkScope}

  # Independent controller survives caller loss to run host cleanup. No links to
  # the host tree, no replay, and no callback exception/stack/credential logging.
  def run(client, request, timeout, callback) do
    owner = self()
    id = make_ref()
    deadline = now() + timeout
    deadline = min(deadline, Map.get(request, :deadline, deadline))
    deadline = RequestContext.deadline(client.connection.request_context, deadline)
    request = Map.merge(request, %{call_id: id, deadline: deadline})

    {pid, monitor} =
      spawn_monitor(fn -> control(owner, id, client, request, callback) end)

    receive do
      {^id, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        error(:adapter_failed)
    after
      max(0, deadline - now()) + min(client.connection.timeout, 1_000) + 100 ->
        Process.demonitor(monitor, [:flush])
        # Keep the independent controller alive: cleanup must wait for actual
        # worker termination, even if host callback code is still unkillable.
        {:error, %Error{kind: :adapter_cleanup, response: %{call_id: id, cleanup_pending: true}}}
    end
  end

  defp control(owner, id, client, request, callback) do
    owner_monitor = Process.monitor(owner)
    controller = self()
    scope = WorkScope.new(client.connection.queue_limit)

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :start ->
            WorkScope.bind(scope)
            send(controller, {id, safely(callback, request)})
        end
      end)

    watchdog(controller, worker)
    :ok = WorkScope.register(scope, worker)
    send(worker, :start)

    result =
      await(
        {owner, owner_monitor},
        worker,
        monitor,
        id,
        request.deadline,
        client.connection.request_context
      )

    WorkScope.stop(scope)
    WorkScope.close(scope)
    Process.demonitor(monitor, [:flush])
    outcome = outcome(result)

    cleanup =
      clean(client, id, outcome, min(client.connection.timeout, 1_000))

    if result != :owner_lost do
      result =
        if cleanup == :ok,
          do: result,
          else: {:error, %Error{kind: :adapter_cleanup, response: result}}

      send(owner, {id, result})
    end
  end

  defp await(caller, worker, monitor, id, deadline, nil) do
    await_result(caller, worker, monitor, id, deadline, {nil, nil})
  end

  defp await({owner, _} = caller, worker, monitor, id, deadline, context) do
    case RequestContext.subscribe(context) do
      {:ok, subscription} ->
        case await_context(caller, worker, monitor, id, deadline, subscription) do
          :context_changed -> await(caller, worker, monitor, id, deadline, context)
          result -> result
        end

      {:error, :canceled} ->
        # The notifier and caller monitor can observe the same exit in either
        # order. Keep caller-loss cleanup when the context belongs to that caller.
        if context.owner == owner and not Process.alive?(owner),
          do: caller_down(deadline),
          else: error(:adapter_canceled)

      {:error, :deadline} ->
        error(:adapter_deadline)
    end
  end

  defp await_context(caller, worker, monitor, id, deadline, subscription) do
    await_result(caller, worker, monitor, id, deadline, subscription)
  after
    RequestContext.unsubscribe(subscription)
  end

  defp await_result({owner, owner_monitor}, worker, monitor, id, deadline, {notifier, notice}) do
    receive do
      {^id, result} -> result
      {:DOWN, ^owner_monitor, :process, ^owner, _} -> caller_down(deadline)
      {:DOWN, ^monitor, :process, ^worker, _} -> error(:adapter_failed)
      {:request_context_terminal, ^notice} -> :context_changed
      {:DOWN, ^notice, :process, ^notifier, _} -> :context_changed
    after
      max(0, deadline - now()) -> error(:adapter_deadline)
    end
  end

  defp caller_down(deadline) do
    if now() >= deadline, do: error(:adapter_deadline), else: :owner_lost
  end

  defp clean(client, id, outcome, timeout) do
    controller = self()
    ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result = safely(fn _ -> client.adapter.cleanup(client.config, id, outcome) end, nil)
        send(controller, {ref, result})
      end)

    watchdog(controller, worker)

    result =
      receive do
        {^ref, :ok} -> :ok
        {^ref, _} -> :error
        {:DOWN, ^monitor, :process, ^worker, _} -> :error
      after
        timeout -> :error
      end

    Process.exit(worker, :kill)
    Process.demonitor(monitor, [:flush])
    result
  end

  defp watchdog(controller, worker) do
    spawn(fn ->
      controller_monitor = Process.monitor(controller)
      worker_monitor = Process.monitor(worker)

      receive do
        {:DOWN, ^controller_monitor, :process, _, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_monitor, :process, _, _} -> :ok
      end
    end)
  end

  defp safely(callback, request) do
    callback.(request)
  rescue
    _ -> error(:adapter_failed)
  catch
    _, _ -> error(:adapter_failed)
  end

  defp outcome(:owner_lost), do: :owner_lost
  defp outcome({:error, %Error{kind: :adapter_deadline}}), do: :deadline
  defp outcome({:error, %Error{kind: :adapter_canceled}}), do: :canceled
  defp outcome({:error, _}), do: :failed
  defp outcome(_), do: :completed
  defp error(kind), do: {:error, %Error{kind: kind}}
  defp now, do: System.monotonic_time(:millisecond)
end
