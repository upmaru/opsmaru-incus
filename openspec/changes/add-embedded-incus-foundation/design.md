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

Deliver the client as OTP application `:opsmaru_incus` in `upmaru/opsmaru-incus`, with no application callback. A library without a supervision tree cannot start an Endpoint, Repo, PubSub, listener or worker on load, so passive embedding holds by construction rather than by a runtime `deployment_mode` switch, and ambient PHX_SERVER/PORT values have nothing to act on. Expose the client and its helpers under `Opsmaru.Incus.*`. Hosts that want bounded concurrency add `Opsmaru.Incus.ClientSupervisor` to their own tree; restarting it cannot stop Swift/Incus.

The approved namespace cleanup (2026-10-14) moves the trusted host binding to
`Opsmaru.Incus.Context` and optional supervision to `Opsmaru.Incus.ClientSupervisor`.
This supersedes the extraction's decision to retain top-level helper names.
Move the files, module declarations, Inspect implementation and every repository
call site/documentation reference together, including the isolated consumer and
planned shared-operation host contract. Preserve all function bodies, struct
fields, readiness/owner checks, redaction, capacity/restart and startup behavior.
Do not add compatibility modules or convert between two context structs. Consumers
must update aliases, struct references and child specifications when pinning the
new revision. This cleanup adds no native behavior or coverage-completion claim.

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

#### Approved slice: S08 raw SFTP/NBD upgrade certification (2026-10-29)

Certify stream contract S08 under a single reviewed record in one PR. Two rows
then have no open stream contract and complete:

- instance NBD on `GET /1.0/instances/{name}/nbd` (B11)
- custom volume NBD on `GET /1.0/storage-pools/{pool}/volumes/{type}/{name}/nbd`
  (B08)

The two SFTP rows are also linked to S09 and stay partial until S09 is
certified in its own PR.

User decisions (2026-10-29):

- The raw helpers work like the pinned Go client. `Incus.sftp/2`, `nbd/3`,
  `volume_sftp/4` and `volume_nbd/5` match `GetInstanceFileSFTPConn`,
  `GetInstanceNBDConn`, `GetStoragePoolVolumeFileSFTPConn` and
  `GetStoragePoolVolumeBlockNBDConn`. Name segments are no longer checked
  locally: any binary, including an empty, long or non-UTF-8 name, is escaped
  like Go's `url.PathEscape` and sent, so the server answers with its native
  error. Only the extension guards the pinned client checks (`instance_nbd`,
  `custom_volume_sftp`, `storage_volume_nbd`) run before I/O. The `reuse` and
  `writable` options keep their boolean type checks, which stand in for Go's
  typed `InstanceNBDArgs` and `StorageVolumeNBDPost`. A Go caller cannot pass
  anything else.
- Protocol bytes that arrive coalesced with the 101 response are kept. This
  is an approved difference. The pinned `rawConn` discards bytes buffered with
  the response, and copying that would corrupt streams.
- Over mutual HTTPS, a backend half-close ends the connection, which is an
  approved difference (decided during implementation). OTP TLS closes on the
  peer's `close_notify`, where a Go `tls.Conn` can keep writing. Later writes
  return `:write_closed`, never a silent loss, and bytes already received stay
  readable. incusd's `UpgradeResponse` never half-closes, so a real daemon
  never triggers this. Unix half-close matches the pinned client.
- Any process may use a raw channel, as with a Go `net.Conn`. The channel
  closes on `close/1`, peer closure or the existing finite stream lifetime,
  and when the process that opened it exits. This is the Elixir equivalent
  of the connection closing with its Go program.

The PR covers:

- a new differential for the instance helpers against the pinned client on
  Unix and mutual HTTPS: SFTP and NBD with `reuse` off and on, project and
  target routing, Upgrade and Connection headers, initial and echoed bytes,
  and Go argument handling for empty, long and special-character names
- backend half-close compared with the pinned connection, then writes after
  read EOF over Unix and the explicit `:write_closed` refusal over HTTPS
- the existing volume differential, coalesced-byte, native rejection without
  retry, caller loss, lifetime, byte-bound and handshake-deadline evidence,
  linked rather than repeated
- a raw-upgrade record kind that certifies S08 and completes the two NBD rows.
  The selected manifest grows 243 -> 245 pairs, all complete, and the
  certified stream contracts become S01, S02, S03, S04, S05, S06, S07, S08
  and S10.

Approved exclusions:

- cluster forwarding beyond host project and target routing
- NBD export and SFTP file semantics on a real daemon, which stay with
  separately recorded opt-in real-Incus acceptance. The NBD payload protocol
  stays caller-owned.

The library-wide request-path bound and host identity and readiness checks are
unchanged. The PR updates the ledgers, closure ledger, backlog, client docs and
generated coverage. Task 3.9, `complete_port` and every Go declaration status
are unchanged.

#### Approved slice: S02 console certification (2026-10-28)

Certify stream contract S02 under a single reviewed record in one PR. Two rows
then have no open stream contract and complete:

- console attachment on `POST /1.0/instances/{name}/console`
- the operation WebSocket on `GET /1.0/operations/{id}/websocket`, whose other
  linked contracts (S01 and S10) are already certified

User decisions (2026-10-28):

- The static `Session.console/3` matches the pinned `ConsoleInstance`. It
  validates the body as `InstanceConsolePost` and requires the control and data
  secrets in the accepted metadata. It then opens the control channel, then
  channel 0, and ignores any other channel. Missing or malformed secrets fail
  closed, before any channel opens, and keep the accepted operation; no channel
  is opened with an empty secret. `Session.close/1` sends the pinned
  `1000 "Detaching from console"` close frame on a console's control channel.
  A new Go driver compares the static console with the pinned helper.
- Console orchestration is explicit, which is an approved difference. Hosts
  send and receive frames, write barriers, resize and detach themselves; there
  is no `Control` callback, `ConsoleDisconnect` channel or `ws.Mirror` helper.
  Evidence shows the explicit calls produce the same wire frames as the pinned
  helpers.
- Local argument checks happen before the POST, which is an approved
  difference. The pinned client sends the POST and only then rejects a nil
  `Terminal` or `Control`, leaving an accepted console orphaned. The method
  fixture still compares the pinned POST body and its post-acceptance error.

The PR covers:

- the static and dynamic consoles compared with the pinned `ConsoleInstance`
  and `ConsoleInstanceDynamic` on Unix and mutual HTTPS: `console` and `vga`
  types, width and height, `force`, the `console_vga_type` and `console_force`
  guards before dispatch, control frames, data frames and write barriers, and
  the detach close frame
- native 400/403/404 rejection, and lost or malformed replies that are
  uncertain and never replayed
- existing evidence for repeated dynamic attachments, capacity, owner loss,
  lifetimes, channel failures and peer closure, linked rather than repeated
- a console record kind that certifies S02 and completes the two rows. The
  selected manifest grows 242 -> 243 pairs, all complete, and the certified
  stream contracts become S01, S02, S03, S04, S05, S06, S07 and S10.

Approved exclusions:

- the `?public` documentation view of the operation WebSocket, like the earlier
  `?public` exclusions
- cluster forwarding beyond host project and target routing

The server's control commands stay native: hosts may send any bounded JSON
control message, and the daemon acts only on `window-resize`. Real-daemon
console acceptance stays separately recorded. The PR updates the ledgers,
closure ledger, backlog, client docs and generated coverage. Task 3.9,
`complete_port` and every Go declaration status are unchanged.

#### Approved slice: S05 image binary handoff and copy certification (2026-10-28)

Certify stream contract S05 under a single reviewed record and complete the
three rows linked to it, which then have no open stream contract:

- image creation, upload and copy target on `POST /1.0/images`
- image download on `GET /1.0/images/{fingerprint}/export`
- push export on `POST /1.0/images/{fingerprint}/export`

This also lands the image copy deferred from S10. The operation WebSocket row
stays partial while S02 is open.

User decisions (2026-10-28):

- The `?public` documentation views on image export and `POST /1.0/images`
  serve unauthenticated clients. `Connection.https!` always presents a client
  certificate, so they are approved exclusions, like the B11 public alias view.
  The daemon-to-daemon push upload (fingerprint and secret headers) is still
  certified through `Images.import/4`.
- Image copy cleanup is explicit. `Images.copy/4` stays free of side effects
  and returns its native handles. A new `Images.wait_copy/2` waits on the
  operation that drives the copy (the target in pull and relay mode, the source
  export in push mode) and then performs the pinned cleanup explicitly:
  - in push mode, it cancels the target's token operation
  - in relay mode, and in pull mode against a target without
    `image_create_aliases`, it creates the requested aliases

  When the source export fails in push mode, `copy` returns the accepted token
  handle with the error and does not cancel it; the host cancels with
  `Operation.cancel/1`. This is an approved difference from the pinned client,
  which cancels the token itself.
- Certify every `CreateImage` source kind, so `POST /1.0/images` can complete:
  binary upload, image pull and push, URL, and instance and snapshot publish.
- Two PRs. Rows linked to S05 complete only once S05 is certified.

PR 1: image binary and create control plane, with rows still partial.

- `CreateImage` JSON bodies for every source kind (image pull with and without
  a secret, push token request, URL, instance and snapshot publish) on Unix and
  mutual HTTPS, compared with the pinned `CreateImage(image, nil)`. Coverage
  includes schema-driven bodies, the `image_compression_algorithm` guard before
  dispatch, accepted operations with native `/wait`, native 400/403/404/409, and
  lost or malformed replies that are uncertain and never replayed.
- `Images.import/4` binary uploads compared with the pinned
  `CreateImage(image, args)` on both transports: unified and split images, the
  container `rootfs` and virtual-machine `rootfs.img` parts, compression, and
  the public, filename, properties, profiles, aliases and push
  fingerprint/secret headers. Request bytes and headers are compared, and a
  lost upload is uncertain and never replayed.
- `Images.download/4` compared with the pinned `GetImageFile` and
  `GetPrivateImageFile` on both transports: unified and split exports, private
  secret encoding, names, sizes and bytes, OCI exports that skip the
  fingerprint check, fingerprint mismatch, a split export with one sink,
  native errors, sink failure and deadlines.
- `ExportImage` compared with the pinned method, including the
  `images_push_relay` guard. No row completes and S05 stays open.

PR 2: image copy and certification.

- `Images.copy/4` pull, push and relay end to end on mutual HTTPS, compared
  with the pinned `CopyImage`: requests, secrets, aliases (`copy_aliases` and
  explicit), profiles with the `image_copy_profile` guard, `auto_update`,
  `public` and image type. Pull and push need the host-approved origin; a Unix
  peer is refused before any request.
- `Images.wait_copy/2` compared with the pinned `RemoteOperation.Wait` for
  success, failure and cancellation, including token cancellation and alias
  creation where the pinned client performs them. Any other divergence is
  recorded for approval.
- Lost or malformed source and target replies are uncertain and never
  replayed. Every handle already accepted is kept.
- An image-transfer record kind certifies S05 and completes the three rows. The
  selected manifest grows 239 -> 242 pairs (241 complete), and the certified
  stream contracts become S01, S03, S04, S05, S06, S07 and S10.

Approved exclusions:

- the `?public` documentation views
- the pinned `/dev/incus/sock` download path, since the library never probes
  local sockets
- trying each address a server advertises; pull and push use one host-approved
  origin
- cluster forwarding beyond host project and target routing

Already-approved boundaries stay as they are:

- relay stages bytes through host adapters rather than temporary files
- hosts observe progress through their own sinks and sources, not a progress
  callback
- connection deadlines replace the pinned 30-second response-header timeout

Copies whose source is a SimpleStreams or OCI server stay with S12 and S11.
Real-daemon image acceptance stays separately recorded. Each PR updates the
ledgers, closure ledger, backlog, client docs and generated coverage. Task 3.9,
`complete_port` and every Go declaration status are unchanged.

User decisions during PR 2 (2026-10-28), recorded as approved differences:

- A push to a source without `images_push_relay` is refused before the target
  token request. The pinned client asks for the token, fails the `ExportImage`
  guard and then cancels the token.
- The pinned relay builds its failure with `remoteOperationError(msg, nil)`,
  which returns nil, so a failed or cancelled relay upload reports success.
  `Images.wait_copy/2` reports the native failure instead. Neither creates
  aliases.

PR 2 shape: `Images.copy/4` returns an `ImageCopy` with the bound `source` and
`target` operation handles and takes `:approved_origin`, the exact HTTPS origin
of the side the other backend connects to. Failures keep the accepted handles
in `response.accepted`. A local wait deadline in `wait_copy/2` performs no
cleanup, because the copy may still be running.

#### Approved slice: S10 copy and migration certification (2026-10-27)

Certify stream contract S10 under a single reviewed record and complete the
five rows that then have no open stream contract:

- `POST /1.0/instances`, whose S06 import modes are already certified
- instance rename and migration on `POST /1.0/instances/{name}`
- snapshot rename and migration on `POST /1.0/instances/{name}/snapshots/{snapshot}`
- volume create, migration target and import on
  `POST /1.0/storage-pools/{pool}/volumes/{type}`
- custom volume rename, move and migration on
  `POST /1.0/storage-pools/{pool}/volumes/{type}/{volume}`

The collection `POST /1.0/storage-pools/{pool}/volumes`, deferred by B08 to
volume create, completes with them. The operation WebSocket row stays partial
while S02 is open, and both image rows (`POST /1.0/images` and image export)
stay partial while S05 is open.

User decisions (2026-10-27):

- Image copy is deferred to S05. S10 does not change `Images.copy`; its origin,
  option validation and private, alias, profile, auto-update and relay
  comparisons land with the image rows they complete.
- Relay stays strict and fail-closed. Where it agrees with the pinned
  `proxyMigration`, channel names and relayed bytes are compared. Three
  differences are recorded as approved:
  - source and target secret sets must be identical, where the pinned client
    accepts a source superset
  - a channel that fails to open closes every channel, where the pinned client
    skips that data socket
  - relay is an explicit `Migration.relay/2` call, not started inside `Copy.*`
- Live instance and stateful snapshot migration use generic channel evidence:
  `control`, `fs` and `criu` are host-approved channels negotiated and relayed
  on both transports. Real CRIU acceptance stays a separate gate.
- Add a typed REST descriptor for the collection volume POST, mirroring the
  `CreateStoragePoolVolume` and `CreateStoragePoolVolumeFromMigration` bodies
  and compared through unchanged Go RawQuery plus fixtures.
- Two PRs. Rows linked to S10 complete only once S10 is certified.

PR 1: migration control plane, with rows still partial.

- `RenameInstance`, `MigrateInstance`, `RenameInstanceSnapshot`,
  `MigrateInstanceSnapshot`, `CreateStoragePoolVolume`,
  `CreateStoragePoolVolumeFromMigration`, `RenameStoragePoolVolume` and
  `MigrateStoragePoolVolume` join the sync- and async-mutation contract tests on
  Unix and mutual HTTPS, compared with the named pinned methods.
- Coverage includes schema-driven bodies, the `migration` true/false guards and
  every extension guard before dispatch (`instance_only`, pool and project
  move, `allow_inconsistent`, volume rename, remote volume handling and
  snapshot copy), accepted operations with native `/wait`, native
  400/403/404/409 and lost or malformed replies that are uncertain and never
  replayed.
- `CreateInstance` migration and copy sources (pull, push and local copy) are
  compared on both transports. No row completes and S10 stays open.

PR 2: copy orchestration and certification.

- `Copy.instance/4`, `Copy.snapshot/5` and `Copy.volume/6` in relay mode end
  to end on both transports, compared with the pinned `Copy*` relay where the
  behaviour agrees, plus the three recorded relay differences.
- Remote pull and push copies with `wait_target` and `cancel_target` compared
  with the pinned `RemoteOperation` `Wait` and `CancelTarget`.
- Lost or malformed source and target replies are uncertain and never
  replayed. A push whose source fails keeps the accepted target handle.
- `MigrateInstance` pool, project and target-member moves, and live and
  stateful negotiation and relay with `control`, `fs` and `criu`.
- The collection volume POST descriptor.
- A `migration` record kind certifies S10 and completes all five rows and the
  collection POST. The selected manifest grows 234 -> 239 pairs (238
  complete), and the certified stream contracts become S01, S03, S04, S06, S07
  and S10.

Approved exclusions: cluster forwarding beyond host project/target routing, and
trying each address a server advertises. Pull and push use one host-approved
origin. Deployed-cluster and real CRIU acceptance stay separately recorded. Each
PR updates the ledgers, closure ledger, backlog, client docs and generated
coverage. Task 3.9, `complete_port` and every Go declaration status are
unchanged.

#### Approved slice: S06 backup and archive certification (2026-10-26)

Certify stream contract S06 under a single reviewed record and complete the 19
rows linked only to S06:

- instance, custom volume and bucket backups: list, get, create, rename,
  delete and export
- bucket creation, whose archive mode is bucket import

Certifying S06 also covers its archive modes on the two rows shared with S10:

- instance backup import on `POST /1.0/instances`
- volume import, including ISO, on `POST /1.0/storage-pools/{pool}/volumes/{type}`

Those two rows then wait only on S10.

User decisions (2026-10-26):

- Add typed REST descriptors for the bucket backup calls the pinned client
  lacks, compared through unchanged Go RawQuery plus fixtures:
  - `GetStoragePoolBucketBackupNames`
  - `GetStoragePoolBucketBackups` (recursion=1)
  - `GetStoragePoolBucketBackup`
  - `RenameStoragePoolBucketBackup` (an accepted operation)

  These close the last three confirmed typed implementation gaps (3 -> 0).
- Certify every S06 obligation now, including the shared import and ISO modes.
- Two PRs. Rows linked to S06 complete only once S06 is certified.

PR 1: backup control plane, with rows still partial.

- The list, get, create, rename and delete calls for instance, volume and
  bucket backups, plus JSON bucket creation, join the inspection and
  sync-mutation contract tests on Unix and mutual HTTPS. They are compared with
  the named pinned methods, or with RawQuery for the new descriptors.
- Coverage includes schema-driven bodies (expiry, compression, instance-only
  and optimized-storage options), accepted operations with native `/wait`,
  native errors and lost replies.
- The three missing-typed bucket backup rows become `catalogue`. No row
  completes and S06 stays open.

PR 2: archive streams and certification.

- Export downloads for instance, volume and bucket backups.
- Direct backup POST to a sink (`backup_stream`).
- Imports:
  - instance backup import, with name, pool, config and device overrides
  - volume import and ISO
  - bucket import
- All on both transports, compared with the pinned `GetInstanceBackupFile`,
  `CreateInstanceBackupStream`, `CreateInstanceFromBackup` and their volume and
  bucket counterparts. Coverage includes byte and deadline bounds, mid-stream
  cancellation and caller loss, uncertain lost uploads that are never
  replayed, and no implicit host files.
- An `archive` record kind certifies S06 and completes all 19 rows. The selected
  manifest grows 215 -> 234 pairs (232 complete), and the certified stream
  contracts become S01, S03, S04, S06 and S07.

Approved exclusion: cluster forwarding beyond host project/target routing. Each
PR updates the ledgers, closure ledger, backlog, client docs and generated
coverage. Task 3.9, `complete_port` and every Go declaration status are
unchanged.

#### Approved slice: S04 file transfer certification with B06 HEAD (2026-10-26)

Certify stream contract S04 under a single reviewed record and complete its 8
rows in one PR:

- instance files: read, create, delete and HEAD
- custom volume files: read, create, delete and HEAD

The two HEAD rows are the B06 gaps. With them, confirmed typed implementation
gaps fall 5 -> 3, leaving only the bucket backup pairs.

- New typed helpers `Opsmaru.Incus.Files.head/3` and `volume_head/5` send a
  native `HEAD /files?path=...`. They return the parsed file metadata (owner,
  group, mode, type, modification time and, for files, size) from the response
  headers through the shared `FileHeaders` parser, which is already compared
  with the pinned `GetInstanceFile` header parsing. An unexpected body is
  rejected.
- Instance and volume read, create and delete are compared with the named
  pinned methods (`GetInstanceFile`, `GetStorageVolumeFile` and their create and
  delete counterparts) through a dedicated files reference driver. The pinned
  client has no HEAD method, so HEAD is evidenced by independent fixtures.
- Every helper runs on Unix and mutual TLS (the fixture requires a client
  certificate). The contract covers:
  - file, directory and symlink types
  - uid, gid and mode
  - overwrite and append write modes
  - path selector and project/target routing
  - binary bytes to an acknowledged sink and directory entries as metadata
  - native 400/403/404
  - byte and deadline bounds
  - mid-stream cancellation and caller loss
  - lost upload or delete replies, which are uncertain and never replayed
  - preflight extension guards (`file_delete`, `directory_manipulation`,
    `file_symlinks`, `file_append`)
- A `file_transfer` record kind names the S04 cases. As decided for B08, every
  volume type is passed through unchanged.

User decisions (2026-10-26):

- Add typed HEAD helpers evidenced by independent fixtures and the shared header
  parser.
- Approved exclusions:
  - agent-mode file access (`/1.0/files` on an incus-agent connection), since
    this library talks to the daemon only
  - cluster forwarding beyond host project/target routing
- One PR: the selected manifest grows 207 -> 215 pairs (213 complete), and the
  certified stream contracts become S01, S03, S04 and S07.

The PR updates the ledgers, closure ledger, backlog, client docs and generated
coverage. Task 3.9, `complete_port` and every Go declaration status are
unchanged.

#### Approved slice: S07 auxiliary byte stream certification (2026-10-26)

Certify stream contract S07 and complete the 8 rows linked only to it, in one PR,
under a single reviewed record (a stream contract is certified by exactly one
record). The rows and their helpers:

- `GET /1.0/metrics`: `metrics/2`
- `GET /1.0/network-acls/{name}/log`: `network_acl_log/3`
- `GET /1.0/instances/{name}/logs/{filename}`: `instance_logfile/4`
- `GET /1.0/instances/{name}/console`: `instance_console_log/3`
- `GET /1.0/instances/{name}/debug/memory`: `instance_debug_memory/4`
- instance metadata templates:
  - `GET` lists names (`GetInstanceTemplateFiles`) or downloads one by `path`
    (`instance_template_file/4`)
  - `POST` uploads one (`create_instance_template_file/4`)
  - `DELETE` removes one (`DeleteInstanceTemplateFile`)

A new `byte_stream` record kind names the S07 cases. The validator still derives
extension guards from the two listed catalogue methods.

- Each download is compared with the named pinned Go method on Unix and mutual
  HTTPS, covering:
  - the request: path, exact selectors (`path`, `format`) and project/target
    routing
  - the bytes delivered to an acknowledged sink
  - native error envelopes
  - byte, chunk and deadline bounds
  - mid-stream cancellation and caller loss, which close the peer and stop the
    sink
  - no host file writes
- The template upload is compared for its body bytes and headers. A lost
  upload reply is uncertain and never replayed.
- The template list and delete use the inspection and sync-mutation contract
  tests.

The existing `streams_test.exs` evidence covers most of this on Unix, so the
slice extends it to both transports and adds mid-stream cancellation.

User decisions (2026-10-26):

- Approved exclusions:
  - the console `type` selector (`log`/`vga` screenshot), which the pinned
    client never sends; the helper keeps downloading the text console log
  - cluster forwarding beyond host project/target routing
- One PR. The selected manifest grows 199 -> 207 pairs (205 complete), and the
  certified stream contracts become S01, S03 and S07.

The PR updates the ledgers, closure ledger, backlog, client docs and generated
coverage. Task 3.9, `complete_port` and every Go declaration status are
unchanged.

#### Approved slice: B07 recorded exec output and B12 debug repair (2026-10-25)

Complete the three B07 rows and the B12 row, plus the supplemental
`POST /1.0/instances/{name}/debug/repair` server row, in one PR. These are the
last stream-free rows apart from the deferred collection volume POST.

B07 recorded exec output (`container_exec_recording`). The pinned client has
only private helpers, which `ExecInstance` uses in record-output mode and which
delete each file automatically after fetching it. This client never deletes
implicitly.

- `GetInstanceExecOutputNames`: a REST descriptor listing the recorded output
  files of an instance (`GET /logs/exec-output`, names result).
- `Opsmaru.Incus.Streams.instance_exec_output/4`: a helper that streams one
  recorded file (`GET /logs/exec-output/{filename}`) to an acknowledged sink,
  within the connection's response bound, like `instance_logfile/4`.
- `DeleteInstanceExecOutput`: a REST descriptor for the explicit delete (empty
  synchronous result). A lost or malformed reply is uncertain and never
  replayed.

B12 debug repair (`instances_debug_repair`). The REST document lists
`GET /1.0/instances/{name}/debug/repair`, but the daemon registers only `POST`,
with an `InstanceDebugRepairPost` body (`action`) and an empty synchronous
result.

- `RepairInstance`: a REST descriptor for the typed `POST`, certified against
  the daemon route under a `sync_mutation` record.
- The documented `GET` is never sent. Its row completes under the same record,
  with the `GET` view recorded as an approved source discrepancy (exclusion).
- The validator learns to complete the supplemental `POST` server row through
  that record.

User decisions (2026-10-25):

- Evidence: list, delete and repair are compared through unchanged Go
  RawQuery. The download is covered by independent fixtures: path and identity
  isolation, missing output, response bound, native errors and lifetime
  cleanup. The pinned `ExecInstance` record-output path is not driven.
- B12: add the typed `POST` and record the documented `GET` as an approved
  source discrepancy.
- File names: the client rejects only empty, slash and dot-segment names
  before I/O. The daemon's own record-output name rule and its native 400 stay
  authoritative.
- Approved exclusion: cluster forwarding beyond host project/target routing.

The selected manifest grows 195 -> 199 pairs (197 complete), and confirmed typed
implementation gaps fall 9 -> 5 (the two B06 HEAD pairs and three bucket backup
pairs remain). The PR updates the ledgers, closure ledger, backlog, client docs
and generated coverage. Task 3.9, `complete_port` and every Go declaration
status are unchanged.

#### Approved slice: B11 stream-free instance and image completion (2026-10-24)

Complete all 19 B11 rows that have no stream contract, in one PR, under reviewed
completion records. The 23 B11 rows linked to open stream contracts stay partial.

- Reads (5 rows, 6 methods) use `read_contract` records through the inspection
  contract test and schema-driven `ModelSamples`:
  - image aliases (names and list) and an image alias
  - instance access
  - instance log file names
  - instance metadata
- Writes (14 rows, 14 methods) use the sync-mutation contract test:
  - Nine synchronous writes use `sync_mutation` records: image alias create,
    rename, update and delete; image update; instance metadata update; console
    log delete; log file delete; instance bitmap create.
  - Five asynchronous writes use `async_mutation` records with native `/wait`
    evidence: image refresh, image secret, instance rebuild, instance snapshot
    update and the project-wide `UpdateInstances` state change.
- `CreateImageSecret` returns the secret in its operation metadata. Response
  and operation values already redact their payload in `Inspect`; the test
  asserts the secret is not shown.

User decisions (2026-10-24):

- Certify `UpdateInstances` (`PUT /1.0/instances`) as an ordinary
  asynchronous write. Whether tools may expose a project-wide state change is
  a separate tool-policy decision.
- Approved exclusions:
  - the untrusted `GET /1.0/images/aliases/{name}?public` view, for
    verified-identity connections only, consistent with earlier slices
  - cluster forwarding beyond host project/target routing
- One PR for all 19 rows: the selected manifest grows 176 -> 195 pairs (193
  complete).

The PR updates the ledgers, closure ledger, backlog, client docs and generated
coverage. Task 3.9, `complete_port` and every Go declaration status are
unchanged.

#### Approved slice: B08 stream-free storage completion (2026-10-24)

Complete 28 of the 29 B08 rows that have no stream contract, under reviewed
completion records: storage pools, buckets and bucket keys, pool resources,
volume state, volume snapshots and bitmaps, and volume rebuild. The 20 B08 rows
linked to open stream contracts (S04, S06, S08, S09, S10) stay partial.

- Reads (11 rows, 25 methods) use `read_contract` records through the inspection
  contract test and schema-driven `ModelSamples`.
- Writes (17 rows, 17 methods) use the sync-mutation contract test.
  Synchronous writes use `sync_mutation` records. The four asynchronous rows
  (volume snapshot create, rename and delete, and volume rebuild) use
  `async_mutation` records with native `/wait` evidence.
- `CreateStoragePoolBucketKey` returns a `StorageBucketKey` model. Its
  synchronous result is compared field by field with the pinned client, so the
  harness gains a model-result path.
- Bitmap create and delete are empty synchronous responses in both the daemon
  and the pinned client, although the REST document lists delete as an
  operation.

User decisions (2026-10-24):

- The volume type is a pass-through path argument. Every method that takes one
  is compared with the pinned client for each daemon type (custom, container,
  virtual-machine and image), so no volume type exclusion is recorded.
- Add four typed REST descriptors where the pinned client has no method:
  `GetStoragePoolVolumeTypeNames`, `GetStoragePoolVolumesByType` and
  `GetStoragePoolVolumesByTypeFull` for `GET /1.0/storage-pools/{pool}/volumes/{type}`
  (names, recursion=1, recursion=2), and `GetStorageVolumeBitmap` for the single
  bitmap read.
  - Evidence is unchanged Go RawQuery transport plus independent fixtures.
  - Each descriptor takes the extension of the matching pinned method:
    `storage` and `storage_volume_full` for the lists, and
    `storage_volume_nbd` for the bitmap.
- Defer `POST /1.0/storage-pools/{pool}/volumes`. It is the same daemon handler
  as the typed create path, which takes the type from the body, and the pinned
  client never sends it. The row stays partial until it is reconciled with the
  stream-linked volume create row.
- Approved exclusions:
  - `filter` and `all-projects` on the names-only bucket view, since the
    pinned client has no names method that sends them; filtering stays
    certified on the recursion methods
  - cluster forwarding beyond host project/target routing

PR 1 — 11 read rows:

- Rows: buckets, bucket, bucket keys, bucket key, pool resources, volumes by
  type, bitmaps, bitmap, volume snapshots, volume snapshot and volume state.
- Ledgers: the selected manifest grows 148 -> 159 pairs (157 complete), and
  confirmed typed gaps fall 11 -> 9.

PR 2 — 17 write rows:

- Pools: create, update and delete.
- Buckets: update and delete.
- Bucket keys: create, update and delete.
- Volumes: update and delete.
- Bitmaps: create and delete.
- Volume snapshots: create, rename, update and delete.
- Volumes: rebuild.
- Ledgers: the manifest grows 159 -> 176 pairs (174 complete).

Each PR updates the ledgers, closure ledger, backlog, client docs and generated
coverage. Task 3.9, `complete_port` and every Go declaration status are
unchanged.

#### Approved slice: B05 PATCH completion (2026-10-23)

Complete all 24 B05 PATCH rows under reviewed `conditional_patch` records, one
method per row. The four existing descriptors (`PatchProject`, `PatchProfile`,
`PatchImage`, `PatchInstanceSnapshot`) are certified, and 20 new REST
descriptors are added: `PatchServer`, `PatchCertificate`, `PatchClusterGroup`,
`PatchClusterMember`, `PatchImageAlias`, `PatchInstanceMetadata`,
`PatchNetworkACL`, `PatchNetworkAddressSet`, `PatchNetworkIntegration`,
`PatchNetworkZone`, `PatchNetworkZoneRecord`, `PatchNetwork`,
`PatchNetworkForward`, `PatchNetworkLoadBalancer`, `PatchNetworkPeer`,
`PatchStoragePool`, `PatchStoragePoolBucket`, `PatchStoragePoolVolume`,
`PatchStoragePoolVolumeSnapshot` and `PatchWarning`. No B05 row is linked to a
stream contract.

The pinned client has no PATCH method, so each descriptor takes the body model,
path parameters, extension preflight and field guards of its pinned PUT
counterpart (for example `failure_domain` on cluster members), and evidence is
unchanged Go RawQuery transport plus independent fixtures, as for B04. Every new
daemon handler returns HTTP 200 empty synchronous success; instance snapshot
PATCH alone returns an accepted operation (HTTP 202). The implementation stops if
a handler is found to differ.

User decisions (2026-10-23):

- Conditional-only on every row: a nonempty caller ETag (at most 1024 bytes) is
  required, and unconditional PATCH stays an approved exclusion as in B04. The
  daemon's forward, load balancer, peer, warning and storage bucket PATCH
  handlers do not check If-Match; the ETag is sent there but not enforced, and
  the docs say so.
- Certify network peer PATCH with native semantics: the daemon handles it as a
  full replace rather than a merge, so omitted fields are reset. The body is sent
  unchanged and the docs record the replace behavior.
- Custom volumes only for volume and volume snapshot PATCH. The daemon itself
  accepts only custom volumes on volume PATCH; other snapshot volume types are an
  approved exclusion.
- Approved exclusions: unconditional PATCH, non-custom volume snapshot types and
  cluster forwarding beyond host project/target routing. Approved difference: no
  named pinned Go PATCH method; requests are compared through Go RawQuery.

The `conditional_patch` record kind keeps its shared cases. `empty_sync` is
derived for methods with an empty synchronous result. `restore_rejection` is
derived for `InstancePut` bodies. The acceptance and native `/wait` cases are
derived for operation results. The B04 record is unchanged.

A new data-driven PATCH contract test runs every B05 method over Unix and mutual
HTTPS with schema-driven `ModelSamples` bodies. It compares with Go RawQuery for
empty, single-field, every-field, explicit null/false/empty and unknown-field
bodies, and for If-Match, routing and native 400/403/404/412. Independent fixtures
cover lost and malformed replies (uncertain after one PATCH, never replayed),
deadline and cancellation peer cleanup, and preflight (no or oversized ETag,
invalid body, empty path argument, unready host, missing extension, guarded
field) before I/O. Snapshot PATCH also proves acceptance and `/wait`.

PR 1 — 11 rows: the four existing descriptors plus server, certificate, cluster
group and member, image alias, instance metadata and warning PATCH. The selected
manifest grows 128 -> 135 pairs (133 complete), and confirmed typed gaps fall
31 -> 24.

PR 2 — 13 rows: nine network PATCH rows (networks, ACLs, address sets,
integrations, zones and records, forwards, load balancers and peers) and four
storage rows (pools, buckets, custom volumes and their snapshots). The manifest
grows 135 -> 148 pairs (146 complete), and confirmed typed gaps fall 24 -> 11.

Each PR updates the ledgers, closure ledger, backlog, client docs and generated
coverage. Task 3.9, `complete_port` and every Go declaration status are
unchanged.

#### Approved slice: B10 administrative completion (2026-10-22)

Complete all 40 B10 rows (server, root discovery, certificates, cluster, cluster
groups and members, projects, profiles, resources, metadata and warnings) under
reviewed completion records. They map 48 catalogue methods: 20 reads, 23
synchronous writes and 5 asynchronous writes (`CreateCertificateToken`,
`CreateClusterMember`, `UpdateClusterMemberState`, `RenameProject`,
`UpdateCluster`). No B10 row is linked to a stream contract.

User decisions (2026-10-22):

- Add a typed root-discovery helper for `GET /`, which the pinned client does
  not implement (`connect/2` reads `GET /1.0`). It returns the server's
  supported API version paths, with bounded result validation. Evidence is
  unchanged Go RawQuery transport plus independent fixtures on both transports;
  there is no named Go method to compare.
- Certify `POST /1.0/certificates?public`, the trust-token bootstrap, as a
  supported view: the same `CreateCertificate` request with a `trust_token`
  body, sent by a client whose certificate the server does not yet trust.
- Approved exclusions: `filter` on the names-only certificate and cluster member
  views (filtering stays certified on the recursion `WithFilter` methods), and
  cluster forwarding beyond host project/target routing.

PR 1 — 14 read rows plus root discovery under `read_contract` records, through
the inspection contract test and schema-driven samples. `GetServerResources`,
`GetMetadataConfiguration`, cluster, certificate, project access/state and
warning models use the shared `ModelSamples` generator.

PR 2 — 25 write rows under `sync_mutation` records, through the sync-mutation
contract test. The validator derives the asynchronous cases (accepted identity,
native `/wait` running/completed/failed/cancelled and local lifetime) from any
listed method whose result is an operation, so the mixed `POST /1.0/certificates`
row (sync `CreateCertificate`, async `CreateCertificateToken`) proves both. The
harness gains an asynchronous path reusing the B01 `/wait` composition. Guarded
fields (`token`, cluster join fields, `failure_domain`) are rejected before
dispatch without their extensions, compared with the pinned client. The four
rows whose every method returns an operation (`PUT /1.0/cluster`, cluster member
create and state, project rename) use the existing `async_mutation` record kind,
since they have no synchronous success to record.

Each PR updates the ledgers, closure ledger, backlog, client docs and generated
coverage, and stops if new transport infrastructure is needed. Task 3.9,
`complete_port` and every Go declaration status are unchanged.

#### Approved slice: B09 network completion (2026-10-21)

Complete 51 of the 53 B09 rows (networks, ACLs, address sets, allocations,
integrations, zones, zone records, forwards, leases, load balancers and peers)
under reviewed completion records. They map 63 catalogue methods: 32 reads and
31 synchronous writes. `GET /1.0/metrics` and `GET /1.0/network-acls/{name}/log`
are helper rows linked to S07 (auxiliary byte streams) and stay partial until
S07 is certified with B11.

User-approved exclusions (2026-10-21):

- Selectors the pinned client does not send (19 obligations): `filter` and
  `all-projects` on names-only views, and `filter` on the recursion=1 views of
  ACLs, address sets, integrations, zones, zone records, forwards, load
  balancers and peers, for which the pinned client has no filtered method. The
  client offers what the pinned client offers.
- Cluster forwarding beyond host project/target routing.

PR 1 — 20 read rows under `read_contract` records. Extend the data-driven
inspection contract test to the 32 B09 read methods (names, lists, all-projects
variants and gets, including network state, leases, allocations and
load-balancer state). Replace hand-written per-model samples for new models with
a schema-driven sample generator over `priv/incus/models.json`: each field gets
a typed, non-zero value, nested structs and maps recurse, and the comparison with
the pinned DTO stays field by field at every depth. Keep the existing hand-written
samples, so B02 evidence is unchanged; the generator is reusable for B08, B10
and B11.

PR 2 — 31 write rows under a new `sync_mutation` record kind. Required cases:
named-Go request, native synchronous success, routing and binding, native
400/403/404/409/412, malformed reply and response loss reported as uncertain
without replay, and preflight; the catalogue adds `body_fields`,
`extension_guards` and `etag` (PUT) where a method declares them. Build a
data-driven, both-transport mutation harness reusing the existing fixtures and
mutation driver, with schema-generated request bodies compared with the named Go
method.

Each PR updates the ledgers, closure ledger, backlog, client docs and generated
coverage, and stops if new transport infrastructure is needed. Task 3.9,
`complete_port` and every Go declaration status are unchanged.

#### Approved slice: B02 inspection completion (2026-10-20)

Complete all 20 B02 rows under reviewed completion records. They map 59 catalogue
methods plus `connect/2` discovery; 19 methods and discovery already have
`initial_inspection_v1` / `core_inspection_v1` evidence on Unix and verified
mutual HTTPS. Certify the remaining 40 methods by extending the data-driven
inspection contract test, and keep the existing scopes.

User-approved exclusions (2026-10-20):

- Names-only views (no recursion) document `filter` and `all-projects`, but the
  pinned client has no names method that sends them (14 obligations across the
  image, instance, network, operation, profile, project, storage pool and volume
  lists). Filtering and all-projects are certified on the recursion=1/2 methods;
  names-only views do not offer them, matching the pinned client.
- The `?public` documentation views (`GET /1.0`, the image list, the recursive
  image list and a single image). The client always uses a verified-identity
  connection; `GetPrivateImage` with a secret stays certified over it.
- Cluster forwarding beyond host project/target routing.

Record kind `read_contract`. Required cases: named-Go request and result,
populated, empty, corrupt result rejection, native 403 and 404, routing and
binding, response bound, readiness, deadline and cancellation with peer cleanup.
The catalogue-derived rules add `extension_guards` for every method that
declares an extension (rejected before dispatch), and `selectors` where a
supported view has `filter`, `all-projects` or `instance-type`. Discovery
(`GET /1.0`) uses its existing RawQuery-transport and required-field/version
evidence, and keeps no named Go `GetServer` DTO parity claim.

Evidence to add, parameterized over both transports:

- Result kinds not yet covered: names lists, project-grouped names
  (`GetInstanceNamesAllProjects`) and project URLs
  (`GetStoragePoolVolumeNamesAllProjects`), compared with the pinned client.
- Arguments: `filters` encoding for every `WithFilter` method, `instance-type`
  for instance lists, and the image `secret` for `GetPrivateImage`.
- Full models (`InstanceFull`, `StorageVolumeFull`) with populated and empty
  samples, and the recursion=2 instance and volume variants.
- Every declared extension (`api_filtering`, `instance_all_projects`,
  `container_full`, `instance_get_full`, `images_all_projects`,
  `networks_all_projects`, `profiles_all_projects`,
  `operations_get_query_all_projects`, `storage_volume_full`,
  `storage_volumes_all_projects`) rejected before dispatch.

Delivery: PR 1 completes instances, instance, snapshots, snapshot, state,
images, image, operations, operation and discovery (10 rows). PR 2 completes
projects, project, profiles, profile, networks, network, storage pools, pool,
volumes and volume (10 rows). Each PR updates the ledgers, closure ledger,
backlog, client docs and generated coverage, reuses the existing fixtures and
inspection driver, and stops if new transport infrastructure is needed. Task
3.9, `complete_port` and every Go declaration status are unchanged.

#### Approved slice: B01 mutation and B04 instance PATCH completion (2026-10-19)

Complete eight single-method rows under reviewed completion records, reusing
the `initial_mutation_lifecycle_v1` and conditional instance PATCH evidence that
already runs on Unix and verified mutual HTTPS:

- `PUT /1.0/instances/{name}` (`UpdateInstance`, configuration update and restore)
- `PUT /1.0/instances/{name}/state` (`UpdateInstanceState`)
- `DELETE /1.0/instances/{name}` (`DeleteInstance`)
- `POST /1.0/instances/{name}/snapshots` (`CreateInstanceSnapshot`)
- `DELETE /1.0/instances/{name}/snapshots/{snapshot}` (`DeleteInstanceSnapshot`)
- `DELETE /1.0/images/{fingerprint}` (`DeleteImage`)
- `DELETE /1.0/operations/{id}` (`DeleteOperation`)
- `PATCH /1.0/instances/{name}` (`PatchInstance`, B04)

`POST /1.0/instances` stays partial: it is linked to S06 (archives) and S10
(copy/migration), which remain open. Task 3.9, `complete_port` and every Go
declaration status are unchanged.

User-approved exclusions (2026-10-19): cluster forwarding beyond host target
routing for all eight rows, and unconditional PATCH. `PatchInstance` stays
conditional-only: a missing or empty caller ETag is rejected before I/O, as
today. Real-daemon effects remain separately recorded acceptance.

Record kinds. Add three kinds to the validator, each with an exact required-case
list and negative tests:

- `async_mutation` (six rows): named-Go request and accepted identity, direct
  native `/wait` running/completed/failed/cancelled snapshots, applicable
  ETag preconditions, native 403/404/409/412, malformed and lost replies with no
  replay, host binding, extension guards, preflight and local lifetime after
  acceptance.
- `sync_cancellation` (`DeleteOperation`): the existing authoritative may_cancel
  inspection, one synchronous DELETE, completion race, native rejection and
  lost-reply identity.
- `conditional_patch` (`PatchInstance`): RawQuery transport comparison (the
  pinned client has no named PATCH method), field presence without local merge,
  native empty synchronous success, 400/403/404/412 and restore-mode rejection,
  uncertain dispatched loss without replay, lifetime cleanup and conditional
  preflight. Evidence kinds stay distinct from named-Go and daemon evidence.

Evidence to add, parameterized over both transports:

- Request bodies with every field: a fully populated `InstancePut` (architecture,
  config, devices, ephemeral, profiles, stateful, description) and a stateful
  restore; every `InstanceStatePut` action (start, stop, restart, freeze,
  unfreeze) with timeout, force and stateful; `InstanceSnapshotsPost` with
  name, stateful and `expires_at`. Compare each with the named Go method.
- Extension guards before dispatch: `disk_only` restore requires
  `instance_snapshot_disk_only_restore` and `expires_at` requires
  `snapshot_expiry_creation`; with the extension present the field is sent.
- A cancelled (401) `/wait` snapshot for the six asynchronous rows.

Each record names its supported view, the excluded scope, the bodies or actions
it covers and the evidence kind of every case. Update the closure ledger,
backlog, client docs and generated coverage. Reuse the existing fixtures and
mutation/PATCH drivers; target well under a thousand handwritten lines and stop
if new transport infrastructure would be needed.

#### Approved slice: B03 completion records, native wait, events and exec (2026-10-19)

This is the first slice that promotes rows. It closes three B03 endpoint rows,
`GET /1.0/operations/{id}/wait`, `GET /1.0/events` and
`POST /1.0/instances/{name}/exec`, and certifies stream contracts S01 (live exec)
and S03 (events and callbacks). `GET /1.0/operations/{id}/websocket` stays
partial, because S02 (console) and S10 (copy/migration) also use it and remain
open; its exec-channel evidence improves through S01. Task 3.9, global
`behavior_complete`, `complete_port` and every Go declaration status (1239
partial / 41 missing) are unchanged.

User-approved exclusions (2026-10-19), recorded on each affected record with
this date: the `?public` documentation views for wait and websocket, because
the client always uses a verified-identity connection; arbitrary and empty
operation-wait secrets; and cluster forwarding for wait, events and exec. Host
`project`/`target` routing stays compared on the wire; the exclusion only means
no claim that the daemon forwards to another member. The finite `/wait` timeout
bound (0..3600, `-1` rejected before I/O) from the 2026-10-15 native-wait slice
is retained as an approved difference. Real-daemon and Macus acceptance remain
separately recorded and are not part of these records.

Reviewed completion records. `priv/incus/endpoint-inventory.json` gains a
`completion_records` map. Each record names its approval date, rows, stream
contracts, methods/helpers, supported views, excluded views with approval,
per-query selector treatment, bodies/modes, result fields, locally rejected
variants, excluded scope and approved differences, required cases, the
transports `unix` and `mutual_https`, and evidence keys with their kind
(named-Go differential, RawQuery transport or independent fixture). A completed
row sets `behavior_complete: true` and names its record; the selected manifest
row uses `status: "complete"` with the same record and keeps nonempty `gaps`
listing exclusions and separately owned acceptance. A certified stream contract
uses `status: "certified"` and names its record. The events row joins the
selected manifest, which grows from 36 to 37 pairs.

The validators accept completion only when a record lists the row and the row
is not `missing_typed`; every documented view is supported or approved-excluded;
every query parameter of a supported view has a selector treatment; every linked
stream contract is certified; both transports and the certification-rule cases
for the row's kind are present, with each case linked to an existing anchored
evidence key. Negative tests reject a removed case, transport or evidence key;
an unlisted view; an exclusion without approval; a completed row with an open
linked stream contract (the websocket row); a record claiming an unrelated or
missing-typed row; completion or certification without a record; and changed
global completion, `complete_port` or declaration counts. A record is reviewed
through the human pull-request review; agents never mark it reviewed themselves.

PR 1 — record mechanism, native wait and events with S03.

- Wait: `GetOperationWaitSecret` rejects an empty or non-lowercase-hex secret,
  or one over 1024 bytes, before I/O. This replaces the current silent drop of
  an empty secret, which turned the call into a plain wait. Daemon secrets come
  from `RandomHexString`. Add named-Go evidence for 404 absence and a cancelled
  (401) terminal snapshot, timeout 3600 accepted and 3601/non-integer rejected
  before I/O, and an independent fixture for connection loss before headers:
  one GET, no replay and no DELETE. Retain the 20 differential and 12 stalled-
  body cases.
- Events: extend the pinned `eventhandlers` driver to compare GetEvents,
  GetEventsByType, GetEventsAllProjects and GetEventsAllProjectsByType
  upgrade targets: comma `type` lists, `all-projects=true` suppressing
  `project`, and member `target`. Unknown types are forwarded, not locally
  filtered, and the native 400 is preserved. Add native 403 envelope, 400
  (unsupported type) and 404 (absent project) on upgrade. Because
  `all-projects` suppresses `project`, as in the pinned client, neither client
  can produce the server's project-conflict 400. Compare populated and minimal Event fields (type, timestamp,
  metadata, location, project). Cover inbound per-frame and total-stream
  bounds. Parameterize the listener and explicit-send matrix (handlers,
  filters, capacity, callback failure/timeout, owner and caller loss, EOF with
  queued tail, malformed events, overflow, deadline and context cancellation)
  over Unix and verified mutual HTTPS, asserting actual peer closure where the
  local side ends the stream. Native callback order stays unspecified.

PR 2 — exec with S01.

- Compare every InstanceExecPost field and mode with the named Go
  `ExecInstance` on both transports: collected noninteractive `run`,
  `wait-for-websocket=false` through `call`, interactive PTY through
  `Session.exec` (channel 0 plus control), `record-output=true` submission and
  nonzero width/height/user/group with nonempty cwd.
- Prove `container_exec_recording` and `container_exec_user_group_cwd`
  rejection before dispatch, and read back resize/signal control frames
  against Go's control messages, including range rejection. Add native
  400/403/404 through `Session.exec` and `run`.
- Assert each channel's upgrade target (secret plus project/target),
  `:stream_negotiation` upgrade rejection, `:invalid_stream_metadata` fds,
  empty output with exit 0, pending exit status, missing channels and Session
  Inspect redaction.
- Run the Unix-only preflight, blocked-stdin, owner-loss, lost-response,
  sink-limit, running/failed and close/barrier/abrupt cases on mutual HTTPS
  too.
- S01's boundary becomes: bounded noninteractive collection plus interactive
  host-owned channels, with no arbitrary producer or tool capture policy.
  Recorded-output listing, download and deletion stay in B07, unimplemented.

User decisions during PR 2 (2026-10-19). The pinned `GetOperationWebsocket`
sends only the operation secret; this client also sends the host
`project`/`target` on every channel upgrade, which the pinned daemon ignores
(it forwards by where the operation lives). This existing routing is
maintained and recorded as an approved difference on `b03_exec_v1`; S02/S10
behavior is unchanged. A request context ending while an upgrade is pending
could be reported as `:stream_negotiation`, depending on which local timer won.
Fix it narrowly: `WebSocket.open` reports the ended context's `:deadline` or
`:canceled`, and `Session.channels` propagates those kinds with the accepted
operation. Add both-transport regressions; transport budgets and timeouts are
unchanged.

Each PR updates the closure ledger, backlog and generated coverage evidence, and
reuses the existing fixtures and reference drivers. Target well under a thousand
handwritten lines per PR. Stop and report if new transport infrastructure,
production timeout changes or repair rounds would expand scope.

#### Approved slice: complete endpoint classification audit (2026-10-15)

Create a separate full classification ledger alongside the selected endpoint
evidence manifest. Account for all 247 documented verb/path pairs and all 293
documented operation views (46 additional variants), preserving their literal
source keys. Compare public v1.0 server registrations using Go's standard AST
parser, not a handwritten source parser. Retain documentation/server differences
and supplemental server-only pairs explicitly; do not patch the pinned source.
Public-access documentation views are not automatically literal query parameters.

For every pair record exact catalogue methods or explicit helper mappings,
subtype limitations, existing fixture evidence, missing typed implementation or
source discrepancies, and one named backlog batch with finite exit criteria.
Record each documented query/access view and its declared query parameters
separately, including unmapped selectors on otherwise implemented routes;
a route match never proves a query, body, error or streaming contract. Preserve
the selected 32-pair evidence manifest and its ten verified inspection scopes.
Validate exhaustive source coverage, duplicates, stale mappings, missing anchors,
backlog assignments and accidental completion claims in the canonical checks.

The backlog must distinguish missing implementation, evidence/contract work,
source reconciliation and scope decisions. No new exclusion is approved by this
audit: missing methods and unsupported variants remain closure blockers unless
implemented and verified or explicitly approved by the user. Existing approved
host-adapter, finite-lifetime, SFTP subset and caller-owned NBD boundaries remain.
List non-REST streaming/helper contracts separately with finite obligations;
installed adapters, real backend and Macus hardware remain separate acceptance.

Use finite per-contract evidence criteria: declared supported selectors/fields,
extension/routing/ETag behavior, native success and representative rejection,
mutation acceptance/uncertainty/no replay and applicable stream/lifetime cleanup.
Reuse existing evidence; do not demand every possible field/error cross-product.
Parameter classification must use only methods matching the current documented
view, so names-only views cannot borrow filter/all-projects support from another
recursion view. Copied verified_scope values must equal the matching selected
evidence entry, including absence on unrelated rows. Add focused mutation
regressions and correct the finite backlog counts without changing support.

Only inventory classification may become complete in this slice. Behavioral
completion, declaration parity, task 3.9 and tool export remain unchanged. Update
the closure checklist and recommend the next implementation batch without
implementing it. Keep new verifier logic bounded; large mechanical ledger data
is audit output, not authorization for runtime/parser expansion.

#### Approved slice: B02 remaining initial inspection contracts (2026-10-16)

Extend the existing inspection fixture for GetInstances, GetInstance,
GetInstanceState, GetInstanceSnapshots, GetInstanceSnapshot, GetImages, GetImage,
GetOperations and GetOperation, plus explicit server discovery through connect/2.
Use only current catalogue queries and a container sample for GetInstances;
other recursion/filter/all-projects/private-image/type variants remain gaps.
The initial B02 batch changes no runtime, descriptor, shared tool or parser.
The explicitly approved deadline-classification follow-up below is the sole runtime exception.

Compare the nine unchanged named Go read methods on Unix and mutual HTTPS for
populated/empty DTOs, known-field corruption, native 403/404, host project/member,
response binding and applicable ETags. Preserve operation grouping semantics
without inferring cross-group ordering. Derive expected fields from fixtures,
assert the complete decoded fixture first, and compare fixed known keys with Go;
unknown-field retention is an independent codec assertion, not Go DTO parity.

Discovery has no typed catalogue descriptor: compare its GET transport using
unchanged Go RawQuery with discovery disabled in the driver, then independently
exercise connect/2's raw metadata, required API version/extensions and rejection
of malformed or unsupported-version discovery. Minimal valid discovery retains
required fields; it is not an empty supported server. Do not invent an ETag field
on the connected client or claim named GetServer DTO parity from RawQuery.

Reuse bounded response-byte, readiness, deadline/cancellation and actual peer EOF
fixtures on both transports, with one local GET and no replay or backend mutation.
Record core_inspection_v1 on exactly nine methods and the one discovery helper;
retain the existing ten inspection and eight mutation scopes, 36 partial selected
endpoints, all declaration gaps and complete_port=false. Validate exact methods,
helper attachment, transports, cases and evidence; reject scope overclaims.
Update the closure ledger and coverage evidence without certifying broader
endpoint variants or real-backend acceptance. Keep additions data-driven within
a few hundred handwritten lines; stop before runtime/infrastructure expansion.

#### Approved B02 follow-up: receive-timeout classification (2026-10-16)

PR #15 first-attempt macOS CI returned :response instead of :deadline in a
stalled mutual-TLS read; Ubuntu and 120 local short-deadline probes passed.
The user approved expanding this PR for a narrow diagnosis/fix. Mint reports
passive socket receive expiry as TransportError(reason: :timeout), but the
client currently maps every receive error to :response. The competing outer
guard can therefore hide this classification depending on scheduling.

Reproduce the socket-timeout winner deterministically with existing Unix/mutual
HTTPS fixtures: temporarily suspend only the test-owned caller and its deadline
guard, allow the real receive timeout to finish the worker, then resume the caller.
Trace the real Mint timeout and receive-function result directly so the outer
timer cannot hide a wrong result. Assert strict read :deadline and actual peer EOF; keep generic
premature EOF as :response. Cover GET/HEAD and POST, whose possibly dispatched
failure must remain :uncertain with one request and no replay. Use process/message
synchronization rather than elapsed success assertions or relaxed error sets.

Map only Mint's explicit receive timeout to :deadline. Preserve all other receive
errors, deadlines, cancellation rules, cleanup and operation identity. Do not
normalize all failures or change transport budgets. Add bounded regression and
coverage/closure evidence; retain all declaration/endpoint statuses and task 3.9
open. A subsequent macOS run passed the receive regressions but the expanded
negative evidence matrix exceeded ExUnit's 60-second limit while repeatedly
parsing fixture source. Deduplicate source parsing per validation invocation,
retaining all row/anchor assertions and negative cases; never use a cross-call
cache that could hide source drift or increase the test timeout. This test-support
optimization is part of making the new evidence guards bounded. Stop again if
diagnosis requires broader transport or callback changes.

#### Approved test-only follow-up: YAML atom probes (2026-10-16)

Current-head CI run 38888955608 passed macOS canonical/reference and immutable
consumer checks. Ubuntu failed the unchanged atom-safety fixture when a single
200-key document returned invalid_native_config. The parser's two-second wall
budget makes load-related rejection plausible; the failure does not identify
which bound fired. The user approved test-only stabilization after the scope stop.

Retain all 200 distinct keys and all atom-safety, invalid-input, native-oracle and
yamerl-state assertions. Split only the atom probe into twenty ten-key documents;
require successful decoding of the complete expected string map for every batch
and verify none of the 200 keys are atoms before or after parsing. Do not accept
rejection, retry decoding or raise any timeout. This tests atom safety without
assuming one large document always finishes inside a wall-clock resource budget.

After atom batching, run 38895931250 passed Ubuntu fully and every atom probe,
but macOS rejected a near-limit success fixture in this same async YAML module.
Run this resource-sensitive test module serially to remove competing async fixture
work while retaining its large-document success, elapsed, native differential,
worker/message cleanup and all atom assertions. Keep ownership-based worker
tracing rather than a VM-wide process count. This changes test scheduling only.

Keep NativeYaml, NativeConfig, the pinned oracle, reduction/heap/deadline limits
and accepted subset unchanged. Update validation/closure evidence, regenerate
coverage without status promotion, run canonical/reference checks and verify
both platforms and immutable consumers on the pushed revision. Stop before any
parser or production-budget change or further unrelated repair scope.

#### Approved slice: B01 mutation lifecycle evidence (2026-10-16)

Verify the eight existing B01 endpoint/method pairs: CreateInstance,
UpdateInstance (configuration update and snapshot restore as distinct bodies),
UpdateInstanceState, DeleteInstance, CreateInstanceSnapshot,
DeleteInstanceSnapshot, DeleteImage and DeleteOperation. No new tool descriptors,
MCP binding, migration/copy behavior or general mutation orchestration is planned.
Use bounded fixture bodies with populated writable maps and explicit ETags for
instance update/restore and state preconditions where supported by the pin.

Compose the seven asynchronous mutation pairs with Operation.from_response and
the existing typed GetOperationWait native `/wait` endpoint. Verify native accepted
identity and host project/member/connection binding, then running, completed and
failed snapshots, retaining native status/error/metadata and wait ETags. A native
finite wait returning running is not completion; local timeout/cancellation is
not remote cancellation. Reuse existing wait cleanup/lifetime evidence and add
bounded composition evidence without changing polling or callback ordering.

Compare named unchanged Go methods and independent fixtures on Unix and mutual
HTTPS for supported bodies/preconditions, native 403/404/409/412 rejections, lost
or malformed mutation responses and no replay or invented operation identity.
Cancellation is distinct: Operation.cancel performs authoritative inspection,
rejects may_cancel=false without DELETE, sends at most one synchronous native
DELETE when permitted, preserves completion races/native rejection and known
identity on response loss. A successful DELETE acknowledges the request, not a
new asynchronous operation or proven cancellation completion.

Record a finite `initial_mutation_lifecycle_v1` fixture scope on exactly these
eight selected rows. Validate exact methods, transports, cases and source anchors,
and reject missing/misplaced scope claims. Whole endpoints, B01's broader body/
cluster/error variants, task 3.9 and every declaration remain partial; no backend
acceptance or tool export follows. Update the closure checklist and generated
coverage evidence. Reuse existing fixture/oracle support, target a few hundred
handwritten lines, and stop if new infrastructure or repair rounds expand scope.

#### Approved slice: four conditional resource PATCH methods (2026-10-15)

Implement PatchProject, PatchProfile, PatchImage and PatchInstanceSnapshot through
the existing typed catalogue and ProjectPut/ProfilePut/ImagePut/InstanceSnapshotPut
models. Require a nonempty caller ETag bounded to 1024 bytes, unique allowed
options and nonempty bounded resource path arguments. Preserve omitted, null,
false and empty values where valid for the model, with no local GET/merge,
defaults or mutation replay. Retain host project/member selection, native ETags,
errors and response identity. Keep existing PatchInstance behavior unchanged.

Pinned projectPatch/profilePatch/imagePatch return HTTP 200 empty sync success.
Pinned snapshotPatch delegates to snapshotPut and returns HTTP 202 asynchronous
operation acceptance, even when no expires_at change was supplied. Require that
native status and preserve the real accepted handle; do not report acceptance as
completion or manufacture an operation for synchronous methods. Snapshot expiry
and projects use their existing extension preflights. Image PATCH's evidenced
fields are auto_update, public and properties; no effect on other ImagePut fields
is inferred. Native Incus owns merge and expiry semantics.

Reuse and parameterize the bounded instance PATCH fixtures across the five methods
and Unix/mutual HTTPS. Compare unchanged Go RawQuery requests/results (not a named
Go PATCH method) and independent native-shaped fixtures for field presence,
400/403/404/412, accepted snapshot identity, unexpected/malformed/disconnected
responses, request/ETag/path/body/extension/readiness preflight, deadline and
cancellation peer cleanup with one PATCH and no replay. Preserve the existing
instance restore rejection fixture. These fixtures do not establish daemon merge
or installed-backend acceptance. No oracle changes or live backend are planned.

Add four REST descriptors and four partial selected evidence rows (32 -> 36).
Reclassify those full-inventory rows from missing_typed to catalogue while keeping
behavior_complete=false and bounded scope/gaps explicit. Confirmed missing typed
pairs decrease 36 -> 32, with 20 other missing PATCH pairs and 28 existing-route
selector gaps still open. Retain B05 membership for the four partial contracts;
adding typed methods is not endpoint completion. Update coverage evidence without
inventing Go declarations or promoting their status; complete_port stays false.
Keep this data-driven batch within a few hundred handwritten lines. Stop before
parser/runtime expansion or repeated corner-case repair rounds require re-scoping.

#### Approved slice: priority endpoint/method evidence (2026-10-14)

Add a development-only, checked manifest for 21 priority verb/path pairs:
server inspection (1), instances/state (7), snapshots (4), images (3),
operations including wait/WebSocket (5), and exec submission (1). Verify each
pair and source hash against the unchanged pinned REST specification using its
existing YAML parser dependency. Normalize path parameter names for catalogue
comparison and retain query variants separately. This is a selected inventory,
not a complete REST inventory or an automatic tool-export decision.

Link public client calls and specific existing differential/fixture tests;
record queries, extensions, ETags, errors, acceptance/completion and streaming
scope plus remaining gaps. Validate duplicate pairs, stale provenance, missing
method/evidence links and unsupported-as-verified claims. The native operation
wait endpoint already has typed GetOperationWait/GetOperationWaitSecret request
and result evidence. Operation.wait uses GET polling, whose evidence belongs
to operation GET; server-side long-poll/deadline/secret matrices remain partial.
Keep all declaration mappings partial/missing,
complete_port=false and task 3.9 open. Update the closure/validation ledger and
coverage manifest pointer without adding runtime behavior or MCP definitions.
Keep the slice within a few hundred lines and stop for renewed scope selection
if it grows, needs a handwritten parser or produces repeated corner-case fixes.

#### Approved slice: native operation-wait evidence (2026-10-15)

Exercise GetOperationWait and GetOperationWaitSecret through the existing typed
call API, separately from polling Operation.wait. Reuse the unchanged pinned Go
reflection driver and disposable Unix/verified mutual-HTTPS fixtures. The pinned
server flushes HTTP 200 headers before waiting, so gate the response body after
headers and require explicit fixture release before a successful result. Compare
finite timeout queries, scoped routing, operation identity, ETags, running
snapshots at server timeout, terminal success/failure snapshots and native HTTP
errors. A failed operation in a successful wait response remains typed data.

Independently hold the response body open and verify finite local deadline,
explicit context cancellation and caller loss close the peer socket with one
wait GET and no replay or remote DELETE. Verify premature EOF and pre-dispatch
rejection of native timeout=-1 without changing the finite 0..3600 bound. Use
acknowledged fixture gates and socket closure, never tight elapsed-time success
assertions. Check secret redaction on the explicit hex-secret variant. Arbitrary
secret encoding/empty-secret variants, cluster forwarding, full timeout/error
matrices and real-daemon acceptance remain gaps. Keep both the selected endpoint
and declaration mappings partial; no runtime or polling-strategy changes are
planned. Stop if this evidence slice exceeds a few hundred lines or requires
new parser/runtime machinery.

#### Multi-item slice: initial-tool inspection contracts (2026-10-15)

Verify list/get projects, profiles, networks, storage pools and volumes as one
coherent ten-pair batch. Reuse existing typed methods and unchanged Go driver;
no runtime rewrite or operation/tool implementation is planned. Compare populated
and empty results, known-field corruption, 403/404, host project/member and ETag
on Unix and verified mutual HTTPS. Independently verify response-byte bounds,
unavailable extensions, finite deadline, cancellation and peer cleanup without
replay. Native typed DTO projections and lossless unknown fields are distinct.

Expand the selected manifest 22 -> 32 partial pairs. Add an explicitly scoped
fixture_verified inspection contract: ten named methods, catalogued queries,
custom volume sample, both transports, required cases and evidence anchors.
The validator must reject removed methods/cases/anchors, wrong scope attachment
or any whole-endpoint/declaration completion claim. This is fixture evidence,
not an exhaustive query/field/error matrix, real backend acceptance or automatic
tool export. Keep filters/all-projects/other volume-type variants and all Go
declaration gaps visible. Update the current checklist to count ten verified
scoped contracts separately from 32 partial endpoints. Keep the batch data-driven
within a few hundred new lines; stop if it requires a parser, runtime expansion
or repeated corner-case/DoS repair rounds.

#### Approved slice: conditional instance PATCH (2026-10-15)

Add PatchInstance to the typed call catalogue for PATCH /1.0/instances/{name}.
Require an explicit nonempty ETag for this conditional subset; other input,
request-byte and response bounds remain the existing library bounds. Pass a
validated InstancePut map without defaults or a local read/merge; omission,
false, empty collections and null values remain distinct on the wire. Native
Incus owns merge and restore rejection semantics. Preserve host project/member,
If-Match, returned ETag, native HTTP/error codes and connection/identity binding.
Accept only the native empty synchronous success shape; a dispatched response
loss, malformed/unexpected success or interrupted lifetime remains uncertain,
with any received native identity preserved and no replay or invented operation.

There is no named Go PatchInstance declaration. Reuse unchanged RawQuery through
the existing reflection driver over Unix and verified mutual HTTPS, plus
endpoint-specific fixtures for 200 sync, 400/403/404/412, restore rejection,
preflight bounds/readiness, local deadline/cancellation and ambiguous response
loss. RawQuery comparison proves request/transport projection, not daemon merges.
Add one partial endpoint row (22 selected), retain the 1280-declaration ledger
and complete_port=false, and link evidence without inventing a Go declaration.
The prior audit is documentation carried forward separately. Keep this new
runtime/test slice within a few hundred lines; stop if a parser, other PATCH
routes or repeated corner-case repairs become necessary. Do not implement tools.

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

#### Verified slice: bounded full-duplex noninteractive exec

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

#### macOS cleanup evidence repair (2026-10-14)

Separate runtime cleanup budgets from scheduling of test observers and fixture
peers. Reproduce the existing 500 ms elapsed/peer-report false failures with
controlled observation delay after resources terminate or the socket closes.
Replace those performance assertions with bounded monitor/real-EOF evidence
and failure diagnostics. Use a shared 5-second observation allowance while
stalled client/peer lifetimes remain 30 seconds, so natural I/O expiry cannot
substitute for owner cleanup. A delayed observer is not a cleanup SLA.

Independently verify the existing 100 ms shared WebSocket close budget through
call traces: all close requests precede waits, the first wait consumes the
remaining shared allowance and subsequent blocked waits get zero rather than
fresh allowances. Retain blocked-write/negotiation preconditions, pending-writer
failures, native identity and no DELETE/replay assertions. Library budgets,
native oracle and declaration/endpoint classifications remain unchanged. Keep
the repair within a few hundred lines and validate both CI platforms without
retrying failures into a parity claim.

The first repair CI run also exposed the raw-channel blocked-write fixture's
500 ms observation assertion. Apply the same bounded observation separation
to raw-channel owner cleanup and stream expiry. Trace actual socket send-timeout
options to verify they are capped by the configured test stream lifetime rather
than the longer request budget; retain stalled peers and explicit deadline errors.

#### WebSocket write-lifetime evidence repair (2026-10-14)

Replace the remaining Unix/TLS blocked-write fixture's 700 ms elapsed assertion
with bounded resource observation and direct evidence of the unchanged socket
write budget. Trace clock return values and socket options on the explicit local
channel process: every send timeout must equal the lesser of the request budget
and the stream deadline's remainder at the actual budget calculation, with
send-timeout-close enabled. No test-observer elapsed threshold is a runtime SLA.

Use a 3-second fixture stream lifetime against 30-second request and stalled-peer
budgets. Require a deadline error (including its notification when the local
handle is already closed), normal channel termination and one native GET. Keep
a permanent 750 ms delayed observer and a finite five-second monitor allowance.
Prove enlarged send-timeout mutations fail the direct checks, restore runtime
source after probes, and retain the unchanged native oracle and partial coverage.
Keep this repair test-only and within a few hundred lines.

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
