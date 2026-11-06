defmodule Opsmaru.TestSupport.TraceLock do
  @moduledoc """
  One test at a time may set VM-wide call trace patterns.

  `:erlang.trace_pattern/3` is global: a pattern one module sets or clears
  applies to every traced process in the VM. Patterns only produce messages for
  processes traced with the `:call` flag, so tests that never trace calls run
  safely beside a tracing test. Tests that do must hold this lock from before
  they set a pattern until after they clear it.

  Call `acquire!/0` from the test process before registering the `on_exit`
  that clears patterns: callbacks run newest first, so the patterns are cleared
  before the lock is released. Repeated calls in one test are no-ops.
  """

  @doc "Hold the trace lock until this test's later `on_exit` callbacks have run."
  def acquire! do
    if Process.get(__MODULE__) do
      :ok
    else
      test = self()

      holder =
        spawn(fn ->
          :global.trans({__MODULE__, self()}, fn ->
            send(test, {__MODULE__, :held, self()})

            Process.sleep(:infinity)
          end)
        end)

      # Registered before waiting, so a test that times out here still stops its
      # holder. :global releases a lock when its holder exits, so killing it covers
      # both a holder that took the lock and one still waiting for it.
      ExUnit.Callbacks.on_exit(fn -> Process.exit(holder, :kill) end)
      Process.put(__MODULE__, holder)

      receive do
        {__MODULE__, :held, ^holder} -> :ok
      after
        120_000 -> raise "timed out waiting for the VM-wide trace lock"
      end

      :ok
    end
  end
end
