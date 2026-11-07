# Design

## Context

See [proposal.md](proposal.md). The archived foundation provides passive embedding, explicit Unix/verified HTTPS connections, bounded outgoing HTTP/transfers/WebSockets/raw channels and native models/operations; task 3.9 closed against the endpoint inventory and task 4.3 passed on real Incus. The archived `add-incus-operations` change added protocol-neutral operation descriptors and removed its optional TamaMCP binding before any consumer pinned it. Nothing under `Opsmaru.Incus.Gateway` exists yet; `plug` is a test-only dependency and `cowboy` is absent.

Macus has an endpoint without a shared body parser, an empty JSON API scope and proxy/auth boundary stubs. Its test-only Cowboy handler uses `switch_protocol` and `takeover/7` to transfer socket ownership and forward both client and backend prefetched bytes. This is reusable protocol evidence, not installed gateway authentication or hardware acceptance. Macus source is not changed here.

Plug.Cowboy 2.9.0's adapter supports `:websocket` upgrades and returns `:not_supported` for other protocols. A Phoenix `forward` declaration is sufficient for request dispatch but not the entire native Incus protocol surface. The typed `HTTP.request` facade buffers responses and parses/re-encodes native selection queries, so it cannot serve as a transparent streaming reverse proxy without separate relay mechanics.

## Goals / Non-Goals

**Goals:** one reusable native gateway with a small host mounting/policy contract; cross-server migration through the gateway at pinned Go client parity; an independent fixture and isolated real-Incus acceptance path in this repository; clear evidence boundaries and preserved host/backend ownership.

**Non-Goals:** a workload manager, per-method REST facade, central endpoint/registry/MCP/OIDC/connector behavior, an MCP binding for the shared operations, production trust store or issuer, background application tasks, installation, VM lifecycle, host commands, Macus source changes or automatic real-backend provisioning/activation.

## Decisions

### 1. Library component with optional server adapters

Put reusable code under `lib/opsmaru/incus/gateway/` in the `:opsmaru_incus` library, using `Opsmaru.Incus.Gateway` namespaces for configuration/host contract, relay, Plug, WebSocket and Cowboy raw protocol handling. Do not introduce another package, application callback, process or server. Declare `plug` and `cowboy` as `optional: true` dependencies (ranges compatible with the consumer-locked baseline) and wrap gateway modules in `Code.ensure_loaded?/1` guards, so client-only consumers do not inherit a web stack and still compile warning-free. Keep transport internals isolated so adapters can evolve independently.

Macus mounts the component in its own router/endpoint and configures the companion Cowboy dispatch on the same listener. The test harness uses an explicitly started host-owned fixture endpoint. This harness is not a production application mode or service. Central Opsmaru does not mount the gateway; it is an operation gateway, not a native `/1.0` proxy.

Alternative: controllers per native Incus method couple proxy coverage to the typed-client catalogue and risk changing wire behavior. A transparent relay preserves backend extensions without relabeling typed-client coverage.

### 2. Immutable configuration and host policy

Construction accepts a fixed host-selected backend `Connection`, resource limits, an explicitly selected host adapter (a behaviour module) and opaque private configuration. Validation is passive. Host callbacks receive normalized bounded request metadata and actual peer identity from the server adapter; request body/query/headers cannot provide a verified principal or alternative remote. Configuration/Inspect/process status must redact addresses, credentials, private references and transport secrets.

Native project/member defaults and supplied query selections are evaluated against host authority without silently injecting a typed client's default selection or re-encoding the raw query. Conflicting, ambiguous or unauthorized selectors fail before backend access. Backend capability metadata is host-supplied from explicit verified inspection, bound to the selected connection and combined with the gateway's implemented protocol support; anonymous identity handling never probes a backend to build that metadata.

The host contract supplies authorization/caller binding, readiness, allowed project/member/operation authority, advertised gateway identity (public origin and certificate), narrow discovery/trust handling, operation-secret admission and an expiry/revocation decision. Missing adapter/callbacks deny before connection. The gateway enforces that contract and the configured connection binding; callbacks run under bounded budgets and cannot authorize work after their deadline. All HTTP, WebSocket and raw-upgrade paths share this policy code, including paths dispatched before Phoenix pipelines.

This change does not implement a production credential registry or issuer. The independent host fixture supplies test certificate enrollment and trust in isolated ephemeral state. Production Macus policy, certificate/bearer storage and administration remain Macus-owned. User/gateway credentials are stripped before backend relay; explicitly configured backend HTTPS credentials remain distinct. An optional verified gateway/backend restriction cannot be advertised unless it is enforced before privileged Unix access; initial fixture enrollment uses explicit owner-admin authority and rejected restricted-certificate cases.

Default revocation/expiry rechecks for active channels are bounded to at most five seconds; hosts may tighten the interval. Backend/worker cleanup never requires a new authorization grant. A bounded admission supervisor is explicitly host-started when mounting, rather than automatically created on dependency load. Rejected admission opens no backend and queues no unbounded work.

### 3. Canonical routing and narrow identity mediation

Expose native `/`, `/1.0` and `/1.0/*`; keep host `/runtime` and `/mcp` routes outside this component. The HTTP Plug can be forwarded at `/1.0` with a separate root discovery mount. Preserve the original encoded request path and raw query despite `forward` modifying `path_info`; do not reconstruct resource paths from decoded Phoenix params. No `/incus` prefix aliases are promised. Native routes bypass blanket JSON body parsing and JSON-only content negotiation.

Explicit allowlisted discovery, `/1.0` identity and `/1.0/certificates` enrollment/trust actions delegate to host policy rather than blindly forwarding privileged guest trust. Anonymous discovery is synthetic, bounded and backend-free. In authenticated `GET /1.0` responses the gateway replaces `environment.addresses` with the host-approved public addresses and `environment.certificate` with the advertised gateway certificate, and omits private socket/guest-NAT addresses; other environment fields and workload payloads pass unchanged. Unknown native routes do not bypass authorization; authenticated backend-native failures stay native.

### 4. Cross-server migration at Go client parity

The pinned v7.0.1 client builds migration endpoints from `GetConnectionInfo()`: the connection URL first, then `https://` plus each `environment.addresses` entry, with the certificate pinned for that connection. Through the gateway that yields the gateway URL and certificate, followed by whatever addresses `GET /1.0` advertises. Decision 3's rewrite makes that list contain only host-approved public addresses, so no mode falls back to a guest address.

| Mode | Gateway is source | Gateway is target |
| --- | --- | --- |
| Relay | Client opens the source operation WebSockets through the gateway (Decision 5 relay) | Client opens the target operation WebSockets through the gateway |
| Pull | The other server connects to the gateway's operation WebSocket with the operation secret | Guest backend connects out to the source; gateway relays only the request |
| Push | Guest backend connects out to the target; gateway relays only the request | The other server connects to the gateway's operation WebSocket with the operation secret |

The pinned Incus server's migration dialer pins the remote certificate but normally presents no client certificate. The pinned client's operation WebSocket helper also omits project selection, even for nondefault-project operations. The host therefore resolves the named operation to its own verified pending migration and project, rejects any explicit conflicting project/target selection, and uses the actual adapter peer (which may have no certificate) as policy input rather than caller trust. The gateway admits these otherwise unauthenticated peers only on `GET /1.0/operations/{id}/websocket?secret=…` and only after an explicit host `admit_operation_secret` decision for that operation, its project and the peer; the backend still validates the secret. Admission never grants any other route. When the guest cannot reach the other server (pull target, push source), the failure is a backend network limitation reported natively, not a gateway fallback. Operation-scoped secrets are redacted from diagnostics.

Unsupported cases must identify an actual backend or verified host-policy limitation. An unimplemented relay/negotiation path is recorded as missing gateway implementation and cannot count as a passed acceptance case or be hidden by capability filtering.

User decision (2026-11-07): the pinned CLI recognizes snapshot source syntax only for `copy`; snapshot `move` requests the root instance route and receives native `400 Invalid instance name` before migration. Preserve and explicitly classify this limitation as pinned native parity, with no compensating gateway mutation. The default CLI matrix records 18 successful cases and six native limitations rather than claiming 24 successful transfers.

### 5. Three protocol paths on one listener

| Protocol | Server integration | Backend handling |
| --- | --- | --- |
| Native HTTP and archives/files | Mountable Plug | Passive streamed Unix/HTTPS relay with acknowledged bounded chunks |
| Exec/console/events/migration WebSockets | Plug plus native WebSocket handler | Bounded bidirectional control/data relay preserving message semantics |
| SFTP/NBD raw upgrades | Cowboy handler/protocol switch | Native HTTP 101 validation, socket takeover and raw duplex traffic |

The host configures Cowboy dispatch for raw upgrades, with ordinary traffic reaching the Phoenix router. Matching is limited to known native upgrade routes/protocols/methods; HTTP/1.1 is required for the raw takeover path. Reject unsupported versions, bodies, malformed connection/upgrade tokens and unsafe response headers before takeover. Document host listener/ALPN requirements without modifying global host settings or opening another listener.

Transferred Macus fixtures require recorded source/transferred hashes and existing Incus notices; do not copy Macus policy, Swift code or active implementation. Socket ownership moves to the takeover process, which forwards both prefetched buffers exactly once and never re-enters Cowboy's HTTP state machine after termination. Preserve supported half-close with finite drain deadlines and bounded writes. WebSocket relay preserves message/control semantics without claiming identical masked wire bytes between independently negotiated connections.

### 6. Transparent HTTP and truthful failure

Reuse suitable foundation framing, TLS trust and lifecycle primitives, adding an incoming streamed relay instead of routing every request through `Incus.call` or the buffered HTTP facade. Preserve end-to-end statuses, errors, ETags, duplicate headers where applicable, query ordering/encoding, native operation URLs, binary data and trailers. Remove hop-by-hop headers according to connection tokens; validate framing and header budgets to prevent ambiguity/injection. Apply byte/deadline/queue/admission limits through both directions and every callback.

Record the transition where request bytes may have reached the backend. Do not retry mutations on timeout, disconnect, redirects or malformed responses; do not auto-follow another origin. Before a response is committed, emit a bounded truthful native-shaped gateway failure including a known operation identity when available; after HTTP upgrade or committed output, close the stream and require reconciliation rather than emitting another HTTP response. Do not claim backend cancellation or delete remote operations because the frontend closed. Cleanup stops only gateway-owned sockets/workers; caller-owned destination files and backend resources remain intact.

### 7. Acceptance without Macus or central services

Maintain four distinct evidence layers:

1. Database-free fake Unix/HTTPS gateway protocol fixtures on macOS/Linux, including TLS peer policy, wrong credentials, denial counters, framing, transfers, upgrades, bounds, redaction, revocation, operation-secret admission and uncertain mutations.
2. An independent immutable Git consumer with its own endpoint/policy mounting the gateway and the library remaining passive under hostile PHX_SERVER/PORT, plus the existing client-only consumer proving no web stack is required. Run the unmodified official client/CLI at the existing v7.0.1 reference pin; any built CLI is verifier-only, with exact hashes and isolated INCUS_CONF.
3. Explicit isolated real-Incus tests in this repository: native CLI/client interactions through the mounted gateway, including relay/pull/push copy against a second authorized backend or project, recorded separately from the foundation's direct typed-client evidence. No Macus build or runtime is needed. A fixture host demonstrates portable policy mechanics, not Macus's production trust implementation. Keep the approved coalesced-byte oracle exception and local-timeout/no-remote-cancellation contract visible.
4. Installed Macus bridge/gateway/package/VZ/hardware acceptance, performed later by Macus against an actual pinned gateway revision.

Real tests require a supplied approved backend, a dedicated project/resource namespace, credential references, isolated client state and an explicit mutation opt-in. There is no default real socket, automatic Incus install/init, VM boot or reuse of production data. Only expressly authorized test resources may be cleaned up; ambiguous failures preserve resources and bounded diagnostic identities for reconciliation. Absence of opt-in records an unrun gate, never a pass.

Gateway conformance never changes `priv/incus/coverage.json` or the endpoint inventory, even if every proxied native request succeeds.

### 8. Delivery in slices

Each slice is its own `feature/incus-gateway-*` branch from develop with its own draft pull request, checks and task evidence, following the client's slice practice. Later slices build on merged earlier ones; no slice claims another's tasks.

| Slice | Tasks | Delivers |
| --- | --- | --- |
| G1 Core HTTP | 1.1–1.3, 2.1, 2.2, 3.1–3.3 | Optional deps, config/host behaviour, admission, shared policy, canonical mounting, streamed HTTP relay |
| G2 Identity and revocation | 2.3, 2.4 | Discovery/identity rewrite, trust/enrollment delegation, revocation rechecks |
| G3 WebSockets | 4.1, 4.2 | Exec/console/events and operation WebSocket relay |
| G4 Raw upgrades | 5.1, 5.2 | Cowboy dispatch, takeover and SFTP/NBD duplex |
| G5 Migration | 6.1, 6.2 | Relay/pull/push negotiation and operation-secret admission |
| G6 Acceptance | 7.1–7.4 | Immutable consumer, CLI conformance, portable checks, real-Incus report |

## Risks / Trade-offs

- Raw handler bypasses Phoenix authorization -> one shared policy path and zero-backend-access denial fixtures for every protocol.
- Privileged Unix relay erases downstream caller restrictions -> enforce host authority before opening sockets; mediate gateway trust locally.
- Operation-secret admission becomes an unauthenticated side door -> admit only the single operation WebSocket route, only after an explicit host decision, with the backend still validating the secret; fixtures prove every other route stays denied.
- Convenient forwarding corrupts binary bodies or native URLs -> retain original path/query and byte streams; differential fixtures and native CLI checks.
- Address rewrite hides a guest-reachability failure -> report guest-side connection failures natively and never retry through another address.
- Full HTTP capture or slow peers exhaust memory -> bounded admission, chunks, callbacks, queues, writes and total/lifetime budgets.
- A proxy pass is mistaken for typed-client evidence -> independent reports and an unchanged coverage ledger.
- Extracted mechanics are mistaken for accepted Macus integration -> immutable consumer test now; Macus plan/source reconciliation and installed/hardware evidence later.

## Migration Plan

This is new opt-in functionality with no deployed gateway state migration. Implement and verify portable mechanics here slice by slice, publish immutable revisions and document the host mount/dispatch contract. Macus can then reconcile its own `add-elixir-server` proxy tasks to consume those mechanics while retaining local endpoint/auth/identity/trust/bridge ownership. Do not edit Macus here or remove its historical fixture evidence.

For deployment rollback, remove only the explicit gateway mount and its owned workers from the host configuration, preserving host runtime, Incus workloads, credentials and data. No release, installation or service activation occurs during this proposal.

For Git Flow delivery, implement each slice on its own feature branch from develop. Do not merge, tag or release without explicit authorization.
