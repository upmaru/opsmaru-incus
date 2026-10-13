# Spec Delta

## Purpose

Provides a native Incus gateway that a host can mount in its existing server, with explicit policy, transparent bounded transports and acceptance independent of Macus installation or virtualization.

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

The gateway MUST NOT automatically replay a potentially accepted mutation after disconnect, timeout, redirect or uncertain response. Known native operation identity SHALL remain available. Discovery/address and migration negotiation SHALL use host-approved public endpoints rather than automatically following guest-advertised addresses.

#### Scenario: Lost accepted response

- **WHEN** a backend may have accepted a mutation before its response is lost
- **THEN** the gateway preserves any known native identity and reports failure/uncertainty without another mutation or a false completion claim

### Requirement: Independent acceptance evidence

Gateway fixtures, typed-client coverage, isolated real-Incus acceptance, installed host integration and Macus hardware acceptance SHALL be recorded separately with exact source/reference/tool provenance. Portable checks SHALL run in this library's repository without Macus, SQL, central authentication or production data. Real-backend mutation tests SHALL require explicit isolated opt-in.

#### Scenario: Portable real-backend acceptance

- **WHEN** an operator explicitly supplies an isolated Incus backend and permits scoped test mutations
- **THEN** the library repository can verify gateway behavior independently, without modifying Macus or claiming its installation/hardware acceptance

#### Scenario: Proxy passes while client coverage is missing

- **WHEN** a standard client succeeds through the gateway for an unimplemented typed-client entry
- **THEN** gateway evidence is recorded and the foundation task 3.9 gap remains open
