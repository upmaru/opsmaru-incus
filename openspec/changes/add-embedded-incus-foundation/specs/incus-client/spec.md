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

#### Scenario: Bounded inspection contracts

- **WHEN** the ten initial-tool list/get methods have typed Unix and mutual-HTTPS comparisons plus independent bound/lifetime evidence
- **THEN** the manifest may record their explicit fixture-verified scope and required cases while whole endpoint and declaration statuses remain partial, unsupported variants and backend acceptance remain visible, and removed methods/cases/evidence fail validation

#### Scenario: Bounded YAML atom-safety evidence

- **WHEN** the atom-safety fixture parses all 200 distinct keys in bounded ten-key documents
- **THEN** every document must decode to its complete expected string map and no probe key may become an atom
- **AND** the resource-sensitive YAML module runs serially with all large-document success, elapsed, oracle and worker/message cleanup checks retained
- **AND** parser code, native oracle, accepted subset, production limits and test timeouts remain unchanged; retries and accepted rejections cannot establish this evidence

#### Scenario: Socket receive timeout wins the deadline race

- **WHEN** a passive HTTP socket receive exhausts its absolute remaining deadline before the outer guard result is observed
- **THEN** GET/HEAD report the local deadline, POST retains uncertain mutation semantics, peers close and no request is replayed
- **AND** premature EOF remains a response failure, with deterministic Unix/mutual-HTTPS regression evidence that does not relax deadlines or accepted error kinds
- **AND** evidence validation parses each referenced source once per invocation while retaining row-specific anchors, fresh source reads across invocations and the full negative-case matrix

#### Scenario: Completed inspection contracts

- **WHEN** any names, list, full, filtered, all-projects or single-object inspection method of a B02 row, or connect/2 discovery, is called over Unix or mutual HTTPS
- **THEN** request and populated/empty results agree with the pinned client, corrupt results and native 403/404 are rejected faithfully, declared extensions are required before dispatch, and response bounds, readiness, deadline and cancellation clean up the peer
- **AND** each completed row has a reviewed completion record, while names-only filter/all-projects selectors, public views and cluster forwarding are recorded approved exclusions

#### Scenario: Completed network contracts

- **WHEN** any B09 network, ACL, address set, allocation, integration, zone, zone record, forward, lease, load balancer or peer method is called over Unix or mutual HTTPS
- **THEN** reads agree with the pinned client for populated/empty/corrupt results, native 403/404, routing, extensions and lifetime cleanup, and synchronous writes agree for request bodies, ETags and native rejection while lost or malformed replies are uncertain and never replayed
- **AND** reviewed records list each completed row, selectors the pinned client does not send and cluster forwarding are approved exclusions, and the metrics and ACL log rows stay partial while S07 is open

#### Scenario: Completed stream-free instance and image contracts

- **WHEN** any stream-free B11 image alias, image, instance access, log, metadata, console log, bitmap, rebuild, snapshot or project-wide instance state method is called over Unix or mutual HTTPS
- **THEN** reads agree with the pinned client for populated/empty/corrupt results, native 403/404, routing and extensions. Synchronous and asynchronous writes agree for request bodies, ETags, accepted operations and native rejection. Lost or malformed write replies are uncertain and never replayed. A returned image secret is never shown by `Inspect`
- **AND** the public alias view and cluster forwarding are recorded approved exclusions

#### Scenario: Completed stream-free storage contracts

- **WHEN** any stream-free B08 storage pool, bucket, bucket key, resource, volume state, snapshot, bitmap or rebuild method is called over Unix or mutual HTTPS, for any daemon volume type
- **THEN** reads agree with the pinned client (or, for list-by-type and the single bitmap read, with unchanged RawQuery transport) for populated/empty/corrupt results, native 403/404, routing and extensions. Synchronous, model-returning and asynchronous writes agree for request bodies, ETags, results, accepted operations and native rejection. Lost or malformed write replies are uncertain and never replayed
- **AND** the collection volume POST stays partial until it is reconciled with volume create, and names-only bucket selectors and cluster forwarding are recorded approved exclusions

#### Scenario: Completed PATCH contracts

- **WHEN** any B05 PATCH method is called over Unix or mutual HTTPS with a nonempty caller ETag
- **THEN** the request (path, routing, If-Match and body field presence, including null, false, empty and unknown fields) agrees with unchanged pinned Go RawQuery transport, native empty synchronous success, accepted snapshot operations and native 400/403/404/412 are preserved, and lost or malformed replies are uncertain after one PATCH and never replayed
- **AND** PATCH without an ETag, invalid bodies, empty path arguments, unready hosts, missing extensions and guarded fields reject before I/O, network peer PATCH is documented as the daemon's full replace, and unconditional PATCH, non-custom volume snapshot types and cluster forwarding are recorded approved exclusions

#### Scenario: Completed administrative contracts

- **WHEN** any B10 server, root discovery, certificate, cluster, project, profile, resource, metadata or warning method is called over Unix or mutual HTTPS
- **THEN** reads, synchronous writes and asynchronous writes agree with the pinned client (or, for root discovery, with unchanged RawQuery transport) for results, request bodies, ETags, native rejection and accepted operations, guarded fields require their extensions before dispatch, and lost or malformed write replies are uncertain and never replayed
- **AND** the trust-token certificate bootstrap is a certified supported view, while names-only filter selectors and cluster forwarding are recorded approved exclusions

#### Scenario: Remaining initial inspection contracts

- **WHEN** the nine B02 typed reads and explicit server discovery have scoped Unix/mutual-HTTPS fixture evidence
- **THEN** populated/empty/grouped results use fixed fixture expectations, native errors/routing/binding and applicable ETags remain faithful, and byte/readiness/lifetime bounds have independent cleanup evidence
- **AND** discovery RawQuery transport evidence remains distinct from connect/2 compatibility guards and named Go DTO parity, while broader variants, whole endpoints and declarations stay partial

#### Scenario: Full endpoint inventory classification

- **WHEN** the full classification audit is validated
- **THEN** every pinned documented verb/path, query/access view and declared query parameter is represented, public server registration differences and helper/subtype mappings remain explicit, and every unresolved contract has a named finite backlog assignment; classification completeness does not certify behavior, approve exclusions, change tool exports or complete task 3.9

#### Scenario: Classification cannot borrow evidence from another scope

- **WHEN** query parameters and copied fixture-verification scopes are checked
- **THEN** parameter support comes only from methods matching that documented view and each copied verified_scope equals its selected evidence entry, so unrelated recursion views or endpoint rows cannot conceal gaps or claim verification

#### Scenario: Reviewed endpoint completion record

- **WHEN** an endpoint row or stream contract is marked complete or certified
- **THEN** a completion record lists it with its methods/helpers, supported and approved-excluded views, selector treatment, bodies/modes, result fields, locally rejected variants, approved differences, required cases and evidence kinds on Unix and mutual HTTPS, and every stream contract linked to the row is certified
- **AND** validation rejects removed cases, transports or evidence, unlisted views, unapproved exclusions, completion claimed for an unrelated, missing-typed or open-stream row, and any change to global completion, complete_port or Go declaration statuses

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

#### Scenario: Initial mutation lifecycle contracts

- **WHEN** the eight B01 mutation pairs are exercised through bounded Unix and mutual-HTTPS fixtures
- **THEN** seven asynchronous pairs preserve native acceptance and identity through direct finite `/wait` running/completed/failed snapshots, update/restore bodies and applicable preconditions remain faithful, native rejection and response-loss uncertainty never replay mutations, and synchronous operation cancellation retains authoritative permission/race semantics without claiming completion
- **AND** a checked fixture scope records exactly the evidenced methods/cases while whole endpoints, declaration parity, broader variants and real-backend acceptance remain separate

#### Scenario: Completed single-method mutation contracts

- **WHEN** instance update/restore, state change, deletion, snapshot creation/deletion, image deletion or operation cancellation is submitted with any supported body field or action over Unix or mutual HTTPS
- **THEN** the request and accepted identity agree with the pinned client, guarded fields require their extensions before dispatch, and native running/completed/failed/cancelled snapshots, ETag preconditions and native rejection hold without replay on lost or malformed replies
- **AND** a reviewed completion record lists each completed row with its cases and evidence kinds, while cluster forwarding stays an approved exclusion and instance creation stays partial while its archive and migration contracts are open

#### Scenario: Direct native operation wait evidence

- **WHEN** either typed native wait method receives a gated response body after flushed headers over Unix or verified HTTPS
- **THEN** fixture evidence compares finite wait queries, operation snapshots, ETags and native errors with the unchanged pinned client, while independent deadline/cancellation/caller-loss checks prove local socket cleanup without replay or remote cancellation; polling behavior and partial declaration status remain unchanged

#### Scenario: Completed native wait contract

- **WHEN** a native wait has an empty or non-hexadecimal secret, or a timeout outside 0..3600
- **THEN** it is rejected before I/O, rather than being sent as a different request
- **AND** supported waits keep pinned-client agreement for running, completed, failed and cancelled snapshots and for native 403/404 errors, and connection loss before headers leaves one request with no replay
- **AND** the public view, arbitrary/empty secrets and cluster forwarding remain recorded approved exclusions

### Requirement: Bounded conditional instance partial updates

PatchInstance SHALL send the native instance PATCH with a validated InstancePut
map and an explicit nonempty caller ETag. It SHALL preserve omitted, null, false
and empty field values without local read/merge/default materialization, retain
host routing and response binding, and require empty synchronous success. Native
rejections SHALL retain HTTP/native errors; dispatched failures SHALL remain
uncertain without replay or manufacturing an operation identity.

#### Scenario: Conditional partial update

- **WHEN** a ready authorized host supplies bounded partial configuration and If-Match
- **THEN** one PATCH preserves field presence and native synchronous result, while unchanged RawQuery transport comparison and independent endpoint fixtures are recorded separately from real-daemon merge acceptance

#### Scenario: Completed conditional instance PATCH

- **WHEN** a host submits instance PATCH without a nonempty ETag
- **THEN** it is rejected before I/O, as unconditional PATCH is an approved exclusion
- **AND** the conditional contract's field presence, empty synchronous success, native and restore-mode rejection, uncertainty without replay and lifetime cleanup are recorded under a reviewed completion record

### Requirement: Bounded conditional resource partial updates

PatchProject, PatchProfile, PatchImage and PatchInstanceSnapshot SHALL use their
native PATCH routes and existing Put models with an explicit bounded caller ETag.
They SHALL preserve model-valid field presence without local GET/merge/defaults,
retain host routing, native errors and identity, reject invalid preflight input
without I/O and never replay possibly accepted mutations. The first three SHALL
require HTTP 200 empty synchronous success. Snapshot PATCH SHALL require HTTP 202
asynchronous acceptance and return the actual operation, distinct from completion.

#### Scenario: Conditional resource update evidence

- **WHEN** a ready host submits one of the four conditional partial updates
- **THEN** Unix and mutual-HTTPS fixtures preserve exact body, If-Match, routing, native result and rejection; unchanged RawQuery comparison remains transport evidence, while supported scope, response-loss uncertainty and local cleanup have independent evidence and daemon merge acceptance remains separate

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

#### Scenario: Completed exec submission contract

- **WHEN** exec is submitted in collected noninteractive, non-waiting, interactive PTY or record-output mode, with or without user/group/cwd and terminal size
- **THEN** the request and accepted handle agree with the pinned client over Unix and mutual HTTPS, recording and user/group/cwd fields require their extensions before dispatch, and interactive resize/signal control frames match native messages within their bounds
- **AND** native rejection, channel upgrade targets and failures, redaction, and the existing failure and cleanup outcomes hold on both transports, while recorded-output retrieval and the shared operation WebSocket row remain open

### Requirement: Bounded event subscriptions

Subscriptions SHALL have explicit lifetime and queue bounds. Overflow SHALL fail visibly and permit reconciliation against authoritative backend state. Cancellation and completion races SHALL release resources without disrupting unrelated operations.

#### Scenario: Event overflow

- **WHEN** a subscription exceeds its documented queue limit
- **THEN** it terminates with a visible overflow error and other client requests remain available

#### Scenario: Completed event subscription contract

- **WHEN** a host subscribes with type lists, all-projects or connection project/member routing over Unix or mutual HTTPS
- **THEN** upgrade targets match the pinned client, with all-projects suppressing project; unknown types receive native 400, absent projects 404 and permission failures 403; and Event fields and inbound byte bounds hold
- **AND** handlers, capacity, callback failure, owner/caller loss, EOF, malformed events, overflow, deadline and cancellation end with actual peer closure where the client ends the stream, and a context-ended listener reports that context's cancellation or deadline, without callback ordering claims or cluster forwarding

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
