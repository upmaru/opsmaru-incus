defmodule Opsmaru.ClientSupervisor do
  @moduledoc """
  Optional host-owned bounded concurrency, with no startup/recovery work.

  Add `{Opsmaru.ClientSupervisor, name: MyHost.Clients, max_children: 8}` to
  the host's tree. Calls at capacity fail immediately; no work queue is kept.
  Stopping/restarting it affects only local calls, never host/Incus lifecycle.
  Losing a local worker cannot establish backend cancellation or permit replay.
  """
  def child_spec(opts) do
    maximum = Keyword.fetch!(opts, :max_children)

    unless is_integer(maximum) and maximum in 1..1024,
      do: raise(ArgumentError, "max_children must be between 1 and 1024")

    Task.Supervisor.child_spec(opts)
  end

  @doc "Start a caller-monitored temporary task, or fail visibly at capacity."
  def async(supervisor, fun) when is_function(fun, 0) do
    {:ok, Task.Supervisor.async_nolink(supervisor, fun)}
  rescue
    RuntimeError -> {:error, :capacity}
  catch
    :exit, _ -> {:error, :supervisor_unavailable}
  end
end
