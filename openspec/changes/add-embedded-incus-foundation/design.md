# Design

## Context

See [proposal.md](proposal.md). The root Phoenix 1.8/Cowboy application already exists and its embedded branch supervises telemetry only, without Endpoint/Repo/PubSub. The existing `scripts/check-embedded.exs` verifies that narrow baseline. There is no Incus client implementation yet. `mix.exs` generates a `test` alias that runs Ecto setup and `config/test.exs` selects standalone web tests; these are unsuitable as the only checks for a reusable no-database library.

Macus has an in-progress headless Phoenix/Cowboy server, private Swift runtime.sock and Incus incus.sock relay, reference method/type inventory and fixture-only native protocol trial. Incus v7.0.1 at `13f3992766142d5087fff2e362cd2e1a75294fe8` is the existing reference baseline; transfer reusable inputs/notices and retain consumer-specific bridge evidence. The inspected dependency baseline is Elixir 1.19.5/OTP 27, Phoenix 1.8.15 and the Cowboy adapter recorded in the current locks; verify actual locked compatibility during implementation rather than inventing a release.

This is the first delivery milestone. `add-compute-substrate` consumes its library/client and later adds tools, task adapters, central targets and connectors. `add-remote-api-and-oauth` supplies later central identity/REST/browser adapters. Neither later change is a prerequisite here.

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
