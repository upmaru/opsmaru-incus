defmodule Opsmaru.Incus.Gateway.Admission do
  @moduledoc """
  Host-started bounded admission for gateway exchanges.

  Add `{Opsmaru.Incus.Gateway.Admission, name: MyHost.GatewayAdmission,
  max_exchanges: 64}` to the host's supervision tree when mounting the gateway;
  the library never starts it. Each relayed exchange holds one slot from before
  host callbacks run until its backend socket is closed. At capacity a request
  is rejected immediately: nothing is queued and no backend is opened.

  Slots are tied to the holding process and released when it exits. A relay
  monitors the admission process and stops its own backend socket if admission
  stops or restarts, so a restart never leaves untracked backend traffic.
  Status and crash reports show only counts.
  """

  use GenServer
  alias Opsmaru.Incus.Redaction

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    maximum = Keyword.fetch!(opts, :max_exchanges)

    unless is_integer(maximum) and maximum in 1..65_536,
      do: raise(ArgumentError, "max_exchanges must be between 1 and 65536")

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, maximum)
      name -> GenServer.start_link(__MODULE__, maximum, name: name)
    end
  end

  @doc """
  Take one slot for `holder`. Returns `{:ok, slot}`, `{:error, :capacity}` or
  `{:error, :unavailable}` when admission is not running.
  """
  def acquire(admission, holder \\ self(), timeout \\ 1_000) do
    GenServer.call(admission, {:acquire, holder}, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Release a slot. Idempotent; exiting holders are released automatically."
  def release({admission, ref}) do
    GenServer.cast(admission, {:release, ref})
  end

  @doc "Move an existing slot to its protocol owner without reacquiring capacity."
  def transfer({admission, ref}, holder) when is_pid(holder) do
    GenServer.call(admission, {:transfer, ref, holder})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Current number of held slots."
  def count(admission), do: GenServer.call(admission, :count)

  @impl true
  def init(maximum), do: {:ok, %{maximum: maximum, slots: %{}}}

  @impl true
  def handle_call({:acquire, holder}, _from, state) do
    if is_pid(holder) and map_size(state.slots) < state.maximum do
      ref = Process.monitor(holder)
      {:reply, {:ok, {self(), ref}}, %{state | slots: Map.put(state.slots, ref, holder)}}
    else
      {:reply, {:error, :capacity}, state}
    end
  end

  def handle_call(:count, _from, state), do: {:reply, map_size(state.slots), state}

  def handle_call({:transfer, ref, holder}, _from, state) do
    if Map.has_key?(state.slots, ref) and Process.alive?(holder) do
      Process.demonitor(ref, [:flush])
      monitor = Process.monitor(holder)
      slots = state.slots |> Map.delete(ref) |> Map.put(monitor, holder)
      {:reply, {:ok, {self(), monitor}}, %{state | slots: slots}}
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | slots: Map.delete(state.slots, ref)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, %{state | slots: Map.delete(state.slots, ref)}}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Redaction.status(status, %{slots: map_size(Map.get(status, :state, %{slots: %{}}).slots)})
end
