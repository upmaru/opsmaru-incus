# Spec Delta

## Purpose

Provides a native Incus gateway that a host can mount in its existing server, with explicit policy, transparent bounded transports, cross-server migration at pinned Go client parity and acceptance independent of Macus installation or virtualization.

## ADDED Requirements

### Requirement: Passive host mounting

The gateway SHALL be usable inside a host-owned server without a dependency-owned endpoint, Repo or separate service. Dependency loading and gateway configuration MUST NOT create credentials/state, open listeners, contact a backend or start workloads, including with ambient PHX_SERVER/PORT values.

#### Scenario: Embedded configuration

- **WHEN** a consumer loads and configures the gateway with hostile web environment values
- **THEN** no dependency-owned listener, credentials, runtime state or backend access appears and the host retains server ownership

### Requirement: Authorization before backend access

Every relayed request and protocol upgrade SHALL use verified host authorization, readiness and an explicitly bound backend. Missing policy SHALL deny access. Request fields MUST NOT replace caller identity, backend address or credentials. Raw upgrade routing SHALL enforce the same policy as ordinary routes.

#### Scenario: Unauthorized raw upgrade

- **WHEN** a caller requests SFTP/NBD without required gateway authorization or readiness
- **THEN** the request is denied before any backend connection or bytes are sent

#### Scenario: Restricted project access

- **WHEN** a caller requests a project or operation outside its verified authority
- **THEN** the gateway denies it before backend access rather than relying on privileged Unix socket access to enforce restrictions

### Requirement: Gateway identity and trust isolation

Discovery, advertised gateway identity and certificate enrollment/trust SHALL be governed by host policy. Anonymous discovery SHALL be narrowly allowlisted, bounded and backend-free. Gateway credentials MUST NOT be forwarded as backend credentials, and guest trust MUST NOT authorize public gateway access.

#### Scenario: Native remote enrollment

- **WHEN** a standard Incus client inspects or enrolls against the gateway
- **THEN** responses identify the host-selected public gateway and its host-owned trust policy without enrolling guest trust or exposing private addresses

#### Scenario: Advertised server addresses

- **WHEN** an authorized client reads `GET /1.0` through the gateway
- **THEN** `environment.addresses` and `environment.certificate` carry only the host-approved public gateway addresses and certificate, and other environment fields stay native

### Requirement: Native HTTP relay

Authorized workload HTTP SHALL preserve canonical routes, encoded paths, query semantics, native errors/statuses, ETags and operation identities. Binary requests/responses SHALL stream with bounded memory and backpressure. Header handling SHALL preserve end-to-end semantics and reject unsafe framing. Workload payloads MUST NOT be reconstructed through a typed-method catalogue.

#### Scenario: Uncatalogued native request

- **WHEN** an authorized client uses a backend-supported method absent from the typed client inventory
- **THEN** native request/response behavior is relayed while typed-client coverage remains unchanged

#### Scenario: Large archive upload

- **WHEN** an authorized client uploads an archive within configured budgets
- **THEN** bytes are streamed without JSON parsing or whole-body capture and framing, errors and conditional headers remain native

### Requirement: Truthful gateway capabilities

Advertised capabilities SHALL reflect the verified backend, configured host policy and implemented gateway protocol support. Unsupported behavior SHALL fail explicitly. An unimplemented gateway path MUST NOT be concealed as a host/backend limitation or accepted as completed conformance evidence.

#### Scenario: Unsupported negotiation

- **WHEN** a backend or verified host policy cannot support a requested migration negotiation
- **THEN** the gateway reports the specific unsupported condition without following private addresses, while any implementation or acceptance gap remains separately visible

### Requirement: Cross-server migration parity

Instance and snapshot copy/move SHALL work through the gateway in relay, pull and push modes, with the gateway as source or target, as the pinned v7.0.1 Go client negotiates them. Endpoints derived from the gateway connection SHALL resolve only to host-approved public gateway addresses. Guest-side reachability failures SHALL be reported natively without retrying through another address.

The pinned v7.0.1 CLI's unsupported snapshot `move` SHALL preserve its native `400 Invalid instance name` failure before any migration mutation, retaining the source. These cases SHALL be recorded as native limitations separately from successful transfers and count as pinned native parity, following the explicit user decision on 2026-11-07. The gateway SHALL NOT synthesize a compensating copy or deletion.

#### Scenario: Pull copy from the gateway

- **WHEN** an authorized client copies an instance in pull mode from a gateway-fronted source to another Incus server
- **THEN** the target server connects to the gateway's public address, is admitted to that operation's WebSocket only by host policy and the copy completes without any guest address being offered

#### Scenario: Pinned CLI snapshot move limitation

- **WHEN** the unchanged pinned CLI attempts snapshot `move` in relay, pull or push mode with either gateway orientation
- **THEN** the native invalid-instance-name error is preserved before any migration POST or DELETE, and the case is reported as an upstream CLI limitation with the source retained

### Requirement: Operation-secret peer admission

An untrusted Incus server peer SHALL reach only the operation WebSocket route of the named operation, only with an operation secret and only after an explicit host admission decision. The backend SHALL still validate the secret, and diagnostics SHALL redact it.

#### Scenario: Secret outside its operation

- **WHEN** an untrusted server peer presents an operation secret on any other route or for another operation
- **THEN** the gateway denies it before backend access

### Requirement: Native WebSocket relay

Exec, console, events and migration WebSocket channels SHALL preserve applicable native control/data message semantics, close behavior and operation identity. Queue, byte and lifetime limits SHALL be explicit. Gateway disconnect MUST NOT imply backend operation cancellation.

#### Scenario: Event overflow

- **WHEN** an event stream exceeds its documented queue limit
- **THEN** it terminates visibly, releases its local resources and leaves other requests and backend reconciliation available

### Requirement: Native raw protocol upgrades

SFTP/NBD upgrades SHALL retain native HTTP negotiation followed by raw binary duplex traffic. Prefetched client/backend bytes, backpressure and supported half-close SHALL be preserved. Invalid upgrades or unsupported HTTP versions SHALL fail before takeover. Raw traffic MUST NOT use WebSocket framing.

#### Scenario: Coalesced native greeting

- **WHEN** HTTP upgrade headers and initial protocol bytes arrive in the same read
- **THEN** all initial bytes reach the correct peer exactly once and both directions remain usable after takeover

### Requirement: Bounded lifecycle and revocation

Requests and streams SHALL have bounded admission, deadlines, buffering and cleanup. Host policy SHALL define expiry/revocation checks with a documented maximum interval. Caller loss, revocation, timeout or worker failure SHALL release gateway-owned resources without affecting unrelated calls, the host runtime or Incus workloads. Diagnostics SHALL redact transport secrets and credentials.

#### Scenario: Revoked active connection

- **WHEN** a host revokes authorization during a stream
- **THEN** access terminates within the documented check bound and local resources close without replaying or canceling the backend operation

### Requirement: Truthful mutation outcome

The gateway MUST NOT automatically replay a potentially accepted mutation after disconnect, timeout, redirect or uncertain response. Known native operation identity SHALL remain available. Discovery/address and migration negotiation SHALL use host-approved public endpoints rather than automatically following guest-advertised addresses. A frontend disconnect during migration MUST NOT cancel or replay the backend migration.

#### Scenario: Lost accepted response

- **WHEN** a backend may have accepted a mutation before its response is lost
- **THEN** the gateway preserves any known native identity and reports failure/uncertainty without another mutation or a false completion claim

### Requirement: Independent acceptance evidence

Gateway fixtures, typed-client coverage, isolated real-Incus acceptance, installed host integration and Macus hardware acceptance SHALL be recorded separately with exact source/reference/tool provenance. Portable checks SHALL run in this library's repository without Macus, SQL, central authentication or production data. Real-backend mutation tests SHALL require explicit isolated opt-in.

#### Scenario: Portable real-backend acceptance

- **WHEN** an operator explicitly supplies an isolated Incus backend and permits scoped test mutations
- **THEN** the library repository can verify gateway behavior independently, without modifying Macus or claiming its installation/hardware acceptance

#### Scenario: Bounded acceptance metadata-read recovery

- **WHEN** the explicitly started acceptance host encounters only a metadata GET connection failure or a transport close before any parsed response observation
- **THEN** it may retry that read while retaining only already-verified authority within the original cache lifetime, without updating freshness/entry expiry, learning unknown operations or making an initially unready host ready; fresh admission and existing leases still enforce their documented expiry/recheck bounds
- **AND** any observed HTTP status, malformed HTTP, deadline, native/model/schema failure, cancellation, owner loss, marker change or trust revocation remains fail-closed; ownership/cancellation are checked after blocked reads before renewal, and decisive diagnostics remain visible without raw metadata or secrets
- **AND** the library never retries a mutation and preserves uncertainty when an accepted mutation loses its response

#### Scenario: Proxy passes while client coverage is missing

- **WHEN** a standard client succeeds through the gateway for a native call with no typed-client evidence
- **THEN** gateway evidence is recorded separately and the coverage ledger entry stays unchanged
