defmodule Opsmaru.Incus.RequestContext.Notifier do
  @moduledoc false
  use GenServer

  alias Opsmaru.Incus.RequestContext

  # The same cell serializes the first registration with terminal transitions.
  @unsubscribed 0
  @subscribed 3
  # Reclaim an empty notifier if its starter dies before sending registration.
  @registration_timeout 1_000

  def subscribe(context) do
    case RequestContext.status(context) do
      :active -> subscribe_active(context)
      kind -> {:error, kind}
    end
  end

  def unsubscribe({notifier, notification}) do
    Process.demonitor(notification, [:flush])
    drain(notification)
    GenServer.cast(notifier, {:unsubscribe, notification})
    :ok
  end

  def transition(cell, kind) do
    case :atomics.compare_exchange(cell, 1, @unsubscribed, kind) do
      @subscribed -> transition_subscribed(cell, kind)
      _ -> :ok
    end
  end

  defp subscribe_active(context) do
    notifier = start()
    notification = :erlang.monitor(:process, notifier, [{:alias, :demonitor}])
    subscription = {notifier, notification}

    case call(notifier, {:subscribe, context.cancelled, context.owner, notification}) do
      :ok ->
        case RequestContext.status(context) do
          :active -> {:ok, subscription}
          kind -> reject(subscription, kind)
        end

      :terminal ->
        reject(subscription, RequestContext.status(context))

      :retry ->
        unsubscribe(subscription)
        subscribe(context)
    end
  end

  defp reject(subscription, kind) do
    unsubscribe(subscription)
    {:error, kind}
  end

  defp transition_subscribed(cell, kind) do
    case call(start(), {:transition, cell, kind}) do
      :ok -> :ok
      :retry -> transition(cell, kind)
    end
  end

  # Registration starts a local process on demand. It stops when its last
  # subscription is gone and never owns backend state.
  defp start do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, nil, name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  defp call(pid, message) do
    GenServer.call(pid, message, :infinity)
  catch
    :exit, _ -> :retry
  end

  defp drain(notification) do
    receive do
      {:request_context_terminal, ^notification} -> drain(notification)
    after
      0 -> :ok
    end
  end

  @impl true
  def init(nil),
    do: {:ok, %{contexts: %{}, monitors: %{}, subscriptions: %{}}, @registration_timeout}

  @impl true
  def handle_call({:subscribe, cell, owner, notification}, {waiter, _}, state) do
    case :atomics.compare_exchange(cell, 1, @unsubscribed, @subscribed) do
      active when active in [:ok, @subscribed] ->
        {:reply, :ok, register(state, cell, owner, waiter, notification)}

      _ ->
        {:reply, :terminal, state, delivery(state, cell)}
    end
  end

  def handle_call({:transition, cell, kind}, _, state) do
    case :atomics.compare_exchange(cell, 1, @subscribed, kind) do
      @unsubscribed -> :atomics.compare_exchange(cell, 1, @unsubscribed, kind)
      _ -> :ok
    end

    # A continuation gives the caller its result once the cell is committed.
    # If this process dies before or during delivery, its monitors wake the
    # subscribers. They can observe the same terminal cell on :DOWN.
    {:reply, :ok, state, delivery(state, cell)}
  end

  @impl true
  def handle_continue({:notify, [notification | remaining]}, state) do
    send(notification, {:request_context_terminal, notification})
    state = drop_subscription(state, notification)

    case remaining do
      [] -> idle_reply(state)
      _ -> {:noreply, state, {:continue, {:notify, remaining}}}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, notification}, state) do
    idle_reply(drop_subscription(state, notification))
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    case Map.get(state.monitors, monitor) do
      {:owner, cell} -> {:noreply, state, delivery(state, cell)}
      {:waiter, notification} -> idle_reply(drop_subscription(state, notification))
      nil -> idle_reply(state)
    end
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}

  defp idle_reply(state) when map_size(state.contexts) == 0, do: {:noreply, state, 0}
  defp idle_reply(state), do: {:noreply, state}

  defp delivery(state, cell) do
    case Map.fetch(state.contexts, cell) do
      {:ok, {_, notifications}} -> {:continue, {:notify, MapSet.to_list(notifications)}}
      :error when map_size(state.contexts) == 0 -> 0
      :error -> :infinity
    end
  end

  defp register(state, cell, owner, waiter, notification) do
    {owner_monitor, notifications} = context(state, cell, owner)
    waiter_monitor = Process.monitor(waiter)

    %{
      contexts:
        Map.put(state.contexts, cell, {owner_monitor, MapSet.put(notifications, notification)}),
      monitors:
        state.monitors
        |> Map.put(owner_monitor, {:owner, cell})
        |> Map.put(waiter_monitor, {:waiter, notification}),
      subscriptions: Map.put(state.subscriptions, notification, {cell, waiter_monitor})
    }
  end

  defp context(state, cell, owner) do
    case Map.fetch(state.contexts, cell) do
      {:ok, context} -> context
      :error -> {Process.monitor(owner), MapSet.new()}
    end
  end

  defp drop_subscription(state, notification) do
    case Map.pop(state.subscriptions, notification) do
      {nil, _} ->
        state

      {{cell, waiter_monitor}, subscriptions} ->
        {owner_monitor, notifications} = Map.fetch!(state.contexts, cell)
        Process.demonitor(waiter_monitor, [:flush])
        notifications = MapSet.delete(notifications, notification)

        state = %{
          state
          | subscriptions: subscriptions,
            monitors: Map.delete(state.monitors, waiter_monitor)
        }

        if MapSet.size(notifications) == 0 do
          Process.demonitor(owner_monitor, [:flush])
          :atomics.compare_exchange(cell, 1, @subscribed, @unsubscribed)

          %{
            state
            | contexts: Map.delete(state.contexts, cell),
              monitors: Map.delete(state.monitors, owner_monitor)
          }
        else
          put_in(state.contexts[cell], {owner_monitor, notifications})
        end
    end
  end
end
