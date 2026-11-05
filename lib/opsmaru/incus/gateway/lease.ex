defmodule Opsmaru.Incus.Gateway.Lease do
  @moduledoc """
  Exchange-local revocation guard reusable by HTTP, WebSocket and raw adapters.

  Created only for an admitted exchange, never on dependency load. Rechecks
  the original grant through Policy with a hard callback deadline. The entire
  polling period, callback budget and interruption grace fit inside
  `recheck_interval` (at most five seconds). An adapter must supply an
  interruption function that closes blocked frontend I/O; the guard also ends
  the exchange process so its owned backend sockets close. No cleanup calls
  the host, opens a backend or cancels a native operation.
  """

  alias Opsmaru.Incus.Gateway.Policy

  defstruct [:pid, :valid]

  def start(gateway, request, admitted, interrupt) do
    owner = self()
    valid = :atomics.new(1, [])
    :atomics.put(valid, 1, 1)

    pid =
      spawn(fn ->
        monitor = Process.monitor(owner)
        loop(gateway, request, admitted, interrupt, owner, monitor, valid)
      end)

    %__MODULE__{pid: pid, valid: valid}
  end

  def valid?(%__MODULE__{pid: pid, valid: valid}),
    do: Process.alive?(pid) and :atomics.get(valid, 1) == 1

  def stop(%__MODULE__{pid: pid}) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    end
  end

  defp loop(gateway, request, admitted, interrupt, owner, monitor, valid) do
    budget = min(gateway.callback_timeout, div(gateway.recheck_interval, 4))
    grace = min(50, div(gateway.recheck_interval, 4))
    # Reserve both a previously in-flight successful check and the next check:
    # a host may read its trust snapshot at the start of a callback.
    interval = gateway.recheck_interval - 2 * budget - grace

    receive do
      {:DOWN, ^monitor, :process, ^owner, _} -> :ok
    after
      interval ->
        if Policy.recheck(gateway, request, admitted.grant) == :ok do
          loop(gateway, request, admitted, interrupt, owner, monitor, valid)
        else
          :atomics.put(valid, 1, 0)
          send(owner, {:gateway_revoked, self()})

          receive do
            {:DOWN, ^monitor, :process, ^owner, _} -> :ok
          after
            grace ->
              interrupt.()
              Process.exit(owner, :kill)
          end
        end
    end
  end
end
