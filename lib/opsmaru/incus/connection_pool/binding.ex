if Code.ensure_loaded?(NimblePool) do
  defmodule Opsmaru.Incus.ConnectionPool.Binding do
    @moduledoc false
    @behaviour NimblePool

    defmodule Unavailable do
      @moduledoc false
      defexception message: "connection pool slot unavailable"
    end

    @impl true
    def init_pool(limits) do
      {:ok, %{limits: limits, active: 0, last_used: now()}}
    end

    @impl true
    def init_worker(state), do: {:ok, :idle, state}

    @impl true
    def handle_enqueue(:reap, state) do
      if inactive?(state), do: Process.exit(self(), :kill)
      {:skip, %Unavailable{}, state}
    end

    def handle_enqueue(deadline, state) do
      if state.active < state.limits.size and now() < deadline,
        do: {:ok, deadline, state},
        else: {:skip, %Unavailable{}, state}
    end

    @impl true
    def handle_checkout(deadline, {pid, _ref}, idle, state) do
      socket = take(idle, pid, deadline, state.limits)
      state = %{state | active: state.active + 1}
      {:ok, socket, {:leased, socket}, state}
    end

    @impl true
    def handle_update({pid, ref, socket}, {:leased, _}, state) do
      # NimblePool installs the returned worker state before handling another
      # message, including the request worker's DOWN.
      send(pid, {ref, :return_registered})
      {:ok, {:returning, pid, socket}, state}
    end

    @impl true
    def handle_checkin(nil, _from, _leased, state), do: {:remove, :discarded, state}

    def handle_checkin({socket, opened, returned}, {pid, _}, {:returning, pid, socket}, state) do
      if expired?(opened, returned, state.limits) do
        {:remove, :expired, state}
      else
        {:ok, {socket, opened, returned}, released(state)}
      end
    end

    @impl true
    def terminate_worker(_reason, {:leased, idle}, state) do
      close_leased(idle)
      {:ok, released(state)}
    end

    def terminate_worker(_reason, {:returning, _pid, socket}, state) do
      close(socket)
      {:ok, released(state)}
    end

    def terminate_worker(_reason, idle, state) do
      close_idle(idle)
      {:ok, state}
    end

    @impl true
    def handle_ping(idle, state) do
      cond do
        inactive?(state) ->
          {:stop, :idle}

        expired_idle?(idle, state.limits) ->
          {:remove, :expired}

        true ->
          {:ok, idle}
      end
    end

    defp take(:idle, _pid, _deadline, _limits), do: nil

    defp take({socket, opened, returned} = idle, pid, deadline, limits) do
      with false <- expired?(opened, returned, limits),
           true <- now() < deadline,
           {:ok, socket} <- Mint.HTTP.controlling_process(socket, pid) do
        {socket, opened}
      else
        _ ->
          close_idle(idle)
          nil
      end
    end

    defp released(state) do
      %{state | active: state.active - 1, last_used: now()}
    end

    defp inactive?(state),
      do: state.active == 0 and now() - state.last_used >= state.limits.idle_timeout

    defp expired_idle?(:idle, _limits), do: false

    defp expired_idle?({_socket, opened, returned}, limits),
      do: expired?(opened, returned, limits)

    defp expired?(opened, returned, limits) do
      now = now()
      now - opened >= limits.max_connection_age or now - returned >= limits.idle_timeout
    end

    defp close_idle(:idle), do: :ok
    defp close_idle({socket, _opened, _returned}), do: close(socket)
    defp close_leased(nil), do: :ok
    defp close_leased({socket, _opened}), do: close(socket)

    # Bound TLS teardown even when a peer does not read the close notification.
    def close(socket), do: :ssl.close(Mint.HTTP.get_socket(socket), 0)

    defp now, do: System.monotonic_time(:millisecond)
  end
end
