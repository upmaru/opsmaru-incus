defmodule Opsmaru.Incus.OCI.AdapterCall do
  @moduledoc false
  alias Opsmaru.Incus.{Error, WorkScope}

  # Independent controller survives caller loss to run host cleanup. No links to
  # the host tree, no replay, and no callback exception/stack/credential logging.
  def run(client, request, timeout, callback) do
    owner = self()
    id = make_ref()
    deadline = now() + timeout
    deadline = min(deadline, Map.get(request, :deadline, deadline))
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
      timeout + min(client.connection.timeout, 1_000) + 100 ->
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
    result = await(owner_monitor, worker, monitor, id, request.deadline)
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

  defp await(owner_monitor, worker, monitor, id, deadline) do
    receive do
      {^id, result} ->
        result

      {:DOWN, ^owner_monitor, :process, _, _} ->
        if now() >= deadline, do: error(:adapter_deadline), else: :owner_lost

      {:DOWN, ^monitor, :process, ^worker, _} ->
        error(:adapter_failed)
    after
      max(0, deadline - now()) -> error(:adapter_deadline)
    end
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
  defp outcome({:error, _}), do: :failed
  defp outcome(_), do: :completed
  defp error(kind), do: {:error, %Error{kind: kind}}
  defp now, do: System.monotonic_time(:millisecond)
end
