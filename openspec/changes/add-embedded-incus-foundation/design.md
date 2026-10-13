# Design

## Context

See [proposal.md](proposal.md). This change was planned and largely implemented inside `upmaru/opsmaru`, then moved with its code and history into `upmaru/opsmaru-incus` on 2026-10-13 (source revision `a00805d`). The rest of this context describes that original baseline. At the original planning baseline, the root Phoenix 1.8/Cowboy application had embedded telemetry only, without Endpoint/Repo/PubSub or an Incus client; generated tests expected Ecto/standalone setup. Implementation now supplies safe embedding, a database-free profile and verified partial client slices. The existing `scripts/check-embedded.exs`, method/type manifest and tasks.md distinguish implemented evidence from remaining tasks 3.9 and 4.3.

Macus has an in-progress headless Phoenix/Cowboy server, private Swift runtime.sock and Incus incus.sock relay, reference method/type inventory and fixture-only native protocol trial. Incus v7.0.1 at `13f3992766142d5087fff2e362cd2e1a75294fe8` is the existing reference baseline; transfer reusable inputs/notices and retain consumer-specific bridge evidence. The inspected dependency baseline is Elixir 1.19.5/OTP 27, Phoenix 1.8.15 and the Cowboy adapter recorded in the current locks; verify actual locked compatibility during implementation rather than inventing a release.

This is the first delivery milestone. Opsmaru's `add-compute-substrate` consumes its library/client and later adds tools, task adapters, central targets and connectors. Opsmaru's `add-remote-api-and-oauth` supplies later central identity/REST/browser adapters. Neither later change is a prerequisite here.

The separately proposed [add-embeddable-incus-gateway](../add-embeddable-incus-gateway/design.md) (planned in Opsmaru, moved to this repository on 2026-10-13) adds optional reusable native HTTP/upgrade relay mechanics under Opsmaru.Incus.Gateway. The host (MacusWeb) supplies the explicitly selected endpoint/router and host policy. It is not a prerequisite for direct real-Incus client acceptance or a replacement for outstanding typed-client behavior.

## Goals / Non-Goals

**Goals:**

- A safely importable pure-library dependency, `:opsmaru_incus`, with a documented public client and host-supplied configuration.
- Native Unix/HTTPS Incus endpoint/method and streaming behavior, transparent declaration provenance and verified consumer-required client behavior.
- Database-free fixture checks and a Macus-compatible external consumer that can pin an implemented revision.

**Non-Goals:**

- Central registry/SQL/OIDC/browser auth, MCP tools, durable application tasks, connector protocol or macus connect.
- Shipping central/connector Linux installers, changing Macus application source, publishing a package release or performing hardware acceptance during planning.
- VZ ownership, host VM CLIs, a workload manager, automatic backend discovery, host commands or workspace/skill provisioning.

## Decisions

### 1. A standalone pure library repository

Deliver the client as OTP application `:opsmaru_incus` in `upmaru/opsmaru-incus`, with no application callback. A library without a supervision tree cannot start an Endpoint, Repo, PubSub, listener or worker on load, so passive embedding holds by construction rather than by a runtime `deployment_mode` switch, and ambient PHX_SERVER/PORT values have nothing to act on. Keep the existing `Opsmaru.Incus.*`, `Opsmaru.Context` and `Opsmaru.ClientSupervisor` module names so consumer call sites are unchanged. Hosts that want bounded concurrency add `Opsmaru.ClientSupervisor` to their own tree; restarting it cannot stop Swift/Incus.

Declare runtime dependencies as version ranges (Mint, MintWebSocket, Jason, cowlib for native multipart/content-type parsing, yamerl for the strict YAML subset) and let each consumer lock exact versions. Plug is test-only. No Phoenix, Ecto, Postgrex, LiveView, asset or OIDC dependency is permitted.

Superseded alternative: the original plan extended the single `:opsmaru` Phoenix app and deferred extraction ("two Mix projects add versioning and wiring before there is separate functionality"). Once the client had a clean boundary and its own gates, keeping it there forced Macus to compile and ship the central service's web/SQL stack and to resolve its versions. A same-repository second Mix project was also considered; a separate repository gives independent tags, CI and a plain Git dependency without a sparse checkout.

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

The library's ordinary `mix test` is the database-free profile: it compiles and runs meaningful tests with no PostgreSQL, DATABASE_URL, OIDC keys, listener or real Incus. (While the client lived in the Opsmaru app this required a separate `:library` Mix environment that bypassed the generated Ecto test alias; extraction removed that need.)

Use fake Unix/HTTPS backends, a pinned official-client differential oracle and deterministic failure/stream fixtures. Start and restart the library with hostile web environment values and verify it has no application callback and creates no processes, ports, state or backend contact. An external Mix consumer fixture uses the Macus-compatible dependency set, hosts its own endpoint/runtime stubs and imports the implemented library without loading a second endpoint/Repo or requiring an absolute sibling source path. Its task is to prove library/client integration, not shared MCP/runner behavior.

Record exactly which method/type entries have implementation/differential evidence. Partial pins may support deliberate Macus development slices, but the change's full-client completion requires every supported entry; no partial implementation is relabeled full parity. Linux real-Incus and Macus consumer bridge/hardware acceptance are separate explicit isolated opt-in gates. No provider, central database or connector setup is part of those foundation checks.

Run task 4.3's direct Unix/verified HTTPS acceptance in this library's repository (originally Opsmaru) against an explicitly supplied isolated real backend, independently of Macus installation or the optional gateway. If gateway acceptance tooling supplies the same environment, reference its exact direct-client results separately from proxy/CLI results. Proxy pass-through cannot close task 3.9, including requests whose typed methods remain missing. Macus installed bridge/VZ/hardware acceptance remains consumer-owned and cannot block an otherwise verified portable foundation.

### 4a. Explicit host-owned OCI conversion adapter

OCI remains in scope. The pinned OCI implementation delegates inspection to skopeo and exports through root-only unpacking, tar processes and temporary directories. The library does not copy those host commands into shared code. Construction accepts an explicit host adapter module and opaque host-owned configuration alongside a verified connection/context; it performs no I/O. The adapter supplies bounded skopeo-compatible inspection JSON and converted metadata/rootfs bytes. Opsmaru preserves native alias normalization, layer-derived fingerprint, architecture names, image models and native unsupported-method errors. Inspection results are connection-local immutable cache values; there is no global registry or automatic discovery.

Each explicit adapter invocation receives a unique call identity and absolute monotonic deadline. The adapter must enforce verified registry identity, isolate credentials, authorize external work and associate all subprocesses/files with that call identity. It must provide idempotent bounded cleanup for completion, failure, deadline and owner loss, without affecting other calls or workloads. Shared code bounds callbacks and sinks, acknowledges binary chunks synchronously, rejects oversized/invalid results and never retries a failed adapter call. Adapter diagnostics are redacted; structured native failures remain available to the caller. No bundled skopeo runner, root escalation, trust generation, temporary state directory or Macus implementation is added here.

Acceptance has distinct layers: unchanged pinned-client fixtures verify native alias/image/unsupported semantics; independent fake adapters verify budgets, readiness, ownership, byte fidelity and cleanup. A fixture adapter proves the contract only. An installed host adapter must separately prove registry TLS, credential isolation, actual conversion contents and process/file cleanup on its supported platform. That installed-adapter gate and real Incus/Macus hardware gates stay explicit and cannot be inferred from fake adapter success. SimpleStreams remains a separate in-scope protocol.

### 4b. Explicit HTTPS SimpleStreams and host-owned delta conversion

SimpleStreams remains in task 3.9. The host supplies a verified HTTPS connection and context explicitly. Construction performs no I/O or local backend discovery. Preserve pinned index/product/image/alias projections, architecture selection, image file names/sizes/fingerprints, full-file checksum validation and supported method errors. Index, metadata and binary responses have explicit size and deadline limits; bytes reach acknowledged bounded sinks. Credentials remain connection-local and redacted. Downloads do not create files or run commands in shared code.

The unchanged Incus v7.0.1 reference probes `/dev/incus/sock`, tries an HTTP URL before HTTPS, and optionally discovers/runs xdelta3 using temporary files. Approved differences are explicit: Opsmaru never probes that socket, never downgrades HTTPS or follows an unverified origin, and never discovers conversion tools. Differential fixtures record these exceptions rather than patching the oracle or claiming identical discovery behavior.

Optional delta retrieval/conversion requires an explicit host adapter and host-provided base source. Each invocation has a unique call identity, absolute deadline, bounded result and acknowledged binary delivery. The host owns verified external identity, tools, credentials and temporary state, and supplies idempotent bounded per-call cleanup for success, failure, timeout and owner loss. Shared code never retries a failed conversion or silently replays a partially delivered stream. Without the optional adapter/base, use the verified full-file path. Conversion failures remain visible and retain download identity.

Acceptance separately verifies pinned native projections/full-file protocol and independent adapter bounds, checksum/byte fidelity, ownership and cleanup. Fake conversion proves only the adapter contract. Actual xdelta conversion and subprocess/file cleanup require installed-adapter acceptance; real Incus and Macus hardware evidence remain distinct. The reference pin and missing-entry ledger remain unchanged until each slice has verification evidence.

### 4c. Approved bounded SFTP v3 helper subset

The two native SFTP convenience constructors remain in scope. On 2026-10-13
the user approved a safe v3 subset after source inspection showed that OTP's
SSH SFTP client cannot consume Incus's raw upgraded stream. Keep the existing
raw-channel APIs. New helpers initialize v3, retain advertised extension bytes
and expose explicit open, positional read/write, file-handle close and session
close. Other SFTP operations fail explicitly; no SSH discovery, host command,
runtime Go sidecar or local file is introduced. This is partial native evidence,
not a full pkg/sftp.Client port or installed-backend acceptance.

Use one owner-bound request at a time with fixed packet, handle, extension,
stream and absolute deadline limits. Compare initialization, request bytes,
binary responses, status codes/messages and helper cleanup against unchanged
pinned Incus and pkg/sftp fixtures over Unix and verified HTTPS. Independent
fixtures must cover fragmented/coalesced packets, malformed/version/oversize
rejection, caller loss, local cancellation and stalled I/O. Close local resources
after negotiation or protocol failure. A possibly dispatched file mutation
must retain its request identity and uncertainty without automatic replay or
deleting backend file state. Unsupported/missing protocol scope and task 3.9's
remaining closure gates stay explicit.

### Approved task 3.9 completion gate (2026-10-13)

Task 3.9 closes on Incus REST endpoints × methods, native streaming/upgrade
types, and the public client behaviors required by `add-incus-operations`.
The endpoint inventory must be verified against the unchanged reference, include
queries/extensions/errors/ETags and asynchronous operation semantics, and expose
unsupported scope and approved differences. The current JSON catalogue alone is
not a complete REST inventory. Required behavior needs typed differential or
independent protocol evidence; proxy/tool success is insufficient.

Keep the 1,280-declaration inventory and every partial/missing mapping visible.
Go interfaces, constants and transport abstractions are provenance rather than
the task's completion unit. Do not promote mappings or `complete_port` merely
because task 3.9 closes. Installed OCI/delta adapters, direct-backend acceptance
and consumer-owned Macus hardware evidence remain separately recorded gates.

#### Verified slice: noninteractive exec collection

Collect live stdout/stderr from an already accepted, creator-owned noninteractive
`Session.exec/3` session with `wait-for-websocket=true` and no recorded output.
The caller supplies both acknowledged binary sinks and sends any stdin explicitly
before collection; collection sends the native stdin write barrier. Pull both
output channels concurrently with at most one outstanding read each. Enforce an
aggregate output byte limit and one absolute collection deadline covering sink
callbacks and authoritative operation completion. Return final operation identity,
native exit status and delivered byte counts only after both output barriers/EOF
and successful operation completion; a nonzero guest exit is data, not a native
operation failure. Stream EOF alone never establishes command completion.

Sink rejection/exception, excess output, cancellation, deadline, channel failure
or owner loss must stop local work and close session channels without backend
cancellation or mutation replay. Errors retain the accepted operation and binding.
Invalid options or sessions reject before channel IO. Recorded-file output,
interactive console, tool policy, command selection and buffered/truncated MCP
results are outside this slice. Compare actual unchanged native ExecInstance IO
over Unix and verified HTTPS and independently verify budgets and cleanup. Stop
and offer scope options if implementation grows beyond a few hundred lines,
requires a handwritten parser or accumulates repeated corner-case/DoS fixes.

#### Approved next slice: bounded full-duplex noninteractive exec

Add a call-scoped client helper combining native exec submission, channel
negotiation, finite binary stdin, acknowledged stdout/stderr sinks and final
operation completion. Validate live noninteractive mode, sink/options and stdin
budget before submission. Native command/environment fields retain the existing
typed request and request-byte bounds; tool-specific argument policy remains in
`add-incus-operations`. Drain both outputs while sending stdin in bounded chunks,
with one outstanding write and one read per output. Send the native input barrier
only after all input writes acknowledge; completion requires that barrier and
both output barriers/EOF plus authoritative operation completion.

One absolute local lifetime starts before POST and covers negotiation, input,
sink callbacks and final wait, respecting a shorter host context and its
cancellation without cancelling unrelated host work. Retain any accepted operation
and binding even when negotiation or a callback stalls. Unknown acceptance remains
uncertain. Close local workers/channels on all terminal paths without backend
DELETE or replay. Keep interactive/recorded output, arbitrary input sources,
buffered/truncated tool results and MCP policy outside this slice. Compare actual
unchanged native IO over Unix and verified mutual HTTPS; independently verify
blocked input, simultaneous output, limits, deadlines, cancellation and owner
cleanup without tight wall-clock assertions. Reuse existing fixtures and stop
if this slice grows beyond a few hundred lines or needs scope expansion.

### 5. Delivery and subsequent work

After implementation and fixture/consumer checks, publish an actual immutable revision of `upmaru/opsmaru-incus` that Macus and Opsmaru can lock, with source/reference provenance and documented direct Elixir usage. Do not invent a Hex release/version or require a sibling checkout for CI/installed consumers. Macus's local gateway/runtime/proxy/client work may proceed from this foundation; later tool/task integration explicitly waits for add-compute-substrate's corresponding milestone. Central enrollment/connectivity never gates standalone embedding/client progress.

## Risks / Trade-offs

- Generated web aliases force SQL into library checks -> distinct core test profile and actual external-consumer startup without database credentials.
- Typed client appears complete after a few JSON calls -> pinned inventory, per-entry evidence and native upgrade/stream fixtures.
- Client credentials or mutable defaults cross connections -> explicit immutable host connection values, safe diagnostics and isolation tests.
- A timeout repeats accepted work -> truthful native operation/uncertainty result and no mutation replay.
- Dependency shutdown or ambient variables affect host runtime -> explicit embedded startup and restart fixtures, independent host lifecycle.

## Migration Plan

Originally the embedded-service/incus-client deltas and their pending tasks were extracted from Opsmaru's add-compute-substrate into this independently implementable change. On 2026-10-13 the change, the client code, fixtures, scripts and docs moved with history from `upmaru/opsmaru` (`a00805d`) into `upmaru/opsmaru-incus`. Files were byte-identical apart from relocating `test/library/` to `test/` and adapting path references and application-mode checks. No deployed client state exists to migrate.

Continue task 3.9 here. Consumers then pin a real immutable revision of this repository: Macus adopts it through its own apply workflow and retains native/private bridge state; Opsmaru removes its in-app copy and depends on `:opsmaru_incus` where later changes need the client. Earlier `:opsmaru` revisions remain valid historical pins. Do not merge/release/activate services as part of this change.
