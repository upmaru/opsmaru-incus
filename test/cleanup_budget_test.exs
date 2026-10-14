defmodule Opsmaru.Incus.CleanupBudgetTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.WebSocket
  alias Opsmaru.TestSupport.CleanupAssertions, as: Cleanup

  test "blocked closes batch requests and spend one shared grace allowance" do
    parent = self()
    pids = for _ <- 1..3, do: spawn(fn -> receive do: (:never -> :ok) end)
    monitors = Cleanup.monitor(pids)

    closer =
      spawn(fn ->
        receive do
          :close ->
            :ok = WebSocket.close_owned(Enum.map(pids, &%{pid: &1}))
            send(parent, :closed)
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn ->
      :erlang.trace_pattern({:gen_server, :send_request, 2}, false, [:local])
      :erlang.trace_pattern({:gen_server, :wait_response, 2}, false, [:local])
      for pid <- [closer | pids], Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :erlang.trace_pattern({:gen_server, :send_request, 2}, true, [:local])
    :erlang.trace_pattern({:gen_server, :wait_response, 2}, true, [:local])
    :erlang.trace(closer, true, [:call])
    send(closer, :close)
    assert_receive :closed, 5_000
    barrier = :erlang.trace_delivered(closer)
    assert_receive {:trace_delivered, ^closer, ^barrier}, 5_000

    calls =
      for _ <- 1..6 do
        receive do
          {:trace, ^closer, :call, {:gen_server, function, arguments}} -> {function, arguments}
        after
          5_000 -> flunk("missing shared-cleanup call trace")
        end
      end

    assert Enum.map(calls, &elem(&1, 0)) ==
             [
               :send_request,
               :send_request,
               :send_request,
               :wait_response,
               :wait_response,
               :wait_response
             ]

    assert for({:send_request, [pid, :close]} <- calls, do: pid) == pids
    [first | remaining] = for {:wait_response, [_, timeout]} <- calls, do: timeout
    assert first in 0..100
    assert remaining == [0, 0]
    assert :ok = Cleanup.assert_stopped(monitors)
  end

  test "cleanup observations still reject a live owned process with diagnostics" do
    pid = spawn(fn -> receive do: (:never -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    assert_raise ExUnit.AssertionError, ~r/owned processes:/, fn ->
      Cleanup.assert_stopped(Cleanup.monitor([pid]), 10)
    end
  end
end
