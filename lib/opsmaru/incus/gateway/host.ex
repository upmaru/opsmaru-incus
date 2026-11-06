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
  denies before backend access. Explicit `{:error, :unauthenticated}` allows
  only synthetic HTTP GET `/` or `/1.0` and host-decided POST certificate
  enrollment; all other errors deny. It never authorizes backend relay.

  `request.project` is `nil` when the caller selected no project, which the
  backend treats as its native default; the gateway never injects one.
  """
  @callback authorize(Request.t(), host_config :: term()) :: {:ok, term()} | {:error, term()}
  @doc """
  Recheck the original grant, including expiry and current revocation state.
  Only `true` keeps access. Runs before backend access and periodically during
  an exchange. Missing callbacks deny. No new grant is acquired for cleanup.
  """
  @callback valid?(Request.t(), grant :: term(), host_config :: term()) :: boolean()

  @doc """
  Supply public gateway identity from explicit verified inspection, never a
  discovery-time backend probe. Return `{:ok, identity}` with `:origin` (HTTPS
  origin), `:addresses` (public host:port strings), `:certificate` (PEM),
  `:connection` (the exact configured backend), and `:api_extensions` (verified
  backend extensions intersected with host policy). The gateway further limits
  extensions to its implemented protocols. Only public identity is returned to
  callers; the backend binding is never encoded. This callback is used only
  for HTTP GET `/` and `/1.0`.
  """
  @callback identity(Request.t(), host_config :: term()) :: {:ok, map()} | {:error, term()}

  @doc """
  Handle an allowlisted native trust action without touching backend trust.
  The action is `:list`, `:get`, `:create`, `:update` or `:delete`. Input is a
  bounded map containing `:fingerprint`, `:body` (decoded native JSON) and
  `:if_match` (the native ETag precondition). Return `{:ok, metadata, headers}`
  for a native synchronous 200 response or `{:error, status}` (400..599).
  The host must enforce owner/admin or token enrollment authority itself,
  including verifying the actual peer certificate. Request metadata alone is
  never a verified principal. No restricted certificates, project restrictions,
  server/metrics credentials or asynchronous token issuance are supported.
  Production trust storage and token issuance stay entirely host-owned.
  """
  @callback certificates(atom(), Request.t(), term(), map(), term()) ::
              {:ok, term(), [{binary(), binary()}]} | {:error, 400..599}

  @optional_callbacks identity: 2, certificates: 5, valid?: 3
end
