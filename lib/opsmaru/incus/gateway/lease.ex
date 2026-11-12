defmodule Opsmaru.Incus.Gateway.Lease do
  @moduledoc """
  Exchange-local admission/revocation guard reusable by protocol adapters.

  Created only for an admitted exchange, never on dependency load. Rechecks
  the original grant through Policy with a hard callback deadline. Every
  exchange, including anonymous local discovery/enrollment, monitors its
  original admission pid. Anonymous exchanges acquire no grant and skip grant
  rechecks, but still terminate when their admission stops. The entire
  polling period, callback budget and interruption grace fit inside
  `recheck_interval` (at most five seconds). An adapter must supply an
  interruption function that closes blocked frontend I/O; the guard also ends
  the exchange process so its owned backend sockets close. No cleanup calls
  the host, opens a backend or cancels a native operation.
  """

  alias Opsmaru.Incus.Gateway.Policy

  defstruct [:pid, :valid, :admission]

  def start(gateway, request, admitted, interrupt) do
    owner = self()
    valid = :atomics.new(1, [])
    :atomics.put(valid, 1, 1)

    pid =
      spawn(fn ->
        monitors = {Process.monitor(owner), Process.monitor(admitted.admission)}
        loop(gateway, request, admitted, interrupt, owner, monitors, valid)
      end)

    %__MODULE__{pid: pid, valid: valid, admission: admitted.admission}
  end

  def check(%__MODULE__{pid: pid, valid: valid, admission: admission}) do
    cond do
      not Process.alive?(admission) -> {:error, :admission}
      :atomics.get(valid, 1) == -1 -> {:error, :admission}
      not Process.alive?(pid) or :atomics.get(valid, 1) == 0 -> {:error, :revoked}
      true -> :ok
    end
  end

  def valid?(lease), do: check(lease) == :ok

  def stop(%__MODULE__{pid: pid}) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    end
  end

  defp loop(gateway, request, admitted, interrupt, owner, monitors, valid) do
    {owner_monitor, admission_monitor} = monitors
    budget = min(gateway.callback_timeout, div(gateway.recheck_interval, 4))
    grace = min(50, div(gateway.recheck_interval, 4))
    # Reserve both a previously in-flight successful check and the next check:
    # a host may read its trust snapshot at the start of a callback.
    interval = gateway.recheck_interval - 2 * budget - grace

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        :ok

      {:DOWN, ^admission_monitor, :process, _, _} ->
        invalidate(:admission, owner, owner_monitor, valid, interrupt, grace)
    after
      interval ->
        if admitted.anonymous or Policy.recheck(gateway, request, admitted.grant) == :ok do
          loop(gateway, request, admitted, interrupt, owner, monitors, valid)
        else
          invalidate(:revoked, owner, owner_monitor, valid, interrupt, grace)
        end
    end
  end

  defp invalidate(reason, owner, monitor, valid, interrupt, grace) do
    :atomics.put(valid, 1, if(reason == :admission, do: -1, else: 0))
    send(owner, {:gateway_stopped, self(), reason})

    receive do
      {:DOWN, ^monitor, :process, ^owner, _} -> :ok
    after
      grace ->
        interrupt.()
        Process.exit(owner, :kill)
    end
  end
end
