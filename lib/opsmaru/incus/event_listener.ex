defmodule Opsmaru.Incus.EventListener do
  @moduledoc """
  Explicit owner-bound event callbacks over one bounded native subscription.
  Callbacks run sequentially in isolated, monitored workers with a deadline;
  failure/overflow ends the local listener without cancelling backend work.
  `wait/2` is repeatable and a local wait timeout leaves the listener active.
  No listener is created by loading the application or constructing a client.
  """
  use GenServer
  alias Opsmaru.Incus.{Error, Events, Model, Transport, WebSocket}

  @failures [
    :deadline,
    :overflow,
    :frame_limit,
    :invalid_frame,
    :invalid_event,
    :callback_failed,
    :callback_timeout,
    :channel_io,
    :channel_closed,
    :listener_failed
  ]
  defstruct [:pid, :ref, :owner, :result]

  def open(client, opts \\ []) do
    ref = make_ref()
    result = :atomics.new(1, [])
    owner = self()

    case GenServer.start(__MODULE__, {client, opts, owner, ref, result},
           timeout: client.connection.timeout + 100
         ) do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid, ref: ref, owner: owner, result: result}}
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, %Error{kind: :listener_failed}}
    end
  end

  def add_handler(listener, types, callback), do: call(listener, {:add, types, callback})
  def remove_handler(listener, target), do: call(listener, {:remove, target})
  def disconnect(listener), do: call(listener, :disconnect)
  def send_event(listener, event), do: call(listener, {:send, event})

  def active?(listener),
    do: :atomics.get(listener.result, 1) == 0 and Process.alive?(listener.pid)

  def wait(listener, timeout \\ 5_000) do
    if self() == listener.owner and is_integer(timeout) and timeout in 1..3_600_000 do
      monitor = Process.monitor(listener.pid)

      receive do
        {:DOWN, ^monitor, :process, _, _} -> outcome(listener.result)
      after
        timeout ->
          Process.demonitor(monitor, [:flush])
          {:error, %Error{kind: :deadline}}
      end
    else
      {:error, %Error{kind: :invalid_listener_wait}}
    end
  end

  defp call(listener, request) do
    if self() == listener.owner do
      GenServer.call(listener.pid, request, 3_600_100)
    else
      {:error, %Error{kind: :owner_mismatch}}
    end
  catch
    :exit, _ -> {:error, %Error{kind: :channel_closed}}
  end

  @impl true
  def init({client, opts, owner, ref, result}) do
    Transport.watch_owner(owner)

    case Events.subscribe(client, opts) do
      {:ok, channel} ->
        send(self(), :read)

        {:ok,
         %{
           channel: channel,
           owner: owner,
           monitor: Process.monitor(owner),
           ref: ref,
           result: result,
           handlers: [],
           capacity: min(client.connection.queue_limit, 128),
           timeout: client.connection.timeout,
           deadline: now() + client.connection.stream_timeout
         }}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call(_, {caller, _}, %{owner: owner} = state) when caller != owner,
    do: {:reply, {:error, %Error{kind: :owner_mismatch}}, state}

  def handle_call({:add, types, callback}, _, state) do
    cond do
      not valid_handler?(types, callback) ->
        {:reply, {:error, %Error{kind: :invalid_event_handler}}, state}

      length(state.handlers) >= state.capacity ->
        {:reply, {:error, %Error{kind: :handler_capacity}}, state}

      true ->
        target = {state.ref, make_ref()}

        {:reply, {:ok, target},
         %{state | handlers: state.handlers ++ [{target, types, callback}]}}
    end
  end

  def handle_call({:remove, target}, _, state) do
    handlers = Enum.reject(state.handlers, fn {ref, _, _} -> ref == target end)

    if length(handlers) == length(state.handlers),
      do: {:reply, {:error, %Error{kind: :invalid_event_target}}, state},
      else: {:reply, :ok, %{state | handlers: handlers}}
  end

  def handle_call(:disconnect, _, state), do: stop(state, :ok, :ok)

  def handle_call({:send, event}, _, state),
    do: {:reply, Events.send(state.channel, event), state}

  @impl true
  def handle_info(:read, state) do
    if remaining(state) == 0 do
      stop(state, :deadline)
    else
      case Events.next(state.channel, min(100, remaining(state))) do
        {:ok, event} ->
          case dispatch(state, event) do
            :ok -> read_again(state)
            kind -> stop(state, kind)
          end

        {:error, %Error{kind: :deadline}} ->
          read_again(state)

        {:error, %Error{kind: kind}} ->
          stop(state, kind)

        :eof ->
          stop(state, :ok)
      end
    end
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: stop(state, :ok)

  def handle_info({ref, :error, %Error{kind: kind}}, %{channel: %{ref: ref}} = state),
    do: stop(state, kind)

  # EOF is a notice, not proof that the bounded WebSocket queue is empty.
  # The existing read loop drains tail events and stops on Events.next/2 EOF.
  def handle_info({ref, :eof}, %{channel: %{ref: ref}} = state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    WebSocket.close(state.channel)
    if :atomics.get(state.result, 1) == 0, do: record(state.result, :listener_failed)
  end

  @impl true
  def format_status(_), do: %{state: "owner-bound event listener; payloads/callbacks redacted"}

  defp valid_handler?(types, callback),
    do:
      is_function(callback, 1) and is_list(types) and length(types) <= 32 and
        Enum.all?(types, &(is_binary(&1) and byte_size(&1) in 1..128))

  defp dispatch(state, %Model{data: event} = model) do
    Enum.reduce_while(state.handlers, :ok, fn {_, types, callback}, :ok ->
      if types == [] or event["type"] in types do
        case invoke(callback, model, min(state.timeout, remaining(state)), state.monitor) do
          :ok -> {:cont, :ok}
          kind -> {:halt, kind}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp invoke(callback, model, timeout, host_monitor) do
    owner = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            callback.(model)
            :ok
          rescue
            _ -> :callback_failed
          catch
            _, _ -> :callback_failed
          end

        send(owner, {tag, result})
      end)

    guard_worker(owner, pid, timeout)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _, _} ->
        :callback_failed

      {:DOWN, ^host_monitor, :process, _, _} ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        :channel_closed
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        :callback_timeout
    end
  end

  # Independent of the listener's receive loop. A callback trapping exits must
  # not outlive a brutally killed listener or its execution budget.
  defp guard_worker(owner, worker, timeout) do
    spawn(fn ->
      owner_monitor = Process.monitor(owner)
      worker_monitor = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_monitor, :process, _, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_monitor, :process, _, _} -> :ok
      after
        timeout + 100 -> Process.exit(worker, :kill)
      end
    end)
  end

  defp read_again(state) do
    send(self(), :read)
    {:noreply, state}
  end

  defp stop(state, kind) do
    record(state.result, kind)
    {:stop, :normal, state}
  end

  defp stop(state, kind, reply) do
    record(state.result, kind)
    {:stop, :normal, reply, state}
  end

  defp record(result, :ok), do: :atomics.put(result, 1, 1)

  defp record(result, kind),
    do: :atomics.put(result, 1, 2 + (Enum.find_index(@failures, &(&1 == kind)) || 9))

  defp outcome(result) do
    case :atomics.get(result, 1) do
      1 -> :ok
      code when code >= 2 -> {:error, %Error{kind: Enum.at(@failures, code - 2)}}
      _ -> {:error, %Error{kind: :listener_failed}}
    end
  end

  defp remaining(state), do: max(0, state.deadline - now())
  defp now, do: System.monotonic_time(:millisecond)
end

defimpl Inspect, for: Opsmaru.Incus.EventListener do
  def inspect(_, _), do: "#Opsmaru.Incus.EventListener<owner-bound callbacks redacted>"
end
