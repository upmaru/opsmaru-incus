if Code.ensure_loaded?(NimblePool) do
  defmodule Opsmaru.Incus.ConnectionPool do
    @moduledoc """
    Optional host-owned pool for verified HTTPS buffered GET and HEAD requests.

    Add this child to the host supervision tree and supply its local name or
    PID as the connection's `pool:` option. The pool bounds retained sockets
    and bindings. Requests may open fresh sockets when the pool is unavailable
    or saturated.
    """
    use GenServer
    alias Opsmaru.Incus.ConnectionPool.Binding

    @acquisition_ms 5
    @limits %{
      max_bindings: {64, 1..256},
      size: {4, 1..32},
      idle_timeout: {15_000, 1..300_000},
      max_connection_age: {60_000, 1..3_600_000}
    }

    def start_link(opts) do
      {name, opts} = Keyword.pop(opts, :name)
      limits = validate!(opts)
      GenServer.start_link(__MODULE__, limits, if(name, do: [name: name], else: []))
    end

    @doc false
    def checkout(pool, key, deadline, request) do
      acquisition = min(deadline, now() + @acquisition_ms)

      case binding(pool, key, acquisition) do
        {:ok, pid, age} -> checkout_binding(pid, age, acquisition, request)
        :miss -> :miss
      end
    end

    @doc false
    def checkin({pool, ref} = from, socket, opened, deadline) do
      timeout = min(@acquisition_ms, deadline - now() - 1)

      if timeout > 0 do
        monitor = Process.monitor(pool)
        NimblePool.update(from, {self(), ref, socket})

        try do
          receive do
            {^ref, :return_registered} ->
              case transfer(socket, pool) do
                {:ok, socket} -> {socket, opened, now()}
                {:error, _} -> discard(socket)
              end

            {:DOWN, ^monitor, :process, ^pool, _} ->
              discard(socket)
          after
            timeout -> discard(socket)
          end
        after
          Process.demonitor(monitor, [:flush])
        end
      else
        discard(socket)
      end
    end

    defp transfer(socket, pool) do
      Mint.HTTP.controlling_process(socket, pool)
    catch
      :exit, _ -> {:error, :closed}
    end

    defp discard(socket) do
      Binding.close(socket)
      nil
    end

    defp binding(pool, key, deadline) do
      with timeout when timeout > 0 <- deadline - now(),
           pid when is_pid(pid) <- GenServer.whereis(pool) do
        GenServer.call(pid, {__MODULE__, key, deadline}, timeout)
      else
        _ -> :miss
      end
    catch
      :exit, _ -> :miss
    end

    defp checkout_binding(pid, age, deadline, request) do
      # Once the callback starts, its errors must never turn into a fresh attempt.
      token = make_ref()

      try do
        case deadline - now() do
          timeout when timeout > 0 ->
            NimblePool.checkout!(
              pid,
              deadline,
              fn from, idle ->
                Process.put(token, :checked_out)
                request.(from, idle, age, deadline)
              end,
              timeout
            )

          _ ->
            :miss
        end
      rescue
        exception in Binding.Unavailable ->
          if Process.get(token), do: reraise(exception, __STACKTRACE__), else: :miss
      catch
        :exit, reason ->
          if Process.get(token), do: exit(reason), else: :miss
      after
        Process.delete(token)
      end
    end

    @impl true
    def init(limits) do
      Process.flag(:trap_exit, true)
      Process.send_after(self(), :reap, limits.idle_timeout)
      {:ok, %{limits: limits, bindings: %{}, pids: %{}}}
    end

    @impl true
    def handle_call({__MODULE__, key, deadline}, _from, state) do
      {reply, state} = admit(state, key, deadline)
      {:reply, reply, state}
    end

    defp admit(state, key, deadline) do
      %{bindings: bindings, limits: limits} = state

      cond do
        deadline <= now() ->
          {:miss, state}

        pid = bindings[key] ->
          {{:ok, pid, limits.max_connection_age}, state}

        map_size(bindings) < limits.max_bindings ->
          start_binding(state, key)

        true ->
          {:miss, state}
      end
    end

    defp start_binding(%{limits: limits} = state, key) do
      opts = [
        worker: {Binding, limits},
        pool_size: limits.size,
        lazy: true,
        worker_idle_timeout: min(limits.idle_timeout, limits.max_connection_age)
      ]

      case NimblePool.start_link(opts) do
        {:ok, pid} ->
          state = %{
            state
            | bindings: Map.put(state.bindings, key, pid),
              pids: Map.put(state.pids, pid, key)
          }

          {{:ok, pid, limits.max_connection_age}, state}

        {:error, _} ->
          {:miss, state}
      end
    end

    @impl true
    def handle_info(:reap, state) do
      manager = self()
      pids = Map.keys(state.pids)
      interval = state.limits.idle_timeout

      spawn(fn ->
        Enum.each(pids, &reap_binding/1)
        Process.send_after(manager, :reap, interval)
      end)

      {:noreply, state}
    end

    def handle_info({:EXIT, pid, reason}, state) do
      case Map.pop(state.pids, pid) do
        {nil, _} ->
          {:stop, reason, state}

        {key, pids} ->
          {:noreply, %{state | bindings: Map.delete(state.bindings, key), pids: pids}}
      end
    end

    defp reap_binding(pid) do
      NimblePool.checkout!(pid, :reap, fn _, _ -> {:ok, nil} end, @acquisition_ms)
    rescue
      _ in Binding.Unavailable -> :ok
    catch
      :exit, _ -> :ok
    end

    @impl true
    def terminate(_reason, state) do
      Enum.each(state.pids, fn {pid, _key} -> Process.exit(pid, :kill) end)
    end

    @impl true
    def format_status(status) do
      %{status | state: :redacted, message: :redacted, log: []}
    end

    defp validate!(opts) do
      unless Keyword.keyword?(opts) and
               Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts) and
               Keyword.keys(opts) -- Map.keys(@limits) == [] do
        raise ArgumentError, "invalid connection pool options"
      end

      Map.new(@limits, fn {key, {default, range}} ->
        value = Keyword.get(opts, key, default)
        unless value in range, do: raise(ArgumentError, "invalid connection pool #{key}")
        {key, value}
      end)
    end

    defp now, do: System.monotonic_time(:millisecond)
  end
end
