defmodule Opsmaru.TestSupport.CleanupAssertions do
  @moduledoc false
  import ExUnit.Assertions

  # Observation allowance, not a replacement for the library's cleanup budget.
  def monitor(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  def assert_stopped(monitors, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    for {pid, monitor} <- monitors do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          states =
            Enum.map(monitors, fn {owned, _} ->
              {owned, Process.info(owned, [:status, :current_stacktrace, :message_queue_len])}
            end)

          flunk("cleanup observation exceeded #{timeout} ms; owned processes: #{inspect(states)}")
      end
    end

    :ok
  end
end
