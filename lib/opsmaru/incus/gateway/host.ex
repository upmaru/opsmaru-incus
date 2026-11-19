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
  Admit an otherwise unauthenticated server peer to one operation WebSocket.

  Called only after `authorize/2` returns `{:error, :unauthenticated}`, for an
  exact GET `/1.0/operations/{id}/websocket` upgrade with one nonempty `secret`
  query value and no all-projects selection. Missing callbacks deny. An explicit
  authorization denial never falls through to this callback.

  The host must bind `request.operation`, project, target and the
  adapter-supplied peer to its own verified pending migration. Native operation
  WebSockets may omit the project even for a nondefault-project operation:
  resolve `request.project == nil` from that stored operation binding, rather
  than inferring default-project authority; an explicit conflicting selection
  must deny. A TLS peer certificate is identity input, not
  proof of caller trust; the pinned migration server normally presents no
  client certificate. The raw secret is available in `request.query`; the
  gateway forwards it unchanged and the backend still validates it. Returning
  `{:ok, grant}` permits only this request and uses the ordinary `valid?/3`
  revocation/expiry checks. Never store or log the secret in the grant.
  """
  @callback admit_operation_secret(Request.t(), host_config :: term()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Admit an otherwise unauthenticated Incus server peer to one image-copy route.

  Called only after `authorize/2` returns `{:error, :unauthenticated}`, for the
  exact HTTP routes in `request.image` (see `Opsmaru.Incus.Gateway.Request`)
  and no all-projects selection. Missing callbacks deny, so a host that does
  not implement this keeps refusing image copies in which the gateway is the
  pull source or the push target. An explicit authorization denial never falls
  through to this callback.

  A pinned v7.0.1 Incus server uses these routes when another server copies an
  image through the gateway:

    * pull from the gateway: `:info` then `:export` for the image fingerprint,
      with the secret of an image secret operation
      (`POST /1.0/images/{fp}/secret`) an authorized caller created;
    * push into the gateway: `:upload` with the fingerprint and the secret of a
      push-mode `POST /1.0/images` operation an authorized caller created, then
      `:wait` on that operation.

  **The host must verify `request.image.secret` itself.** The gateway reaches
  the backend over a trusted connection (the Unix socket, or HTTPS with a
  client certificate the backend trusts), and a pinned v7.0.1 Incus server
  treats a trusted caller's image info, export and upload as authorized
  whatever secret they carry. Compare the secret, in constant time, with the
  pending transfer: for `:info`, `:export` and `:upload`, an image token
  operation (class `token`) whose `images` resource names the fingerprint and
  whose `metadata.secret` matches, as incusd's `imageValidSecret` does; for
  `:wait`, the named operation's `metadata.secret`. Also bind the project,
  target and adapter-supplied peer, never trusting the request alone. The
  pinned server peer normally presents no client certificate. The gateway
  forwards the secret unchanged, so the backend still consumes the
  single-use token. For `:upload` the gateway also refuses, before backend
  access, a body that is not the image itself (empty, or starting with JSON
  whitespace or `{`), because the pinned server would run it as an image
  request with the gateway's trust. Returning `{:ok, grant}` permits only this request and
  uses the ordinary `valid?/3` revocation/expiry checks. Never store or log
  the secret in the grant.
  """
  @callback admit_image_secret(Request.t(), host_config :: term()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Recheck the original grant, including expiry and current revocation state.
  Only `true` keeps access. Runs before backend access and periodically during
  an exchange. Missing callbacks deny. No new grant is acquired for cleanup.
  """
  @callback valid?(Request.t(), grant :: term(), host_config :: term()) :: boolean()

  @doc """
  Supply public gateway identity from explicit verified inspection, never a
  discovery-time backend probe. Return `{:ok, identity}` with `:origin` (HTTPS
  origin), `:addresses` (host:port strings, public unless the gateway's
  `identity_scope` is `:local`), `:certificate` (PEM),
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

  @optional_callbacks identity: 2,
                      certificates: 5,
                      valid?: 3,
                      admit_operation_secret: 2,
                      admit_image_secret: 2
end
