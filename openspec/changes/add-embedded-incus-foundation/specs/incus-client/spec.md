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

The client SHALL maintain a pinned official-client method/type inventory, source notices and evidence for each implemented operation. Missing parity SHALL remain visible and prevent a complete-port claim. Task 3.9 completion SHALL instead require a verified Incus REST endpoint/method inventory, native streaming/upgrade contracts and public client behavior required by `add-incus-operations`, with explicit supported scope and approved differences. Go declaration parity MUST NOT be inferred from that completion. Raw proxy or tool success MUST NOT substitute for typed-client evidence.

#### Scenario: Coverage review

- **WHEN** a complete-port claim is evaluated
- **THEN** every supported reference entry has corresponding implementation and verification evidence, and missing entries prevent a complete-port claim independently of task 3.9 completion

#### Scenario: Task 3.9 completion

- **WHEN** task 3.9 is evaluated for completion
- **THEN** the verified endpoint/method, streaming/upgrade and consumer-required behavior inventory has implementation and evidence while the separate Go declaration ledger retains partial/missing entries and approved differences

#### Scenario: Selected endpoint evidence inventory

- **WHEN** the initial 21 priority endpoint/method pairs are checked
- **THEN** each pair has unchanged pinned REST provenance and explicit supported scope, client/evidence links and gaps; native endpoint wait and polling wait evidence remain distinct with scoped gated-body/lifetime evidence and remaining secret/cluster/backend gaps visible, and selected coverage cannot imply complete REST or declaration parity

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

#### Scenario: Direct native operation wait evidence

- **WHEN** either typed native wait method receives a gated response body after flushed headers over Unix or verified HTTPS
- **THEN** fixture evidence compares finite wait queries, operation snapshots, ETags and native errors with the unchanged pinned client, while independent deadline/cancellation/caller-loss checks prove local socket cleanup without replay or remote cancellation; polling behavior and partial declaration status remain unchanged

### Requirement: Native streaming fidelity

Exec, console, events, files, images, backups and migrations SHALL preserve native streaming and control semantics, including applicable WebSocket and non-WebSocket upgrades. Binary transfers, half-close, backpressure and disconnect cleanup SHALL be bounded and independently verifiable.

#### Scenario: Native file connection

- **WHEN** a consumer opens a native file transfer connection
- **THEN** the client negotiates the required native protocol and preserves binary traffic without substituting WebSocket framing

#### Scenario: Bounded noninteractive exec collection

- **WHEN** a creator collects live noninteractive exec stdout/stderr through explicit acknowledged sinks
- **THEN** both channels are pulled under aggregate byte and absolute deadline limits, native stdin/output barriers are respected, final results retain the authoritative operation and exit status, and failures close local channels without backend cancellation or replay

#### Scenario: Bounded full-duplex noninteractive exec

- **WHEN** a host submits live noninteractive exec with bounded binary stdin and acknowledged output sinks
- **THEN** input and both outputs progress concurrently under one lifetime starting before submission, invalid mode/options or excess input reject before POST, and final results require acknowledged input closure, both output endings and authoritative native completion

#### Scenario: Exec lifetime ends after acceptance

- **WHEN** deadline, host cancellation or owner loss interrupts negotiation, input or output after exec acceptance
- **THEN** local work and channels terminate, known operation identity and binding remain available for reconciliation, unknown acceptance is reported as uncertain, and the client neither cancels nor replays the native operation

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

#### Scenario: Cleanup observation is delayed

- **WHEN** test or fixture scheduling delays observation after local resource cleanup
- **THEN** bounded process/socket observations and independent shared-budget checks preserve cleanup evidence without treating observer latency as native cleanup duration or changing library budgets

#### Scenario: WebSocket write lifetime observed late

- **WHEN** observer scheduling delays an already terminated Unix/TLS WebSocket write-lifetime fixture
- **THEN** bounded normal termination and direct clock/socket-option traces verify the actual remaining write deadline and timeout-close behavior without changing library budgets or asserting observer elapsed performance

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

### Requirement: Explicit verified SimpleStreams downloads

SimpleStreams support SHALL use an explicitly supplied verified HTTPS connection and host context, preserve pinned native index/image/alias semantics and validate binary checksums with bounded metadata, deadlines and acknowledged sinks. Construction MUST NOT contact a backend or create state. The library MUST NOT discover `/dev/incus/sock`, downgrade to HTTP, discover tools or create conversion files. These approved differences SHALL be documented against the unchanged pinned reference.

#### Scenario: Verified full image download

- **WHEN** an authorized ready host selects a SimpleStreams image using its explicit HTTPS origin
- **THEN** the client preserves native image identity and delivers bounded checksum-verified metadata/rootfs bytes without local backend discovery or an HTTP fallback

### Requirement: Host-supplied SimpleStreams delta conversion

Optional delta conversion SHALL require an explicit host adapter and base source. Each call SHALL have a unique identity, absolute deadline, bounded binary delivery and idempotent bounded cleanup on success, failure, timeout or owner loss. Hosts SHALL own conversion tools, credentials and temporary state. The library MUST NOT automatically retry conversion or replay partially delivered bytes. Without an optional adapter/base it SHALL use the verified full-file path. Adapter failures SHALL remain visible with image identity preserved.

#### Scenario: Delta conversion owner loss

- **WHEN** the calling owner exits during an explicit delta conversion
- **THEN** local adapter work terminates and per-call cleanup runs without retrying conversion or affecting another connection

#### Scenario: Fixture delta acceptance

- **WHEN** pinned SimpleStreams fixtures and a fake delta adapter pass
- **THEN** the library contract evidence is recorded separately from actual installed conversion, real-backend and Macus hardware acceptance
