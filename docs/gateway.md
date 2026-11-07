# Native Incus gateway (G1–G3: HTTP, identity and WebSockets)

`Opsmaru.Incus.Gateway` lets a host relay native Incus HTTP through its own
endpoint under its own policy. This page documents slices G1–G3 of
`add-embeddable-incus-gateway`; SFTP/NBD and migration arrive in later slices
and are listed under
[Not yet in this revision](#not-yet-in-this-revision).

## Dependencies

`plug` and `cowboy` are optional dependencies of `:opsmaru_incus`. A host that
mounts the gateway already has them; a client-only consumer does not and still
compiles warning-free (`Opsmaru.Incus.Gateway.Plug` is simply absent). The
gateway's streaming and abort behaviour is verified with Plug.Cowboy, the
adapter Macus uses.

## Host composition

1. Start an admission process in the host's own supervision tree. The library
   never starts it.

   ```elixir
   children = [
     {Opsmaru.Incus.Gateway.Admission, name: MyHost.GatewayAdmission, max_exchanges: 64},
     MyHostWeb.Endpoint
   ]
   ```

2. Implement `Opsmaru.Incus.Gateway.Host`: `ready?/1`, `authorize/2` and
   `valid?/3`; provide `identity/2` for discovery/server identity and
   `certificates/5` for host-owned trust actions. Missing callbacks deny the
   corresponding path. The last three are optional behaviour callbacks for
   source compatibility with G1 hosts; they have no permissive fallback.

3. Build the gateway at request time (so runtime configuration and pids are
   never compiled into the router):

   ```elixir
   def fetch do
     Opsmaru.Incus.Gateway.new!(
       connection: MyHost.Incus.connection(),
       host: MyHost.GatewayPolicy,
       host_config: MyHost.GatewayPolicy.config(),
       admission: MyHost.GatewayAdmission
     )
   end
   ```

4. Mount it for the native routes, ahead of any body parser:

   ```elixir
   get "/", Opsmaru.Incus.Gateway.Plug, gateway: {MyHost.Gateway, :fetch, []}
   forward "/1.0", Opsmaru.Incus.Gateway.Plug, gateway: {MyHost.Gateway, :fetch, []}
   ```

   Keep `/runtime`, `/mcp` and other host routes outside these mounts. A gateway
   placed behind `Plug.Parsers` refuses every request with `500` instead of
   relaying a reconstructed body.

## Request path

Every request takes the same path before any backend socket opens:

1. Route check on the original encoded `request_path`: only `/`, `/1.0` and
   `/1.0/*`; dot segments, NUL and backslashes, raw or percent-encoded, are
   refused (`400`). An encoded `/` inside a segment is kept, since image
   aliases use it.
2. Selection parsing on the raw query. Duplicate `project`, `target` or
   `all-projects` values, `;` separators and malformed escapes are refused
   (`400`). The backend parses with Go's `url.ParseQuery` and falls back to
   the default project when the query fails to parse, so the gateway refuses
   exactly those queries to keep the authorized selection and the executed
   one identical. `all-projects` follows the backend's `IsTrue`.
3. Admission: at capacity `503`, nothing queued.
4. `ready?/1`, then `authorize/2`, each in a monitored process killed at
   `callback_timeout`. Anything but `true` / `{:ok, grant}` denies (`503` /
   `403`). An explicit `{:error, :unauthenticated}` permits only synthetic
   HTTP `GET /`, `GET /1.0`, or token enrollment via `POST /1.0/certificates`.
   Other denials remain denials. A late answer is discarded. For an authorized
   grant, `valid?/3` must return exactly `true` before backend access.
5. Protocol: native WebSockets negotiate after authorization when their
   optional adapter is available. SFTP/NBD upgrades get `501` in this revision.
   Unsupported adapters fail explicitly after authorization.

The host receives an `Opsmaru.Incus.Gateway.Request` with the peer address and
TLS certificate from the server adapter, the `authorization` header and the
parsed selection. Body fields and other headers cannot change the principal or
the backend.

## Relay behaviour

- One new backend connection per exchange (Unix or verified mutual HTTPS, from
  the fixed `Connection`); never pooled, retried or redirected.
- The raw path and query are sent unchanged. Statuses, native errors, ETags,
  `Location` operation URLs and workload bodies are relayed unchanged. The
  bounded server-identity exception and host-owned trust routes are below.
- Never forwarded to the backend: `authorization`, `proxy-authorization`,
  `cookie`, `forwarded`, `x-forwarded-*`, `x-real-ip`, `expect`, hop-by-hop
  fields and fields named in `connection`. `host` comes from the backend
  connection. Everything else, including `x-incus-*`, is forwarded.
- Hop-by-hop response fields are removed. Response fields that could split a
  response are refused before commit. Cowboy writes repeated response fields
  as one comma-joined field.
- Request bodies stream in `max_chunk_bytes` reads; sized bodies keep their
  `content-length`, unsized ones are sent chunked. Response bodies stream with
  backpressure: Cowboy acknowledges each chunk before the next backend read.
- Response trailers are forwarded when the caller sent `TE: trailers` and
  dropped otherwise. Request trailers are not forwarded.

## Discovery, identity and host trust

`identity/2` returns `{:ok, identity}` with these atom keys:

```elixir
%{
  origin: "https://gateway.example.com:8443",
  addresses: ["gateway.example.com:8443"],
  certificate: gateway_pem_certificate,
  connection: exact_configured_backend_connection,
  api_extensions: verified_backend_extensions_allowed_by_host_policy
}
```

The host obtains this metadata through its own explicit verified inspection,
bound to that exact connection. Loading the library or handling anonymous
discovery never probes the backend. The origin must be an HTTPS origin;
addresses contain only approved public `host:port` authorities. Literal
private/loopback/link-local IPs, socket names, paths and credentials are refused.
The host is responsible for public DNS and for supplying the gateway listener's
actual certificate. The connection binding is never returned to a caller.

`GET /` is always synthetic (`metadata: ["/1.0"]`). Unauthenticated `GET /1.0`
returns native synchronous metadata with `auth: "untrusted"`, `public: false`,
`auth_methods: ["tls"]`, stable API version 1.0 and the approved extensions.
Both remain subject to readiness, admission, callback deadlines and body/header
budgets. Only an explicit unauthenticated decision permits discovery; malformed
credentials, forbidden authority and callback failures cannot become anonymous
access. No private environment is included in anonymous discovery.

Authenticated `GET /1.0` uses the backend, buffering at most the smaller of
`max_identity_bytes` and `max_response_bytes` before committing a response. Its
`metadata.environment.addresses` and `certificate` are replaced with the public
gateway values. Every other native environment/envelope field is retained.
API extensions are intersected with verified host metadata and the gateway's
implemented-extension allowlist: `certificate_update`, `instances`, and
`console` when the optional WebSocket adapter is available. The host must
approve only protocols it actually mounts and a verified backend supports;
merely installing an adapter does not authorize a protocol. Raw, migration,
restricted-certificate and token issuance gaps remain explicit below.

This identity rewrite is required by the pinned v7.0.1 client's
`GetConnectionInfo()`: it starts with the connection URL, then appends HTTPS
URLs made from the advertised addresses. Guest/NAT/socket addresses must not
become migration fallback endpoints. The pinned client keeps the TLS connection
certificate as its pin. Native non-200 errors pass through unchanged. Invalid,
encoded or oversized successful identity bodies fail with a native-shaped
`502`, without committing backend bytes. Valid identity trailers are validated and dropped before rewriting; their
ETag/digest values describe the original representation. The changed representation gets a new
content length and drops the backend's ETag/digest validators, which describe
the original bytes. Workload responses retain their native validators.

All `/1.0/certificates` trust routes are handled locally, never proxied to guest
trust, including encoded aliases (which are rejected rather than forwarded).
The allowlist is GET/list, GET/fingerprint, POST/create, PUT/fingerprint and
DELETE/fingerprint; fingerprints are full lowercase SHA-256. The callback gets
the original request/query, original grant (nil for unauthenticated enrollment),
and `%{fingerprint: ..., body: decoded_json, if_match: native_etag_or_nil}`.
Bodies are bounded; chunked JSON is supported. The host returns
`{:ok, native_metadata, headers}` (only ETag/Location) or `{:error, 400..599}`.
The gateway produces the native synchronous envelope and native error shape.
Validation/encoding stays inside the killable callback budget. A timed-out
trust mutation is reported `uncertain`; it is never retried.

The host must verify owner/admin authority or a valid enrollment token against
the actual TLS peer. Request bodies cannot assert a verified principal.
Restricted certificates, nonempty project claims, server/metrics certificate
types and asynchronous token issuance are explicitly refused. Unrestricted
`projects: null` is accepted as empty, matching the pinned Go serializer.
Gateway TLS credentials, enrollment tokens and trust never become backend
credentials; backend HTTPS uses only the configured Connection's own identity.

`test/support/gateway/certificate_host.ex` is an isolated test-only host with
explicitly started, ephemeral Agent trust, owner/admin authority, expiry,
single-use token enrollment and revocation. It is not production trust storage
or an issuer. Production trust persistence, policy and token administration
remain owned by the embedding host.

## Expiry and revocation

`valid?(request, original_grant, host_config)` must enforce current expiry and
revocation and return exactly `true`. The initial check and every active check
use `Policy.callback`; a timeout, raise, missing callback or any other result
denies access. Active checks use at most `min(callback_timeout,
recheck_interval / 4)` milliseconds. `recheck_interval` defaults to **5000 ms**
and may only be tightened (4–5000 ms).

Every local or relayed exchange, including anonymous discovery/enrollment,
monitors its original admission pid through `Gateway.Lease`. Admission loss
terminates blocked I/O, so a restarted admission cannot leave old holders
running outside its capacity. Local routes check admission before/after body
reads, before host callbacks and immediately before committing a response. A
trust callback that may have completed when admission is lost reports an
uncertain outcome; no callback is replayed. Anonymous leases monitor admission
without requesting or rechecking a grant.

An exchange-local `Gateway.Lease` reserves time for both a previously in-flight
check and the next check, plus interruption grace, inside that maximum. It runs
independently of backend reads and frontend writes. The HTTP relay checks its
validity before backend I/O and every forwarded chunk. Silent reads wake on
revocation; blocked uploads/downloads are forcibly interrupted within the bound.
A pre-commit failure is native-shaped; a committed response ends incomplete.
The guard monitors the exchange owner, and callback workers also stop if their
owner disappears. No library-owned global process or trust state is created.

Cleanup uses no new grant or connection and closes only gateway-owned local
resources. It never sends operation DELETE/cancel requests and never replays a
possibly accepted mutation. `Gateway.Lease` and `Policy.recheck/3` are reusable
by later adapters. **Only HTTP is verified in G2**, with HTTP/1.1 socket fixtures
and a blocked-chunk adapter. G3 adds the independent WebSocket evidence below;
raw revocation remains in G4.

## Failures

Before a response is committed, the gateway answers with a native-shaped error
whose `metadata.gateway.outcome` states what the backend may have seen:

| outcome | meaning |
| --- | --- |
| `not_sent` | No request bytes reached the backend. |
| `sent` | A GET/HEAD was sent and its response failed. |
| `uncertain` | Request bytes may have reached the backend; a mutation may have been accepted. Reconcile with `/1.0/operations` before retrying. |

`metadata.gateway.operation` carries a known operation URL when one was seen.
Timeouts are `504`, backend failures `502`, admission loss `503`. Admission is
checked again before the backend connection opens and before the request is
sent, so an admission that stopped while the host callbacks ran is reported
`not_sent` with no backend contact.

`max_lifetime` and admission are checked before every backend read and before
each chunk is forwarded, so a busy stream with data already queued still stops
at its deadline.

After a response is committed, the gateway cannot send an error. On HTTP/1.x it
ends the caller's Cowboy connection without a final chunk (Ranch logs the
ended connection), so a truncated body is visibly incomplete; on HTTP/2 it
resets the stream. Frontend loss, deadlines and admission restarts close only
gateway-owned sockets. They never send `DELETE` to an operation or replay a
request.

## Limits

| option | default |
| --- | --- |
| `callback_timeout` | 1 s |
| `idle_timeout` | the connection's `stream_timeout` (60 s) |
| `max_lifetime` | 1 hour |
| `max_request_bytes`, `max_response_bytes` | the connection's `max_stream_bytes` (1 GiB) |
| `max_chunk_bytes` | the connection's `max_chunk_bytes` (64 KiB) |
| `max_header_bytes` | 64 KiB |
| `max_identity_bytes` | 1 MiB (identity/trust request and response bodies) |
| `recheck_interval` | 5 s maximum including callback and interruption budgets |

Long waits such as `/1.0/operations/{id}/wait?timeout=-1` are bounded by
`idle_timeout`; raise it for hosts that need longer waits.

## Not yet in this revision

- Production trust persistence/issuer and host-specific authorization policy.
- Restricted-certificate semantics and asynchronous certificate-token issuance;
  unsupported claims are refused rather than advertised.
- SFTP/NBD (G4) and cross-server migration (G5).
- Immutable consumer, CLI conformance and real-Incus gateway acceptance (G6).

Gateway evidence never changes `priv/incus/coverage.json`.


## Native WebSockets (G3)

The same gateway Plug mounts native `GET /1.0/events` and
`GET /1.0/operations/{id}/websocket` on the host's existing Plug.Cowboy
HTTP/1.1 listener. It negotiates a separate backend WebSocket over the fixed
Unix or verified mutual-HTTPS connection. The original encoded path and raw
query, including operation identity and secrets, survive unchanged; query
secrets are never logged or exposed in gateway status. Caller credentials and
proxy identity headers stay separate from backend TLS credentials.

Admission, readiness, authority and initial grant validity are checked before
opening that backend. Invalid methods, routes, bodies, keys, versions or
subprotocols fail before connection. Native version 13 is supported; HTTP/2
extended CONNECT and subprotocol negotiation fail explicitly. Compression is
not negotiated, so message bytes are preserved independently of wire framing.
The backend must complete a valid handshake before the frontend receives 101.
A bounded native rejection retains its status, error body, ETag and operation
identity, with safe trailers dropped. Nothing retries the initiating exec or
console POST, a channel GET or a redirect.

Exec stdin/stdout/stderr, console data, event JSON and native resize/signal/exit
text retain their message type and payload. Ping/pong are RFC controls local to
each independently negotiated hop: Cowboy answers caller pings with the same
payload; the backend relay answers backend pings. They are distinct from Incus
JSON control messages. Backend close codes/reasons and queued final messages
are preserved. Caller close is propagated locally where possible. EOF or a
gateway failure closes the channel visibly; neither implies that an Incus
operation was canceled or completed. Reconcile with the original native
operation URL and authoritative operation metadata after interruption.

Each channel holds one admission slot until its local relay terminates. The
slot moves atomically from the Plug worker to the relay without reacquiring
capacity or a grant. The long-lived owner is the HTTP/1.1 Cowboy connection.
Handshake worker loss terminates the relay; after a normal worker exit the
frontend must attach within one second. Admission restart, grant revocation,
owner/worker loss and deadlines close local sockets and release capacity.
The same `recheck_interval` maximum applies while data is busy or silent and
while either direction is blocked. A separate bounded frontend close guard
survives relay termination so a nonreading caller cannot strand Cowboy output.

Resource limits are explicit:

- `connection.max_response_bytes` bounds each incoming/outgoing message and
  partial-frame assembly. `max_request_bytes` and `max_response_bytes` bound
  total traffic in each direction, including received protocol framing.
- `connection.queue_limit` bounds decoded frames in one backend batch and the
  waiting backend writer queue. The waiting writer payload bytes additionally
  cannot exceed `connection.max_response_bytes`; at most one extra frame is
  being written.
- Backend reads pause until Cowboy has processed the preceding batch. The
  frontend mailbox receives at most one outstanding backend batch; slow peers
  apply socket backpressure. Reader and writer run independently so blocked
  stdin cannot prevent stdout from draining.
- `idle_timeout` bounds inactivity and blocked writes; `max_lifetime` is an
  absolute channel budget that traffic cannot refresh. Pre-upgrade rejected
  bodies are bounded by the smallest of the gateway response budget, the
  connection message budget and 1 MiB. Backend headers/trailers have a 64 KiB
  aggregate budget, enforced incrementally by Mint and the gateway collector.
- Overflow/framing errors, revocation and deadlines terminate visibly rather
  than silently discarding events or leaving workers alive. Forced termination
  may close the socket without a close frame when a peer is blocked.

`test/gateway_web_socket_test.exs` records protocol, denial, partial-handshake,
large simultaneous duplex, active overflow, both blocked directions, busy and
silent deadlines, TLS separation, ownership and redaction evidence.
`test/gateway_web_socket_reference_test.exs` runs the unchanged pinned Incus
v7.0.1 Go exec, console, events and operation-WebSocket drivers through a
mutual-TLS gateway. Exec output/exit metadata and static/dynamic console results
are compared directly with their backend-fixture baselines. This is fixture
conformance; immutable consumer, real-Incus and installed Macus/hardware
acceptance remain separate. The typed-client coverage ledger is unchanged.
