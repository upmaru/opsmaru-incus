# Design

## Context

See [proposal.md](proposal.md). At the original planning baseline, the root Phoenix 1.8/Cowboy application had embedded telemetry only, without Endpoint/Repo/PubSub or an Incus client; generated tests expected Ecto/standalone setup. Implementation now supplies safe embedding, a database-free profile and verified partial client slices. The existing `scripts/check-embedded.exs`, method/type manifest and tasks.md distinguish implemented evidence from remaining tasks 3.9 and 4.3.

Macus has an in-progress headless Phoenix/Cowboy server, private Swift runtime.sock and Incus incus.sock relay, reference method/type inventory and fixture-only native protocol trial. Incus v7.0.1 at `13f3992766142d5087fff2e362cd2e1a75294fe8` is the existing reference baseline; transfer reusable inputs/notices and retain consumer-specific bridge evidence. The inspected dependency baseline is Elixir 1.19.5/OTP 27, Phoenix 1.8.15 and the Cowboy adapter recorded in the current locks; verify actual locked compatibility during implementation rather than inventing a release.

This is the first delivery milestone. `add-compute-substrate` consumes its library/client and later adds tools, task adapters, central targets and connectors. `add-remote-api-and-oauth` supplies later central identity/REST/browser adapters. Neither later change is a prerequisite here.

The separately proposed [add-embeddable-incus-gateway](../add-embeddable-incus-gateway/design.md) adds optional reusable native HTTP/upgrade relay mechanics under Opsmaru.Incus.Gateway. OpsmaruWeb or MacusWeb supplies the explicitly selected endpoint/router and host policy. It is not a prerequisite for direct real-Incus client acceptance or a replacement for outstanding typed-client behavior.

## Goals / Non-Goals

**Goals:**

- A safely importable `:opsmaru` dependency with a documented public client and host-supplied configuration.
- Native Unix/HTTPS Incus behavior, transparent provenance and complete planned method/type coverage.
- Database-free fixture checks and a Macus-compatible external consumer that can pin an implemented revision.

**Non-Goals:**

- Central registry/SQL/OIDC/browser auth, MCP tools, durable application tasks, connector protocol or macus connect.
- Shipping central/connector Linux installers, changing Macus application source, publishing a package release or performing hardware acceptance during planning.
- VZ ownership, host VM CLIs, a workload manager, automatic backend discovery, host commands or workspace/skill provisioning.

## Decisions

### 1. Extend the existing single app as a library first

Keep `:opsmaru` and Opsmaru/OpsmaruWeb namespaces; no new Mix app/repository is needed. Embedded mode is the default and contains only safe explicitly configured library workers. Starting the dependency must not create private runtime state, generate credentials, contact a backend or start Endpoint/Repo/standalone PubSub because ambient PHX_SERVER/PORT exist. Do not evaluate a dependency's release runtime.exs as host configuration. Macus configures the library before startup and retains its own endpoint/job tree.

Preserve the existing optional standalone scaffold without turning it into an authenticated central service in this change. Central and connector role activation will be specified/implemented later. No central role is required to exercise the client. Client supervision/cleanup is bounded and cannot stop Swift/Incus when the library restarts.

Alternative: a separate client-only package adds a second versioned product before implementation; retain an internal client boundary that can be extracted later without forcing extra packaging now.

### 2. Explicit connection and caller contracts

Expose `Opsmaru.Incus` and a documented connection value/adapter for absolute Unix socket or approved HTTPS backend, TLS CA/fingerprint verification, client certificate/private-key reference, default project, optional native cluster member and bounded request/stream budgets. Multiple explicitly created connection values can coexist without a mutable global current remote. No target registry or device enrollment is needed.

Macus passes its owner-private incus.sock relay; Linux fixtures and later consumers pass a native Unix or HTTPS connection. Connection values are trusted host configuration, not agent-supplied URLs. Keep secret references/private key loading out of normal inspect/error/log output. Client modules do not import Macus/Swift or require Phoenix routes, MCP authorization, SQL or an Opsmaru server process. The host authorizes operations before calling a privileged client; this library is not an OIDC/resource-server policy engine.

A minimal supplied host/caller binding permits readiness and backend isolation without provisioning a provider registry. Delayed host startup cannot dispatch configured library workers before trusted readiness. A request receives its connection/context explicitly and cannot substitute another owner, URL or credential. Full MCP/task context and central delegation remain later contracts.

### 3. Native client slices and acceptance

Maintain an upstream method/type manifest with immutable source notices and evidence per implemented entry. Port discovery/raw requests/codecs/extensions first, then native projects/profiles/access; instances/state/snapshots; images/transfers; networks/clusters; storage; file/backup/native SFTP/NBD; operation polling/events; exec/console; and migration/copy plus remaining reference entries. Preserve ETags/query parameters, native error envelopes, optional/null models and unsupported-extension failures.

Use a suitable maintained HTTP/TLS/WebSocket/raw-upgrade transport compatible with current locks and verify it against the upstream fixtures before adoption; adapter names do not establish stream support. Direct HTTPS validates native server identity and client key possession, with no disabled verification or OAuth requirement. Authenticate using host-selected credentials; never generate trust or install Incus during ordinary client construction.

Preserve native acceptance versus completion, operation handles, bounded wait and supported cancellation. Disconnection/deadline cannot prove backend cancellation. Possible native mutation acceptance with no known operation ID returns uncertainty and cannot trigger automatic replay. This stage exposes native operation identities and stream handles, not durable MCP/application tasks.

Bound event queues, subscriptions, captured results and connection workers. Native exec/console/control and file/image/backup channels preserve applicable binary framing, protocol upgrades, backpressure, half-close and disconnect cleanup. Test native streams independently; Macus raw proxy fixtures are consumer evidence, not a complete typed-client port. No upstream client patch or host workload translation is introduced.

### 4. Library-only and consumer checks

Add an explicit library/core test command/profile that bypasses the generated Ecto test alias and standalone test supervision. It must compile/run meaningful tests with no PostgreSQL, DATABASE_URL, OIDC keys, listener or real Incus. Keep the web test profile for the existing scaffold separately; do not silently pretend full web checks run without their database.

Use fake Unix/HTTPS backends, a pinned official-client differential oracle and deterministic failure/stream fixtures. Run actual dependency startup with hostile web environment values and inspect processes/listeners/state/backend counters. An external Mix consumer fixture uses the Macus-compatible dependency set, hosts its own endpoint/runtime stubs and imports the implemented library without loading a second endpoint/Repo or requiring an absolute sibling source path. Its task is to prove library/client integration, not shared MCP/runner behavior.

Record exactly which method/type entries have implementation/differential evidence. Partial pins may support deliberate Macus development slices, but the change's full-client completion requires every supported entry; no partial implementation is relabeled full parity. Linux real-Incus and Macus consumer bridge/hardware acceptance are separate explicit isolated opt-in gates. No provider, central database or connector setup is part of those foundation checks.

Run task 4.3's direct Unix/verified HTTPS acceptance in Opsmaru against an explicitly supplied isolated real backend, independently of Macus installation or the optional gateway. If gateway acceptance tooling supplies the same environment, reference its exact direct-client results separately from proxy/CLI results. Proxy pass-through cannot close task 3.9, including requests whose typed methods remain missing. Macus installed bridge/VZ/hardware acceptance remains consumer-owned and cannot block an otherwise verified portable foundation.

### 4a. Explicit host-owned OCI conversion adapter

OCI remains in scope. The pinned OCI implementation delegates inspection to skopeo and exports through root-only unpacking, tar processes and temporary directories. Opsmaru does not copy those host commands into shared code. Construction accepts an explicit host adapter module and opaque host-owned configuration alongside a verified connection/context; it performs no I/O. The adapter supplies bounded skopeo-compatible inspection JSON and converted metadata/rootfs bytes. Opsmaru preserves native alias normalization, layer-derived fingerprint, architecture names, image models and native unsupported-method errors. Inspection results are connection-local immutable cache values; there is no global registry or automatic discovery.

Each explicit adapter invocation receives a unique call identity and absolute monotonic deadline. The adapter must enforce verified registry identity, isolate credentials, authorize external work and associate all subprocesses/files with that call identity. It must provide idempotent bounded cleanup for completion, failure, deadline and owner loss, without affecting other calls or workloads. Shared code bounds callbacks and sinks, acknowledges binary chunks synchronously, rejects oversized/invalid results and never retries a failed adapter call. Adapter diagnostics are redacted; structured native failures remain available to the caller. No bundled skopeo runner, root escalation, trust generation, temporary state directory or Macus implementation is added here.

Acceptance has distinct layers: unchanged pinned-client fixtures verify native alias/image/unsupported semantics; independent fake adapters verify budgets, readiness, ownership, byte fidelity and cleanup. A fixture adapter proves the contract only. An installed host adapter must separately prove registry TLS, credential isolation, actual conversion contents and process/file cleanup on its supported platform. That installed-adapter gate and real Incus/Macus hardware gates stay explicit and cannot be inferred from fake adapter success. SimpleStreams remains a separate in-scope protocol.

### 4b. Explicit HTTPS SimpleStreams and host-owned delta conversion

SimpleStreams remains in task 3.9. The host supplies a verified HTTPS connection and context explicitly. Construction performs no I/O or local backend discovery. Preserve pinned index/product/image/alias projections, architecture selection, image file names/sizes/fingerprints, full-file checksum validation and supported method errors. Index, metadata and binary responses have explicit size and deadline limits; bytes reach acknowledged bounded sinks. Credentials remain connection-local and redacted. Downloads do not create files or run commands in shared code.

The unchanged Incus v7.0.1 reference probes `/dev/incus/sock`, tries an HTTP URL before HTTPS, and optionally discovers/runs xdelta3 using temporary files. Approved differences are explicit: Opsmaru never probes that socket, never downgrades HTTPS or follows an unverified origin, and never discovers conversion tools. Differential fixtures record these exceptions rather than patching the oracle or claiming identical discovery behavior.

Optional delta retrieval/conversion requires an explicit host adapter and host-provided base source. Each invocation has a unique call identity, absolute deadline, bounded result and acknowledged binary delivery. The host owns verified external identity, tools, credentials and temporary state, and supplies idempotent bounded per-call cleanup for success, failure, timeout and owner loss. Shared code never retries a failed conversion or silently replays a partially delivered stream. Without the optional adapter/base, use the verified full-file path. Conversion failures remain visible and retain download identity.

Acceptance separately verifies pinned native projections/full-file protocol and independent adapter bounds, checksum/byte fidelity, ownership and cleanup. Fake conversion proves only the adapter contract. Actual xdelta conversion and subprocess/file cleanup require installed-adapter acceptance; real Incus and Macus hardware evidence remain distinct. The reference pin and missing-entry ledger remain unchanged until each slice has verification evidence.

### 5. Delivery and subsequent work

After implementation and fixture/consumer checks, publish an actual immutable feature revision that Macus can lock, with source/reference provenance and documented direct Elixir usage. Do not invent a Hex release/version or require a sibling checkout for CI/installed consumers. Macus's local gateway/runtime/proxy/client work may proceed from this foundation; later tool/task integration explicitly waits for add-compute-substrate's corresponding milestone. Central enrollment/connectivity never gates standalone embedding/client progress.

## Risks / Trade-offs

- Generated web aliases force SQL into library checks -> distinct core test profile and actual external-consumer startup without database credentials.
- Typed client appears complete after a few JSON calls -> pinned inventory, per-entry evidence and native upgrade/stream fixtures.
- Client credentials or mutable defaults cross connections -> explicit immutable host connection values, safe diagnostics and isolation tests.
- A timeout repeats accepted work -> truthful native operation/uncertainty result and no mutation replay.
- Dependency shutdown or ambient variables affect host runtime -> explicit embedded startup and restart fixtures, independent host lifecycle.

## Migration Plan

Extract the embedded-service/incus-client deltas and their pending implementation tasks from add-compute-substrate into this independently implementable change. Preserve that broader change's historical scaffold task and the seven Macus evidence tasks, with ownership references rather than duplicate client tasks. No deployed client state exists to migrate.

Implement and verify the library first, then select a real immutable consumer revision. Macus adopts it through its own apply workflow and retains native/private bridge state. Do not merge/release/activate services as part of proposing the change. Remaining tools/tasks, central service/OIDC and connectors follow their own pending artifacts.
