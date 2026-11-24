defmodule Opsmaru.Incus.Telemetry do
  @moduledoc """
  Optional `:telemetry` emission for the library.

  Events:

    * `[:opsmaru_incus, :gateway, :exchange, :start]` - measurements
      `system_time`, `monotonic_time`; emitted in the gateway adapter process.
    * `[:opsmaru_incus, :gateway, :exchange, :stop]` - measurements
      `duration`, `request_bytes`, `response_bytes`; emitted once per exchange
      from its observer process.

  The metadata, closed value sets and excluded values are documented in
  `docs/gateway.md` ("Exchange telemetry").

  `:telemetry` is an optional dependency. The implementation is chosen at
  compile time: without `:telemetry` every function is a no-op. Emission never
  raises into a request, including when `:telemetry` is loaded but not
  started. The library attaches no handler.
  """

  if Code.ensure_loaded?(:telemetry) do
    @doc false
    def execute(event, measurements, metadata) do
      :telemetry.execute(event, measurements, metadata)
    catch
      _, _ -> :ok
    end

    @doc false
    def list_handlers(prefix) do
      :telemetry.list_handlers(prefix)
    catch
      _, _ -> []
    end
  else
    @doc false
    def execute(_event, _measurements, _metadata), do: :ok

    @doc false
    def list_handlers(_prefix), do: []
  end
end
