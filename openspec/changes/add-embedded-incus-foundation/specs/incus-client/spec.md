# Spec Delta

## Purpose

Provides the same canonical Incus API and streaming contracts to embedded macOS consumers and independently deployed Linux services without implementing a second workload manager.

## ADDED Requirements

### Requirement: Portable canonical client

The shared client SHALL support explicitly configured Unix and authenticated HTTPS backends on supported macOS and Linux hosts. It SHALL preserve native project/target parameters, ETags, error envelopes and operation identities. It MUST NOT depend on a Macus runtime or invoke a host VM CLI.

#### Scenario: Native Linux backend

- **WHEN** a Linux host supplies its local Incus connection
- **THEN** the shared client uses that backend without accessing Swift endpoints or creating an outer VM

#### Scenario: Macus relay backend

- **WHEN** Macus supplies its private Incus relay connection
- **THEN** the same client implementation uses the existing relay without another host-to-guest bridge

### Requirement: Traceable client coverage

The client SHALL maintain a pinned official-client method/type inventory, source notices and evidence for each implemented operation. Missing parity SHALL remain visible and prevent a complete-port claim. Raw proxy success MUST NOT substitute for typed-client evidence.

#### Scenario: Coverage review

- **WHEN** a complete-port claim is evaluated
- **THEN** every supported reference entry has corresponding implementation and verification evidence, and missing entries prevent acceptance

### Requirement: Truthful backend compatibility

Version, extension and live backend capability checks SHALL precede operations requiring those capabilities. Unsupported behavior SHALL return an explicit compatibility failure. Host limitations MUST NOT conceal missing client implementation.

#### Scenario: Missing extension

- **WHEN** the selected backend lacks the extension required by an operation
- **THEN** the client reports unsupported behavior without attempting an incompatible request

### Requirement: Native operation semantics

Accepted operations SHALL remain distinguishable from completed operations. Waiting, polling and supported cancellation SHALL retain native identity and bounded deadlines. Local timeout or disconnection MUST NOT imply remote cancellation, and potentially accepted mutations MUST NOT be replayed automatically.

#### Scenario: Lost mutation response

- **WHEN** the connection fails after a mutation might have reached Incus
- **THEN** the client reports the known operation identity or uncertain outcome without issuing the mutation again

### Requirement: Native streaming fidelity

Exec, console, events, files, images, backups and migrations SHALL preserve native streaming and control semantics, including applicable WebSocket and non-WebSocket upgrades. Binary transfers, half-close, backpressure and disconnect cleanup SHALL be bounded and independently verifiable.

#### Scenario: Native file connection

- **WHEN** a consumer opens a native file transfer connection
- **THEN** the client negotiates the required native protocol and preserves binary traffic without substituting WebSocket framing

### Requirement: Bounded event subscriptions

Subscriptions SHALL have explicit lifetime and queue bounds. Overflow SHALL fail visibly and permit reconciliation against authoritative backend state. Cancellation and completion races SHALL release resources without disrupting unrelated operations.

#### Scenario: Event overflow

- **WHEN** a subscription exceeds its documented queue limit
- **THEN** it terminates with a visible overflow error and other client requests remain available

### Requirement: Independently recorded acceptance

Differential wire fixtures, shared-library platform checks and real-backend acceptance SHALL be recorded separately. Upstream changes SHALL expose altered inventory entries and rerun affected evidence before support claims are updated.

#### Scenario: Fixture-only success

- **WHEN** differential fixtures pass without a real Linux or Macus backend
- **THEN** protocol evidence is recorded while real-backend acceptance remains incomplete

### Requirement: Host-supplied OCI conversion

OCI support SHALL use an explicitly supplied host adapter for privileged conversion, registry credential use and temporary state. Construction MUST NOT probe tools, run commands, create state or contact a registry. The client SHALL preserve pinned native alias/image semantics and unsupported-method errors, bound inspection and binary delivery, and invoke per-call idempotent cleanup on completion, failure, timeout or owner loss. Adapter calls MUST NOT be replayed automatically. Hosts SHALL verify registry identity and keep credentials and conversion resources isolated by call identity.

#### Scenario: Explicit OCI export

- **WHEN** an authorized ready host invokes OCI image conversion through its supplied adapter
- **THEN** native metadata/rootfs bytes are delivered through bounded acknowledged sinks and per-call resources are released without affecting another connection or workload

#### Scenario: Adapter timeout or host loss

- **WHEN** an adapter exceeds its deadline or its calling owner exits
- **THEN** local work terminates, per-call cleanup is invoked and no automatic conversion retry or backend cancellation occurs

#### Scenario: Fixture adapter acceptance

- **WHEN** native projection fixtures and a fake conversion adapter pass
- **THEN** the evidence records the library contract while installed adapter conversion, registry authentication and real Incus/Macus hardware acceptance remain separate unverified gates
