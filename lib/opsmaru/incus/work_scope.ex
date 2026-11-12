defmodule Opsmaru.Incus.WorkScope do
  @moduledoc false
  @key {__MODULE__, :scope}

  def new(limit) do
    table = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(table, {:count, 0})
    {table, limit}
  end

  def current, do: Process.get(@key)
  def bind(scope), do: Process.put(@key, scope)
  def register(nil, _), do: :ok

  def register({table, limit}, pid) do
    if :ets.update_counter(table, :count, 1) <= limit do
      :ets.insert(table, {pid, true})
      :ok
    else
      :error
    end
  rescue
    _ -> :error
  end

  def stop({table, _} = scope) do
    workers = for {pid, true} <- :ets.tab2list(table), is_pid(pid), do: pid

    monitors =
      for pid <- workers do
        monitor = Process.monitor(pid)
        Process.exit(pid, :kill)
        monitor
      end

    for monitor <- monitors do
      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      end
    end

    # A worker can register a descendant before its kill signal is processed.
    # Check again after all observed workers have actually terminated.
    if Enum.any?(:ets.tab2list(table), fn {pid, _} -> is_pid(pid) and Process.alive?(pid) end),
      do: stop(scope),
      else: :ok
  end

  def close({table, _}), do: :ets.delete(table)
end
