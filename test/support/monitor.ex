defmodule Opsmaru.TestSupport.Monitor do
  @moduledoc """
  Monitors that are known to be in place before the test acts.

  `Process.monitor/1` only sends a signal. Erlang orders signals per sender and
  receiver, so when the target is then killed by another process (a guard, a
  listener, a scope), that kill can reach it before the monitor does. The
  monitor then resolves to `:noproc` instead of the exit reason under test.
  """

  @doc """
  Monitors `pid` and returns the reference once the monitor is established.

  `Process.info/2` follows signal ordering, so its answer arrives only after
  `pid` has handled the monitor. Raises if `pid` had already exited.
  """
  def monitor!(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    case Process.info(pid, :monitored_by) do
      {:monitored_by, _} -> ref
      nil -> raise ArgumentError, "#{inspect(pid)} exited before it could be monitored"
    end
  end
end
