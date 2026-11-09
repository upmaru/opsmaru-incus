defmodule Opsmaru.Incus.Gateway do
  @moduledoc """
  Immutable configuration for the optional native Incus gateway.

  A host mounts `Opsmaru.Incus.Gateway.Plug` in its own router/endpoint and
  passes a gateway built here. Construction is passive: it validates values and
  performs no I/O, starts no process and opens no backend. Loading or
  configuring `:opsmaru_incus` never starts a listener, whatever PHX_SERVER or
  PORT say.

  Fields:

    * `:connection` - the fixed host-selected `Opsmaru.Incus.Connection`. Request
      fields can never replace it.
    * `:host` - a module implementing `Opsmaru.Incus.Gateway.Host`. It verifies
      callers, readiness and authority. Without it nothing is relayed.
    * `:host_config` - opaque host term passed to every callback; redacted.
    * `:admission` - the name or pid of a host-started
      `Opsmaru.Incus.Gateway.Admission`. A missing or stopped admission denies.
    * `:recheck_interval` - maximum active expiry/revocation latency in ms,
      including callback and interruption budgets (default/maximum 5000).
      Hosts may tighten it to 4..5000 ms.
    * `:max_identity_bytes` - bounded discovery/trust/server-identity bodies
      (default 1 MiB, maximum 4 MiB).
    * `:callback_timeout` - per host callback budget in ms (default 1000).
    * `:idle_timeout` - longest silence from the backend or caller in ms
      (default: the connection's `stream_timeout`).
    * `:max_lifetime` - absolute budget for one relayed exchange in ms
      (default 1 hour).
    * `:max_request_bytes` / `:max_response_bytes` - body budgets (default:
      the connection's `max_stream_bytes`).
    * `:max_chunk_bytes` - largest body chunk read at once (default: the
      connection's `max_chunk_bytes`).
    * `:max_header_bytes` - request header budget (default 64 KiB).

  The HTTP Plug and its relay compile only when Plug is available; client-only
  consumers need neither Plug nor Cowboy.
  """

  alias Opsmaru.Incus.Connection

  @enforce_keys [:connection, :host, :admission]
  defstruct [
    :connection,
    :host,
    :host_config,
    :admission,
    :idle_timeout,
    :max_request_bytes,
    :max_response_bytes,
    :max_chunk_bytes,
    recheck_interval: 5_000,
    max_identity_bytes: 1_048_576,
    callback_timeout: 1_000,
    max_lifetime: 3_600_000,
    max_header_bytes: 65_536
  ]

  @type t :: %__MODULE__{}

  @keys [
    :connection,
    :host,
    :host_config,
    :admission,
    :recheck_interval,
    :max_identity_bytes,
    :callback_timeout,
    :idle_timeout,
    :max_lifetime,
    :max_request_bytes,
    :max_response_bytes,
    :max_chunk_bytes,
    :max_header_bytes
  ]

  @doc "Validate an immutable gateway configuration without any I/O."
  def new!(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- @keys == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))),
           do: raise(ArgumentError, "invalid gateway options")

    connection = connection!(Keyword.get(opts, :connection))
    host!(Keyword.get(opts, :host))
    admission!(Keyword.get(opts, :admission))

    gateway =
      struct!(
        __MODULE__,
        Keyword.merge(
          [
            idle_timeout: connection.stream_timeout,
            max_request_bytes: connection.max_stream_bytes,
            max_response_bytes: connection.max_stream_bytes,
            max_chunk_bytes: connection.max_chunk_bytes
          ],
          opts
        )
      )

    bounded!(gateway.recheck_interval, 4..5_000, "recheck_interval")
    bounded!(gateway.max_identity_bytes, 1..4_194_304, "max_identity_bytes")
    bounded!(gateway.callback_timeout, 1..30_000, "callback_timeout")
    bounded!(gateway.idle_timeout, 1..3_600_000, "idle_timeout")
    bounded!(gateway.max_lifetime, 1..86_400_000, "max_lifetime")
    bounded!(gateway.max_request_bytes, 0..1_099_511_627_776, "max_request_bytes")
    bounded!(gateway.max_response_bytes, 0..1_099_511_627_776, "max_response_bytes")
    bounded!(gateway.max_chunk_bytes, 1..1_048_576, "max_chunk_bytes")
    bounded!(gateway.max_header_bytes, 1_024..1_048_576, "max_header_bytes")
    gateway
  end

  defp connection!(%Connection{} = connection), do: connection

  defp connection!(_),
    do: raise(ArgumentError, "gateway requires a host-selected Opsmaru.Incus.Connection")

  defp host!(host) do
    unless is_atom(host) and not is_nil(host) and Code.ensure_loaded?(host) and
             function_exported?(host, :ready?, 1) and function_exported?(host, :authorize, 2),
           do: raise(ArgumentError, "gateway host must implement Opsmaru.Incus.Gateway.Host")
  end

  defp admission!(admission) do
    unless (is_atom(admission) and not is_nil(admission)) or is_pid(admission),
      do: raise(ArgumentError, "gateway requires a host-started admission name or pid")
  end

  defp bounded!(value, range, name) do
    unless is_integer(value) and value in range,
      do: raise(ArgumentError, "gateway #{name} must be an integer in #{inspect(range)}")
  end
end

defimpl Inspect, for: Opsmaru.Incus.Gateway do
  def inspect(gateway, _),
    do: "#Opsmaru.Incus.Gateway<#{inspect(gateway.host)} backend and host state redacted>"
end
