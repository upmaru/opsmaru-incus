defmodule Opsmaru.Incus.Gateway.Host do
  @moduledoc """
  Host policy contract for the native gateway.

  The host owns caller verification, readiness and authority. The gateway
  calls these callbacks for every relayed request, before it opens any backend
  connection, under `callback_timeout`. A callback that raises, exits, returns
  anything else or misses its deadline denies the request. A late result is
  discarded and can never authorize work.

  Callbacks receive an `Opsmaru.Incus.Gateway.Request` built from the server
  adapter: the actual TLS peer certificate and address, the caller's
  `authorization` header and the native project/target selection parsed from
  the raw query. Request bodies and other headers cannot supply a principal,
  backend address or credentials.

  `host_config` is the opaque term from `Opsmaru.Incus.Gateway.new!/1`.
  """

  alias Opsmaru.Incus.Gateway.Request

  @doc """
  Fast local readiness check. Only exactly `true` admits the request.
  """
  @callback ready?(host_config :: term()) :: boolean()

  @doc """
  Authorize one request. Return `{:ok, grant}` to relay it; the grant is an
  opaque host term kept for the lifetime of the exchange. Any other result
  denies before backend access.

  `request.project` is `nil` when the caller selected no project, which the
  backend treats as its native default; the gateway never injects one.
  """
  @callback authorize(Request.t(), host_config :: term()) :: {:ok, term()} | {:error, term()}
end
