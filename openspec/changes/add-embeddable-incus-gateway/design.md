# Design

## Context

See [proposal.md](proposal.md). The existing foundation provides passive embedding, explicit Unix/verified HTTPS connections, bounded outgoing HTTP/transfers/WebSockets/raw channels and native models/operations. Coverage remains partial; foundation tasks 3.9 and 4.3 are open. Its published runtime `debcea5c5dd0c988191175b3aa17310e0c45b695` is a verified incremental consumer pin, not complete client acceptance.

Macus has an endpoint without a shared body parser, an empty JSON API scope and proxy/auth boundary stubs. Its test-only Cowboy handler uses `switch_protocol` and `takeover/7` to transfer socket ownership and forward both client and backend prefetched bytes. This is reusable protocol evidence, not installed gateway authentication or hardware acceptance. Macus source is not changed here.

Pinned Plug.Cowboy 2.9.0's adapter supports `:websocket` upgrades and returns `:not_supported` for other protocols. A Phoenix `forward` declaration is sufficient for request dispatch but not the entire native Incus protocol surface. The current typed `HTTP.request` facade buffers responses and parses/re-encodes native selection queries, so it cannot serve as a transparent streaming reverse proxy without separate relay mechanics.

## Goals / Non-Goals

**Goals:** one reusable native gateway with a small host mounting/policy contract; an independent fixture and isolated real-Incus acceptance path in this repository; clear evidence boundaries and preserved host/backend ownership.

**Non-Goals:** a workload manager, per-method REST facade, central endpoint/registry/MCP/OIDC/connector behavior, production trust store or issuer, background application tasks, installation, VM lifecycle, host commands, Macus source changes or automatic real-backend provisioning/activation.

## Decisions

### 1. Library component with optional server adapters

Put reusable code under `lib/opsmaru/incus/gateway/` in the `:opsmaru_incus` library, using `Opsmaru.Incus.Gateway` namespaces for configuration/host contract, relay, Plug, WebSocket and Cowboy raw protocol handling. Do not introduce another package, application callback, process or server. Declare Plug and Cowboy as `optional: true` dependencies and compile gateway modules only when they are available, so client-only consumers do not inherit a web stack; Macus and central Opsmaru already lock compatible versions. Keep transport internals isolated so adapters can evolve independently.

Macus mounts the component in its own router/endpoint and configures the companion Cowboy dispatch on the same listener. The test harness uses an explicitly started host-owned fixture endpoint. This harness is not a production application mode or service. Central Opsmaru does not mount the gateway; it is an operation gateway, not a native `/1.0` proxy.

Alternative: controllers per native Incus method couple proxy coverage to the unfinished typed-client catalogue and risk changing wire behavior. A transparent relay preserves backend extensions without relabeling typed-client coverage.

### 2. Immutable configuration and host policy

Construction accepts a fixed host-selected backend `Connection`, resource limits, an explicitly selected host adapter and opaque private configuration. Validation is passive. Host callbacks receive normalized bounded request metadata and actual peer identity from the server adapter; request body/query/headers cannot provide a verified principal or alternative remote. Configuration/Inspect/process status must redact addresses, credentials, private references and transport secrets.

Native project/member defaults and supplied query selections are evaluated against host authority without silently injecting a typed client's default selection or re-encoding the raw query. Conflicting, ambiguous or unauthorized selectors fail before backend access. Backend capability metadata is host-supplied from explicit verified inspection, bound to the selected connection and combined with the gateway's implemented protocol support; anonymous identity handling never probes a backend to build that metadata.

The host contract supplies authorization/caller binding, readiness, allowed project/member/operation authority, advertised gateway identity, narrow discovery/trust handling and an expiry/revocation decision. Missing adapter/callbacks deny before connection. The gateway enforces that contract and the configured connection binding; callbacks run under bounded budgets and cannot authorize work after their deadline. All HTTP, WebSocket and raw-upgrade paths share this policy code, including paths dispatched before Phoenix pipelines.

This change does not implement a production credential registry or issuer. The independent host fixture supplies test certificate enrollment and trust in isolated ephemeral state. Production Macus policy, certificate/bearer storage and administration remain Macus-owned. User/gateway credentials are stripped before backend relay; explicitly configured backend HTTPS credentials remain distinct. An optional verified gateway/backend restriction cannot be advertised unless it is enforced before privileged Unix access; initial fixture enrollment uses explicit owner-admin authority and rejected restricted-certificate cases.

Default revocation/expiry rechecks for active channels are bounded to at most five seconds; hosts may tighten the interval. Backend/worker cleanup never requires a new authorization grant. A bounded admission supervisor is explicitly host-started when mounting, rather than automatically created on dependency load. Rejected admission opens no backend and queues no unbounded work.

### 3. Canonical routing and narrow identity mediation

Expose native `/`, `/1.0` and `/1.0/*`; keep host `/runtime` and `/mcp` routes outside this component. The HTTP Plug can be forwarded at `/1.0` with a separate root discovery mount. Preserve the original encoded request path and raw query despite `forward` modifying `path_info`; do not reconstruct resource paths from decoded Phoenix params. No `/incus` prefix aliases are promised. Native routes bypass blanket JSON body parsing and JSON-only content negotiation.

Explicit allowlisted discovery, `/1.0` identity and `/1.0/certificates` enrollment/trust actions delegate to host policy rather than blindly forwarding privileged guest trust. Anonymous discovery is synthetic, bounded and backend-free. Host-supplied identities must advertise a verified public origin and omit private socket/guest-NAT addresses. Workload payloads otherwise pass unchanged. Unknown native routes do not bypass authorization; authenticated backend-native failures stay native.

Migration/remote-copy negotiation is not silently fixed by a generic JSON rewrite. The host must explicitly authorize the public addresses and operation endpoints used in negotiation. Where guest responses cannot safely represent a reachable authorized endpoint without a separately verified mediation path, fail visibly and retain native identities. Acceptance includes that supported negotiation path and explicit unsupported cases, not an automatic fallback to guest addresses.

Unsupported cases must identify an actual backend or verified host-policy limitation. An unimplemented relay/negotiation path is recorded as missing gateway implementation and cannot count as a passed acceptance case or be hidden by capability filtering. Operation-scoped secret and remote-peer authorization during migration must pass the same explicit host policy boundary, not authorize arbitrary addresses or bypass it with request-supplied identity.

### 4. Three protocol paths on one listener

| Protocol | Server integration | Backend handling |
| --- | --- | --- |
| Native HTTP and archives/files | Mountable Plug | Passive streamed Unix/HTTPS relay with acknowledged bounded chunks |
| Exec/console/events/migration WebSockets | Plug plus native WebSocket handler | Bounded bidirectional control/data relay preserving message semantics |
| SFTP/NBD raw upgrades | Cowboy handler/protocol switch | Native HTTP 101 validation, socket takeover and raw duplex traffic |

The host configures Cowboy dispatch for raw upgrades, with ordinary traffic reaching the Phoenix router. Matching is limited to known native upgrade routes/protocols/methods; HTTP/1.1 is required for the raw takeover path. Reject unsupported versions, bodies, malformed connection/upgrade tokens and unsafe response headers before takeover. Document host listener/ALPN requirements without modifying global host settings or opening another listener.

Transferred Macus fixtures require recorded source/transferred hashes and existing Incus notices; do not copy Macus policy, Swift code or active implementation. Socket ownership moves to the takeover process, which forwards both prefetched buffers exactly once and never re-enters Cowboy's HTTP state machine after termination. Preserve supported half-close with finite drain deadlines and bounded writes. WebSocket relay preserves message/control semantics without claiming identical masked wire bytes between independently negotiated connections.

### 5. Transparent HTTP and truthful failure

Reuse suitable foundation framing, TLS trust and lifecycle primitives, adding an incoming streamed relay instead of routing every request through `Incus.call` or the buffered HTTP facade. Preserve end-to-end statuses, errors, ETags, duplicate headers where applicable, query ordering/encoding, native operation URLs, binary data and trailers. Remove hop-by-hop headers according to connection tokens; validate framing and header budgets to prevent ambiguity/injection. Apply byte/deadline/queue/admission limits through both directions and every callback.

Record the transition where request bytes may have reached the backend. Do not retry mutations on timeout, disconnect, redirects or malformed responses; do not auto-follow another origin. Before a response is committed, emit a bounded truthful native-shaped gateway failure including a known operation identity when available; after HTTP upgrade or committed output, close the stream and require reconciliation rather than emitting another HTTP response. Do not claim backend cancellation or delete remote operations because the frontend closed. Cleanup stops only gateway-owned sockets/workers; caller-owned destination files and backend resources remain intact.

### 6. Acceptance without Macus or central services

Maintain four distinct evidence layers:

1. Database-free fake Unix/HTTPS gateway protocol fixtures on macOS/Linux, including TLS peer policy, wrong credentials, denial counters, framing, transfers, upgrades, bounds, redaction, revocation and uncertain mutations.
2. An independent immutable Git consumer with its own endpoint/policy mounting the gateway and the library remaining passive under hostile PHX_SERVER/PORT. Run the unmodified official client/CLI at the existing v7.0.1 reference pin; any built CLI is verifier-only, with exact hashes and isolated INCUS_CONF.
3. Explicit isolated real-Incus tests in this repository: native CLI/client interactions through the mounted gateway, recorded separately from the foundation's existing direct typed-client evidence. No Macus build or runtime is needed. A fixture host demonstrates portable policy mechanics, not Macus's production trust implementation. Keep the approved coalesced-byte oracle exception and local-timeout/no-remote-cancellation contract visible.
4. Installed Macus bridge/gateway/package/VZ/hardware acceptance, performed later by Macus against an actual pinned gateway revision.

Real tests require a supplied approved backend, a dedicated project/resource namespace, credential references, isolated client state and an explicit mutation opt-in. There is no default real socket, automatic Incus install/init, VM boot or reuse of production data. Only expressly authorized test resources may be cleaned up; ambiguous failures preserve resources and bounded diagnostic identities for reconciliation. Absence of opt-in records an unrun gate, never a pass.

Foundation task 4.3 does not depend on this gateway: direct real-Incus evidence may satisfy it earlier, with exact shared-run references if the gateway harness is also used. Foundation task 3.9 still needs all supported remaining client behavior and meaningful per-entry evidence. Gateway conformance cannot substitute for it, even if all proxied native requests succeed.

## Risks / Trade-offs

- Raw handler bypasses Phoenix authorization -> one shared policy path and zero-backend-access denial fixtures for every protocol.
- Privileged Unix relay erases downstream caller restrictions -> enforce host authority before opening sockets; mediate gateway trust locally.
- Convenient forwarding corrupts binary bodies or native URLs -> retain original path/query and byte streams; differential fixtures and native CLI checks.
- Full HTTP capture or slow peers exhaust memory -> bounded admission, chunks, callbacks, queues, writes and total/lifetime budgets.
- A proxy pass is mistaken for a complete library -> independent manifests/reports and unchanged open client gates.
- Extracted mechanics are mistaken for accepted Macus integration -> immutable consumer test now; Macus plan/source reconciliation and installed/hardware evidence later.

## Migration Plan

This is new opt-in functionality with no deployed gateway state migration. Implement and verify portable mechanics here, publish an immutable revision and document the host mount/dispatch contract. Macus can then reconcile its own `add-elixir-server` proxy tasks to consume those mechanics while retaining local endpoint/auth/identity/trust/bridge ownership. Do not edit Macus here or remove its historical fixture evidence.

For deployment rollback, remove only the explicit gateway mount and its owned workers from the host configuration, preserving host runtime, Incus workloads, credentials and data. No release, installation or service activation occurs during this proposal.

For Git Flow delivery, implement on its own feature branch, separate from task 3.9 client work, and keep its task/evidence boundary distinct from the foundation's completion definition. Do not merge, tag or release without explicit authorization.
