# Native Incus gateway

`Opsmaru.Incus.Gateway` lets a host relay native Incus HTTP through its own
endpoint under its own policy. This page documents the gateway delivered by
`add-embeddable-incus-gateway` (slices G1–G5): native HTTP, WebSockets and
SFTP/NBD on the host listener, plus operation-scoped migration peer admission.
The capability's requirements are in `openspec/specs/incus-gateway/spec.md`.
Acceptance evidence (G6) is recorded separately; see "Evidence status" below.

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
   corresponding path. Add `admit_operation_secret/2` for narrowly admitted
   migration server peers. These additional callbacks are optional behaviour
   callbacks for source compatibility; missing callbacks have no permissive fallback.

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
   HTTP `GET /`, `GET /1.0`, token enrollment via `POST /1.0/certificates`,
   or the explicit operation-secret decision documented below.
   Other denials remain denials. A late answer is discarded. For an authorized
   grant, `valid?/3` must return exactly `true` before backend access.
5. Protocol: native WebSockets negotiate after authorization when their
   optional adapter is available. SFTP/NBD require the same-listener Cowboy
   companion below; a direct Plug raw upgrade gets an explicit `501` after
   the same policy check. Unsupported adapters fail explicitly after authorization.

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
addresses contain only host-approved `host:port` authorities. By default
(`identity_scope: :public`) they must be public: literal private, loopback and
link-local IPs, `localhost` and single-label names are refused. A host whose
gateway listens on loopback or a private network passes
`identity_scope: :local` to `Gateway.new!/1`; its identity may then also use
loopback and private-network IPs (`127.0.0.0/8`, `::1`, `10.0.0.0/8`,
`172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `fc00::/7`), `localhost`,
`*.localhost` and single-label names. In both scopes unspecified, link-local,
multicast and reserved IPs, IPv4-mapped IPv6 addresses, socket names, paths and
credentials are refused, and the guest's own addresses are never served.
The host is responsible for DNS and for supplying the gateway listener's
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
implemented-extension allowlist. The allowlist has three parts.

Plain HTTP: request fields, query parameters and routes the gateway already
relays unchanged. Backups and ISO uploads stream through the same relay and are
bounded by `max_request_bytes`, `max_response_bytes` and `max_lifetime`.

- Discovery, trust and instances: `certificate_update`, `instances`,
  `api_filtering`, `instance_get_full`, `instance_create_start`,
  `file_delete`, `images_push_relay`.
- Projects: `projects`, `project_usage`, `projects_force_delete`,
  `container_copy_project`, `instance_project_move`,
  `storage_volume_project_move`.
- All-projects listings: `images_all_projects`, `instance_all_projects`,
  `network_acls_all_projects`, `network_zones_all_projects`,
  `networks_all_projects`, `operations_get_query_all_projects`,
  `profiles_all_projects`, `storage_buckets_all_projects`,
  `storage_volumes_all_projects`.
- Storage pools, volumes and buckets: `storage`, `storage_api_project`,
  `storage_api_volume_rename`, `storage_api_volume_snapshots`,
  `storage_volume_full`, `storage_volume_state`, `storage_volumes_rebuild`,
  `custom_volume_refresh`, `custom_volume_refresh_exclude_older_snapshots`,
  `storage_buckets`, `storage_bucket_full`,
  `storage_buckets_create_credentials`, `instance_pool_move`.
- Networks: `network`, `network_acl`, `network_acl_log`,
  `network_address_set`, `network_allocations`, `network_dns`,
  `network_dns_records`, `network_forward`, `network_integrations`,
  `network_leases`, `network_load_balancer`, `network_load_balancer_state`,
  `network_peer`, `network_state`, `instance_nic_network`.
- Instances, files and snapshots: `container_full`, `container_edit_metadata`,
  `container_exec_user_group_cwd`, `container_exec_recording`, `dependent`,
  `directory_manipulation`, `file_append`, `file_symlinks`,
  `instance_bulk_state_change`, `instance_move_config`,
  `instance_snapshot_disk_only_restore`, `instances_rebuild`,
  `instances_debug_repair`, `snapshot_expiry`, `snapshot_expiry_creation`.
- Copy options (also checked by the pinned client for same-server copies):
  `container_incremental_copy`, `container_only_migration`,
  `instance_allow_inconsistent_copy`.
- Images: `image_compression_algorithm`, `image_copy_profile`,
  `image_create_aliases`, `image_force_refresh`.
- Server information: `resources`, `resources_v2`, `warnings`,
  `metadata_configuration`.
- Backups and ISO uploads: `container_backup`,
  `container_backup_override_pool`, `backup_override_config`,
  `backup_override_name`, `custom_volume_backup`, `storage_bucket_backup`,
  `direct_backup`, `custom_volume_iso`.

WebSocket (only with the WebSocket adapter): `console`, `console_force`,
`container_push`, `container_push_target`, `container_snapshot_stateful_migration`,
`storage_api_local_volume_handling`, `storage_api_remote_volume_handling` and
`storage_api_remote_volume_snapshot_copy`. `console_force` is the `force` field
of a console request whose stream is the console operation WebSocket. The
pinned client checks `container_snapshot_stateful_migration` only when live
migrating a stateful snapshot, and `storage_api_remote_volume_snapshot_copy`
only when migrating a volume snapshot, which already requires
`storage_api_remote_volume_handling`.

Raw upgrade (only with the same-listener Cowboy companion): `instance_nbd`,
`custom_volume_sftp`, `storage_volume_nbd`.

`api_filtering` and `instance_get_full`
are query-parameter features on instance routes the gateway already forwards
unchanged; they let the pinned client list instances with a `filter` query and
read one instance with `recursion=1`. `instance_create_start` is the `start`
field of the `POST /1.0/instances` body, which the gateway forwards unchanged;
the pinned client always sends it for `incus launch` and, when the extension is
not advertised, follows with its own start that an already started instance
refuses. The two storage extensions let the pinned client copy custom
volumes through the gateway in relay, pull and push modes; volume migration
uses the same operation WebSocket negotiation and peer admission as instance
migration. `images_push_relay` lets the pinned client push an image from the
gateway (`ExportImage`); see "Image copy and image-secret peers". Protocol
extensions are filtered out when the corresponding optional adapter is absent.
The host must approve only protocols it actually mounts and a verified backend
supports; raw extensions require the same-listener Cowboy companion. Merely
installing an adapter does not authorize a protocol. Restricted-certificate
and token issuance gaps are listed under "Not provided by the library".

Extensions the gateway must never advertise, and why:

- `cluster_internal_copy`, `cluster_internal_custom_volume_copy`,
  `cluster_member_state`, `cluster_migration_inconsistent_copy`, `clustering`,
  `clustering_edit_roles`, `clustering_evacuation`,
  `clustering_failure_domains`, `clustering_groups`, `clustering_join`,
  `clustering_join_token`, `clustering_update_cert` — clustering would change
  the appliance's network identity/certificate behind the gateway;
- `certificate_token` — server-side trust tokens; the gateway owns
  `/1.0/certificates` and refuses `"token": true`;
- `metrics` — also gates `incus config trust add --type=metrics`, while
  gateway trust holds only client certificates (`/1.0/metrics` itself still
  relays);
- `project_access`, `instance_access` — report the guest's own authorization,
  not gateway trust;
- `console_vga_type` — SPICE over the console WebSocket; it stays hidden until
  a test proves the relay carries it;
- `instance_nvram`, `instance_nvram_bulk_update`, `instance_port_forward`,
  `instance_refresh_migration` — newer than guest Incus 7.0.1.

`file_delete` covers the native HTTP file DELETE route. Its advertisement still
requires both verified backend support and host approval. The pinned native
client's complete binary create/get/delete lifecycle is checked through the
verified TLS gateway, including encoded file queries and the original DELETE;
raw file relay alone does not bypass this client-side capability check.

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
and a blocked-chunk adapter. G3 adds the independent WebSocket evidence below.
G4 verifies the same lease through raw takeover, including silent streams and
blocked writes.

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

## Exchange telemetry

When the host runs `:telemetry` (every Plug host does) and attaches a handler,
the gateway emits one pair of events per exchange. That covers native HTTP,
locally served discovery and trust, WebSocket and SFTP/NBD upgrades, and
requests refused before admission. `:telemetry` is an optional dependency: a
client-only consumer compiles without it. The library attaches no handler,
writes no log and defines no metrics. With no handler attached to the
`[:opsmaru_incus, :gateway, :exchange]` prefix, no observer process or table
is created; a handler attached while an exchange is in flight sees only later
exchanges.

| Event | Measurements | Emitted from |
| --- | --- | --- |
| `[:opsmaru_incus, :gateway, :exchange, :start]` | `system_time`, `monotonic_time` | the adapter process (Plug request process or Cowboy handler), before policy runs |
| `[:opsmaru_incus, :gateway, :exchange, :stop]` | `duration`, `request_bytes`, `response_bytes` | a per-exchange observer process, once, when the exchange ends |

The stop event is emitted exactly once, at the real end of the exchange. The
observer monitors the process that owns the exchange: the Plug request process,
then the WebSocket relay after the upgrade commits, or the raw relay after the
SFTP/NBD handoff. A relay killed for revocation, a deadline or a lost caller
still reports its duration, bytes and reason. Stop handlers run in the
observer, never in a process holding a backend socket, so a slow handler
cannot hold a socket open, delay a relay or use up its deadline. A start
handler runs in the adapter process before admission, so it should be cheap.
Correlate the pair with `telemetry_span_context`.

Start metadata:

| Key | Value |
| --- | --- |
| `telemetry_span_context` | a reference shared by the pair |
| `host` | the gateway's host module, or `nil` when the gateway could not be resolved |
| `protocol` | `:http`, `:websocket` or `:raw` |
| `method` | the HTTP method when it is `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE` or `OPTIONS`, otherwise `nil` |
| `peer_address`, `peer_port` | the caller's address and port, as the server adapter reports them |
| `peer_fingerprint` | lowercase hexadecimal SHA-256 of the certificate the caller presented, or `nil`; it names a presented certificate, not a trusted identity |

Stop metadata is the start metadata plus:

| Key | Value |
| --- | --- |
| `path` | the original encoded path once the route check accepted it (at most 8192 bytes), otherwise `nil` |
| `project`, `target`, `all_projects`, `operation` | the parsed native selection and operation ID; `nil`/`false` when the request was refused before parsing |
| `admitted_as` | `:caller`, `:anonymous`, `:operation_peer`, `:image_peer`, or `nil` when the request was not admitted |
| `status` | the HTTP status of the response head sent to the caller (`101` for a completed upgrade), or `nil` when none was sent |
| `outcome` | `:ok` when the exchange completed as relayed or served, whatever the native status; otherwise what the backend may have seen: `:not_sent`, `:uncertain` or `:sent` |
| `reason` | `nil` when `outcome` is `:ok`, otherwise one of the reasons below |

`request_bytes` and `response_bytes` count body bytes read from and written to
the caller: HTTP bodies (including gateway error bodies), WebSocket text and
binary frame payloads, or tunnelled SFTP/NBD bytes. Header and framing bytes
are not counted.

| `reason` | Meaning |
| --- | --- |
| `:invalid_request` | non-canonical path, ambiguous selection, framing, body or handshake, or a route the gateway does not serve |
| `:not_configured` | the gateway could not be resolved, has no Cowboy fallback, or is mounted behind a body parser |
| `:capacity` | admission is full |
| `:not_ready` | the host is not ready, admission or identity is unavailable |
| `:unauthorized` | the host denied the request, or an image peer sent something other than its upload |
| `:unsupported` | the protocol, adapter or certificate action is not available |
| `:revoked` | the grant expired or was revoked during the exchange |
| `:admission` | the admission process stopped during the exchange |
| `:idle` | the caller or backend was silent for `idle_timeout`, or a request body did not arrive in time |
| `:lifetime` | `max_lifetime` expired |
| `:limit` | a path, query, header, body, frame or queue limit was exceeded |
| `:backend` | the backend could not be reached, failed, or sent an invalid response |
| `:caller_closed` | the gateway saw the caller's connection close or fail before the exchange completed |
| `:killed` | the owning process ended without recording a reason |

A completed WebSocket close handshake from either side, or both halves of a
raw tunnel closing, is `outcome: :ok`. Reasons are assigned where each
failure is built and never derived from error messages.

Metadata never contains the `authorization` header or any other header, the
raw query string (which carries operation and image secrets and unbounded
filters), image secrets or fingerprints, request or response bodies,
WebSocket frames, the host's grant or `host_config`, backend addresses or
credentials, or native and gateway error messages. A host that needs a
principal derives it from `peer_fingerprint` and `admitted_as` or from its own
state.

Handlers are global to the VM, so any code in the host can read these paths
and peer addresses. Do not send `path` to a destination less private than the
host's own request log. `:telemetry` detaches a handler that raises, after
which a log built on it silently stops; a host that treats the log as a record
should rescue inside its handler. Emission never changes admission, relayed
bytes, responses, deadlines, revocation or retry decisions.

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

## Evidence status

Each evidence class is recorded separately, and none substitutes for another:

- **Fixtures and pinned-client conformance:** the portable suites described on
  this page, plus the unchanged pinned v7.0.1 CLI matrix (18 successful cases
  and six accepted snapshot-move limitations). See `docs/gateway-acceptance.md`.
- **Package consumer:** `mise run check:consumer` builds the Hex package and
  compiles it in a fresh Phoenix consumer on Linux and macOS. See
  `docs/gateway-acceptance.md`.
- **Real Incus:** the explicit isolated gate passed 28 of 35 cases on
  2026-11-09, including every copy mode in both gateway orientations. Snapshot
  move is the accepted pinned-native limitation, and NBD stays `unrun` under an
  accepted limitation that is planned for a later revisit. See
  `docs/gateway-real-incus-acceptance.md`.
- **Installed host and Macus hardware:** unrun here. These belong to the
  consumer that mounts the gateway.

Gateway evidence never changes `priv/incus/coverage.json`.

## Not provided by the library

- Production trust persistence/issuer and host-specific authorization policy.
  The embedding host owns these.
- Restricted-certificate semantics and asynchronous certificate-token issuance;
  unsupported claims are refused rather than advertised.


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
Its grace is the same `min(50, recheck_interval / 4)` milliseconds reserved by
the lease, retaining the host-tightened revocation bound.

Host grant callbacks run at negotiation and commitment boundaries. Once a
channel is active, reads and caller messages check the independent lease;
they do not invoke host policy on every frame or quiet read poll. Periodic
lease checks still enforce the configured expiry/revocation bound.

Resource limits are explicit:

- `connection.max_response_bytes` bounds each incoming/outgoing message and
  partial-frame assembly. `max_request_bytes` bounds relayed caller payload
  bytes; `max_response_bytes` bounds backend bytes including received framing.
- `connection.queue_limit` bounds decoded frames in one backend batch and the
  waiting backend writer queue. At half the writer queue count or byte budget,
  the adapter pauses inbound Cowboy socket reads; it resumes after both fall
  to a quarter. Reverse output and revocation/deadline handling remain active.
  Half the capacity is reserved for frames Cowboy has already received and
  continues parsing after a pause. Excessive coalesced bursts still terminate
  at the hard cap, including with deliberately tiny queue limits. The waiting
  writer payload bytes additionally cannot exceed `connection.max_response_bytes`; at most one extra frame is
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
conformance; package consumer, real-Incus and installed Macus/hardware
evidence are recorded separately (see "Evidence status"). The typed-client coverage ledger is unchanged.

## Native SFTP/NBD on the host listener (G4)

Configure a catch-all Cowboy dispatch entry in the existing host endpoint's
listener options. The companion delegates ordinary HTTP and WebSocket requests
to the host handler, including the original protocol-upgrade callback identity:

```elixir
opts = %{
  gateway: {MyHost.GatewayConfig, :current, []},
  fallback: {Plug.Cowboy.Handler, {MyHostWeb.Endpoint, MyHostWeb.Endpoint.init([])}}
}

dispatch = :cowboy_router.compile([
  {:_, [{:_, Opsmaru.Incus.Gateway.CowboyHandler, opts}]}
])
# Supply dispatch under the existing listener's protocol_options.env.
# The library starts no listener and changes no global host/ALPN setting.
```

A static `%Gateway{}` is also accepted. Missing/invalid/dying configuration
resolvers fail closed with native `503`. The host remains responsible for
listener TLS, verified client certificates and policy. Raw takeover requires
HTTP/1.1; an HTTPS host must permit `http/1.1` in ALPN. Requests negotiated as
HTTP/2 cannot use this raw upgrade path. Ordinary host HTTP/2 traffic can still
use the fallback handler. Client-only consumers compile without any of the
Cowboy handler, raw relay or tunnel modules.

The companion accepts only body-free GETs with a matching `Upgrade: sftp` or
`Upgrade: nbd`, valid `Connection` tokens including `upgrade`, and these routes:

- `/1.0/instances/{name}/sftp` and `/1.0/instances/{name}/nbd`
- `/1.0/storage-pools/{pool}/volumes/{type}/{name}/sftp` and the corresponding
  `/nbd` route

Encoded segments and the complete original query (including project/member,
`reuse` and `writable`) are preserved. The shared policy authorizes the actual
peer, readiness and selected authority before any backend connection. Caller
credentials/proxy fields and `x-incus-authenticated` are stripped; only the fixed
backend connection can supply its authenticated assertion and TLS credentials.
Malformed methods, versions, bodies, route/protocol combinations or response
headers cannot switch the connection. Native non-101 rejection status, body,
operation identity and safe end-to-end headers reach the caller without retry.

One relay actor holds admission, lease and backend ownership throughout
negotiation and takeover. The actor monitors the HTTP request worker until an
acknowledged bounded handoff, then monitors the original Cowboy connection.
Cowboy transfers frontend ownership to that same actor. Its prefetched client
buffer and the backend's prefetched 101 bytes are delivered exactly once as
opaque bytes, without WebSocket framing. A failed takeover closes the backend
and releases admission; neither an HTTP worker exit nor an admission restart
can leave an untracked raw connection.

Each direction has one writer and at most one outstanding read delivery. A read
is rearmed only after its bytes are written, so slow peers exert backpressure
without an unbounded mailbox or a duplex write deadlock. Chunks use
`max_chunk_bytes`; each direction uses the corresponding request/response byte
budget. Writes, silence, takeover and Unix half-close drain have finite bounds
from `idle_timeout`, the backend connection timeout and the absolute
`max_lifetime`. Lifetime starts before policy callbacks and includes connect,
negotiation and takeover; busy traffic cannot refresh it. Expiry/revocation and
admission loss terminate even blocked reads/writes within the configured lease
bound. Cleanup closes only local sockets/workers and never replays a request,
opens another backend, sends operation DELETE or implies workload cancellation.

TCP/Unix read EOF leaves its opposite write direction usable during finite
drain. OTP TLS `close_notify` ends that TLS connection, so further writes on
that peer are unavailable; this is the same explicit transport limitation as
the native client foundation.

`test/gateway_raw_upgrade_test.exs` records isolated fixture evidence: verified
HTTPS gateway/backend trust, the unchanged pinned Incus v7.0.1 instance/volume
SFTP/NBD helpers and pkg/sftp binary operations, denied requests, native errors,
coalesced bytes, duplex backpressure and lifecycle limits. The pinned Go
`rawConn` loses bytes prefetched by net/http: official-helper greetings are
therefore delivered separately under the existing approved oracle exception.
Independent opaque-byte tests coalesce both handshake directions and require
exactly-once preservation. These checks are gateway evidence; they do not
change typed-client coverage or claim real-Incus, installed Macus or hardware
acceptance.


## Cross-server migration and operation-secret peers (G5)

The gateway relays the native migration requests and operation channels; the
pinned client and backend own the copy/move workflow. Relay opens both sides'
operation WebSockets through their respective gateways. Pull from a gateway
source and push to a gateway target cause the other Incus server to connect to
that gateway. Pull to a gateway target and push from a gateway source require
the guest backend to reach the other endpoint itself. A native guest network
failure passes through unchanged; the gateway never follows a private address,
replays the migration request or substitutes another transport.

Hosts can implement this optional callback:

```elixir
@impl true
def admit_operation_secret(request, config) do
  # Resolve the ID from host-owned, verified pending migration state. Bind the
  # stored backend/project/target and allowed peer to this exact exchange.
  config.pending_migrations.authorize_operation_peer(request)
  # Return {:ok, opaque_grant} or {:error, :forbidden}.
end
```

The callback runs only when ordinary `authorize/2` explicitly returns
`{:error, :unauthenticated}`. Explicit forbidden decisions and failed ordinary
callbacks never fall through. The gateway additionally requires a WebSocket
GET on exactly `/1.0/operations/{id}/websocket`, one nonempty decoded `secret`
query parameter, no extra path segments or encoded slash in the ID, and no
all-projects selection. Missing/denied/malformed/late callbacks return `403`
before any backend access. Duplicate or malformed project selections return
`400`; duplicate secrets, including encoded duplicate keys, cannot use this
admission path. The backend validates the original secret after the host's
allow decision, and the original path/query are relayed without reconstruction.

The pinned v7.0.1 server's migration dialer pins the remote certificate but
normally presents **no client certificate**. Its peer certificate may therefore
be `nil`. The host listener must permit certificate-less TLS handshakes while
ordinary host authorization continues to deny untrusted callers. Configure
certificate verification for presented client certificates according to the
host's trust policy; this callback does not weaken the TLS listener itself.

The native operation WebSocket helper also omits a project query even for a
nondefault-project operation. The host must resolve an omitted project from
its verified pending operation binding, rather than infer default-project
permission. An explicit conflicting project/target or another operation must
deny. Do not authorize an operation merely because it has a secret parameter,
a peer address or a certificate. The host's returned grant uses the same
`valid?/3`, revocation lease, admission and resource budgets as ordinary calls;
cleanup never acquires fresh authority or remotely cancels the migration.

`Request`/gateway inspection and generated errors redact credentials; hosts
must also keep secrets out of their logs and grants. Native backend response
bytes remain native and are not rewritten as gateway diagnostics.

Portable fixtures exercise unchanged pinned `CopyInstance` and
`CopyInstanceSnapshot` with stopped instances and stateless snapshots in all
three modes through both gateway endpoints, public connection-info addresses/certificate, binary control/fs channels, certificate-less
server peers and omitted nondefault-project selection. Separate interruption
fixtures isolate one frontend exchange from client-owned orchestration and
prove at most one backend POST with no gateway DELETE after frontend loss or
an uncertain reply. The pinned client itself owns its multi-public-address
attempts and explicit cancellations; those are distinct incoming requests,
not gateway retries. Unmodified CLI copy/move, package consumer and
real-Incus results are recorded separately (see "Evidence status"); installed
Macus/hardware evidence belongs to the consumer.

The G5 matrix verifies default copy behavior. Live migration, CRIU/stateful
snapshots and optional flags such as instance-only/refresh are not gateway
acceptance evidence in this slice. Their extension names are allowlisted where
the gateway already forwards the routes (for example `container_only_migration`,
`container_incremental_copy`, `instance_allow_inconsistent_copy` and
`container_snapshot_stateful_migration`, plus the refresh flags in the storage
and instance groups), so hosts that approve them advertise them; the lack of
acceptance evidence is what keeps this slice incomplete. This is an explicit
gateway verification gap, not a claim that the backend or host lacks those
features.

Custom storage volumes use the same negotiation. The pinned
`CopyStoragePoolVolume` copies a volume in all three modes through both gateway
endpoints with the same assertions as instances: public connection info, one
POST per side and no DELETE, the expected channels, and peer admission only to
the named operation WebSocket. Interrupted volume source and target requests
are never replayed or cancelled.

The pinned v7.0.1 CLI has a separate snapshot-move limitation: its shared
copy/move code recognizes snapshot sources only for the `copy` command. For
`move source/snapshot`, it instead requests
`GET /1.0/instances/source%2Fsnapshot`; the pinned server returns `400 Invalid
instance name` before any migration request or source deletion. The portable oracle preserves this rejection
rather than making the CLI pass against a permissive fake server. Successful
snapshot move is recorded as a pinned native limitation under the explicit
2026-11-07 user decision accepting that outcome as parity. The gateway does
not rewrite this route or add a compensating mutation, and successful snapshot
move is not claimed.

## Image copy and image-secret peers

Image copy does not use an operation WebSocket. The Incus servers still move
the image, but over plain HTTP routes that carry a one-time secret:

| Mode | Gateway side | Server peer requests reaching the gateway |
| --- | --- | --- |
| relay | either | none: the caller downloads and uploads over its own authenticated connections |
| pull | target | none: the guest's Incus dials the source |
| pull | source | `GET /1.0/images/{fp}?secret=` then `GET /1.0/images/{fp}/export?secret=` |
| push | source | none: the caller's `ExportImage` needs `images_push_relay`; the guest's Incus dials the target |
| push | target | `POST /1.0/images` with `X-Incus-secret` and `X-Incus-fingerprint`, then `GET /1.0/operations/{id}/wait?secret=` |

For the last two rows, implement the optional `admit_image_secret/2` callback:

```elixir
@impl true
def admit_image_secret(request, config) do
  # request.image is %{route: :info | :export | :upload | :wait, fingerprint: fp | nil}.
  # Bind the route, fingerprint or operation, project, target and peer to a
  # pending image transfer the host verified, never to the request alone.
  config.pending_images.authorize_peer(request)
  # Return {:ok, opaque_grant} or {:error, :forbidden}.
end
```

It runs under the same conditions as `admit_operation_secret/2`: only after
`authorize/2` explicitly returns `{:error, :unauthenticated}`, only for the
exact routes above with one nonempty secret, a lowercase hexadecimal
fingerprint of at most 64 characters and no all-projects selection. An upload
must carry exactly one `X-Incus-secret` and one `X-Incus-fingerprint` header
and no `secret` query, and its body must be the image itself: the pinned
server picks the action of `POST /1.0/images` from the body, whatever the
content type, so the gateway returns `403` before backend access when an image
peer's body is empty or starts with JSON whitespace or `{` (an image request
that could make the backend fetch from a server the peer chooses, publish an
instance or mint a token). A caller that `authorize/2` admits is not limited
this way. Missing, denied, malformed or late callbacks return
`403` before backend access, so a host without the callback keeps refusing
these routes. The operation WebSocket keeps its own callback; neither callback
is consulted for the other's routes. The grant is rechecked by `valid?/3`
like any other.

**Verify the secret in the host.** Unlike a migration WebSocket secret, an
image secret is not checked by the backend here: the gateway's backend
connection is trusted (the Unix socket, or HTTPS with a trusted client
certificate), and the pinned v7.0.1 server serves a trusted caller's image
info, export and upload whatever secret it carries. `request.image.secret`
holds the decoded secret (redacted from `inspect/2`). Compare it in constant
time with the backend's pending operation, as incusd's `imageValidSecret` does
for untrusted callers: for `:info`, `:export` and `:upload`, a `token`-class
operation whose `images` resource starts with `/1.0/images/{fp}` and whose
`metadata.secret` matches (incusd still allows it after the first use cancels
it); for `:wait`, the named operation's `metadata.secret`. The gateway forwards
the secret unchanged, so the backend still consumes the single-use token.

The pull source's secret comes from `POST /1.0/images/{fp}/secret`, and the
push target's from a push-mode `POST /1.0/images`; an authorized caller sends
both through the gateway, so the host can record the pending transfer. The
pinned server peer presents no client certificate and, for a pull, sends the
caller's source project.

Portable fixtures exercise the unchanged pinned `CopyImage` in all three modes
through both gateway endpoints. The server-to-server leg runs the unchanged
pinned client calls of incusd's pull download (`ConnectPublicIncus`,
`GetPrivateImage`, `GetPrivateImageFile`) and export push (`ConnectIncus`,
`CreateImage` with the secret, `GetOperationWaitSecret`). They check public
connection info, which routes each peer reaches, the delivered bytes and that,
without the callback, pull and push are refused before the peer reaches the
backend. Public images pulled without a secret are not admitted.
