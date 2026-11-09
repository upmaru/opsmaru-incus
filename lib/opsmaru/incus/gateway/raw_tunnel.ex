if Code.ensure_loaded?(:cowboy_req) do
  defmodule Opsmaru.Incus.Gateway.RawTunnel do
    @moduledoc false
    alias Opsmaru.Incus.Gateway.RawRelay

    # Cowboy delivers its already-read opaque bytes here after sending 101.
    # Transfer the socket to the same actor that owns the backend and lease.
    def takeover(_parent, _ref, client, transport, _opts, buffer, relay) do
      monitor = Process.monitor(relay)

      try do
        with :ok <- transport.setopts(client, active: false),
             :ok <- transport.controlling_process(client, relay),
             :ok <- RawRelay.attach(relay, client, transport, buffer) do
          receive do
            {:DOWN, ^monitor, :process, ^relay, _} -> :ok
          end
        end
      after
        Process.exit(relay, :kill)
        transport.close(client)
      end

      # Never return to Cowboy's HTTP parser after opaque protocol traffic.
      exit(:normal)
    end
  end
end
