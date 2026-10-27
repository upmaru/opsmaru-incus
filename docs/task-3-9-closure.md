# Task 3.9 closure ledger

Task 3.9 is open. This ledger records remaining behavior, not an exception that
closes the task. The unchanged reference is Incus v7.0.1 revision
`13f3992766142d5087fff2e362cd2e1a75294fe8`. Real Incus acceptance is task 4.3;
installed Macus gateway/runtime/hardware acceptance remains consumer-owned.

The finite behavioral backlog is in [task-3-9-backlog.md](task-3-9-backlog.md),
backed by the exhaustive [endpoint classification](../priv/incus/endpoint-inventory.json).
Go declarations remain separately tracked in `priv/incus/coverage.json`; their
status is not a measure of endpoint completion and is unchanged by this audit.

On 2026-10-13 the user approved task 3.9 completion against a verified Incus
REST endpoint/method inventory, native streaming/upgrade contracts and the public
client behavior required by `add-incus-operations`. Literal Go declaration parity
is a separate claim: keep this declaration ledger and `complete_port=false`
truthful even when the task's behavioral gate is eventually satisfied. The 273
JSON method descriptors map to 193 distinct catalogue routes. The full classified
REST inventory now includes all 247 documented pairs and one supplemental server
POST repair row; mapping a route does not certify its supported contract.

## Current behavioral checklist — audited 2026-10-15

This checklist started at `47b1918` (PR #9) and now includes the approved
conditional instance PATCH, ten-method inspection, full classification, four conditional resource PATCH, B01 lifecycle and B03 completion-record slices. Sections below it are chronological evidence and may describe gaps since superseded.
A checked item means the stated bounded behavior has evidence, not that its
entire endpoint, protocol or Go declaration is complete. The audit changed no support status. The new four-method batch adds bounded typed implementations; endpoint/declaration parity and tool exports remain separate.

### Progress that the declaration counters cannot show

- [x] Completion gate selected: documented REST verb/path inventory, native
  streams/upgrades and client behavior needed by `add-incus-operations`.
- [x] 268 named-Go JSON methods retain their native fixture baseline; five REST-specific
  PATCH descriptors add dedicated evidence (`test/instance_patch_test.exs`).
  The 273 descriptors map to 193 routes; these are not completed endpoints.
- [x] 37 selected pairs have checked REST provenance, method/evidence anchors,
  supported scope and gaps (`priv/incus/endpoint-evidence.json`).
- [x] Reviewed completion records (`completion_records` in
  `priv/incus/endpoint-inventory.json`) complete two endpoint rows and certify
  S03: `b03_native_wait_v1` (`GET /1.0/operations/{id}/wait`) and
  `b03_events_v1` (`GET /1.0/events` with S03). The validator rejects removed
  cases/transports/evidence, unlisted views, unapproved exclusions and
  completion for unrelated, missing-typed or open-stream rows.
- [x] Bounded live noninteractive exec has full-duplex finite stdin, acknowledged
  stdout/stderr, native barriers, exit status, one submission-to-completion
  lifetime, retained acceptance and blocked-stdin cleanup evidence
  (`test/exec_output_test.exs`).
- [x] Both direct native wait methods have gated-body snapshots/errors/EOF
  comparisons on Unix/mutual HTTPS and local deadline/cancellation/caller-loss
  cleanup (`test/native_wait_reference_test.exs`, added by PR #9).
- [x] Polling, supported cancellation, event handlers and remote-operation waits
  have separate identity/lifetime evidence (`test/operation_test.exs`,
  `test/operation_handler_test.exs`, `test/request_context_test.exs`,
  `test/copy_negotiation_reference_test.exs`).
- [x] Copy negotiation covers the recorded boolean/locality/project/member
  combinations and relay failure cleanup; it is no longer wholly unevidenced
  (`test/copy_negotiation_reference_test.exs`, `test/migration_test.exs`).
- [x] File/image/archive handoff, raw upgrades, bounded SFTP subset, events,
  dynamic console, OCI and SimpleStreams have the scoped evidence below.
- [x] PR #9 passed canonical/reference checks and immutable consumers on both
  ubuntu-24.04 and macos-15, first attempt: CI run 38691372898.

These are completed behavior slices. The conditional PATCH behavior is fixture-verified; its broader endpoint scope
remains partial. The checked manifest now has 103 pairs (6 partial, 97 complete) and 28 fixture-verified scoped
contracts (nineteen inspection methods, one discovery helper and eight mutation lifecycle methods). The separate Go
ledger still has 1239 partial / 41 missing declarations, `complete_port=false`.
No percentage of task completion can be derived from either counter.

### Inventory denominator and classification work

Read-only extraction of the unchanged pinned `doc/rest-api.yaml` through
`test/reference/endpoints/main.go` gives **293 documented operations**, including
**46 additional query/access views**, or **247 distinct verb/path pairs**.
Normalize parameter names and separate the query string before counting pairs;
retain query/access views as separate behavior obligations. REST SHA-256 is
`7b4e07375da92f30e7eadf766f1bbdf40bf9968ee305a16be1afe5998e72e91f`.
This is the pinned document's inventory, not a claim that every server route is
fully documented or that matching a route establishes behavior parity.

| Documented family | Verb/path pairs | Exact normalized JSON-catalogue matches | Selected evidence pairs |
| --- | ---: | ---: | ---: |
| Root (`/`, `/1.0`) | 4 | 1 | 1 |
| Instances, state, snapshots, files and upgrades | 50 | 35 | 14 |
| Images and aliases | 17 | 15 | 4 |
| Operations and operation WebSocket | 5 | 4 | 5 |
| Projects | 9 | 9 | 3 |
| Profiles | 7 | 7 | 3 |
| Networks | 28 | 24 | 2 |
| Storage pools, volumes, buckets and streams | 58 | 35 | 4 |
| Certificates | 6 | 5 | 0 |
| Cluster | 19 | 17 | 0 |
| Network ACLs | 8 | 6 | 0 |
| Network address sets | 7 | 6 | 0 |
| Network integrations | 7 | 6 | 0 |
| Network zones | 12 | 10 | 0 |
| Network allocations | 1 | 1 | 0 |
| Metadata | 1 | 1 | 0 |
| Resources | 1 | 1 | 0 |
| Events | 1 | 0 | 1 |
| Metrics | 1 | 0 | 0 |
| Warnings | 5 | 4 | 0 |
| **Total** | **247** | **187** | **37** |

Six of the 193 catalogue routes use literal `volumes/custom` where REST uses a
volume-type parameter. They require subtype-aware mapping; they are not six
missing implementations. Some routes absent from the JSON catalogue are handled
by explicit helpers, including discovery, events, operation WebSocket, binary
transfers and raw SFTP/NBD. Consequently the **60 pairs without an exact JSON
catalogue match are not 60 missing implementations**: the completed classification
resolves them as five custom-only catalogue mappings, 22 explicit helpers, 31
missing typed implementations, one equivalent POST route and one repair mismatch.

- [x] Classify all 247 documented pairs and retain all 293 query/access views,
  accounting for 46 additional variants. The full ledger separately records
  catalogue/helper/custom mappings, 31 documented missing typed implementations,
  the actual server POST repair gap, source differences and finite B01–B12 exits.
- [x] Reconcile all public v1.0 registrations, including image suffix actions;
  retain root discovery and incorrect documented GET repair explicitly. Public
  access views are not automatically wire query flags.
- [x] Add and fixture-verify the ten initial-tool inspection contracts: list/get
  projects, profiles, networks, storage pools and custom-volume samples. The
  `initial_inspection_v1` profile records exact methods, catalogue-only queries,
  both transports, required cases and evidence. No methods were reimplemented.
- [x] Implement and fixture-verify conditional instance PATCH: field presence,
  explicit ETag and sync result, native rejection, uncertainty and local cleanup.
- [x] Implement and fixture-verify four conditional resource PATCH methods:
  project/profile/image return empty sync, snapshot returns a native accepted
  operation. Missing typed pairs decrease 36 -> 32; other missing PATCH pairs
  decrease 24 -> 20. The four whole endpoints remain partial under B05.
- [x] Classify the B05 **24 resource PATCH pairs** (four conditional implementations,
  20 still without typed methods), file HEAD (B06), recorded
  exec output (B07), five storage methods (B08), root discovery (B10) and actual
  POST repair (B12). These require implementation/evidence or explicit approval;
  the audit approves no exclusions. Conditional instance PATCH remains B04.
- [x] Classify every query parameter declared inside the REST operations. Track
  **28 distinct endpoint/selector gaps across 20 existing routes** separately,
  using only each view's matched methods. The previous nine-gap count hid 19
  obligations by borrowing other recursion views. Exact view assignments are in
  the finite backlog; two HEAD path selectors overlap B06.
- [x] Guard copied verified_scope values against selected evidence entries;
  removed, altered or unrelated fixture-scope claims fail validation.
- [x] Verify eight bounded B01 lifecycle contracts on Unix/mutual HTTPS:
  named-Go request/acceptance, direct native wait running/success/failure, separate
  update/restore bodies, applicable PUT ETags, native rejection and response-loss
  uncertainty without replay. Cancellation stays synchronous, with permission,
  completion-race and lost-reply evidence. Broader endpoint scope remains open.
- [x] Define finite certification criteria and assign all endpoint/stream
  obligations in [task-3-9-backlog.md](task-3-9-backlog.md).
- [ ] Complete required B01–B12 contracts and S01–S12 streaming obligations;
  classification is complete, behavioral certification remains open. Preserve
  already fixture-verified scopes and do not infer completion from source links.
- [ ] Add reviewed completion records for every remaining finite supported contract.
  Ninety-seven rows plus S01/S03 are complete; the operation WebSocket and instance
  creation rows stay partial while S02/S06/S10 are open. No Go declaration is promoted.

### The selected 103 pairs: verified scope and next closure obligation

`resource_slice_test.exs` provides the shared **Unix** official typed-method
request/result, project/member, extension and native-error baseline. Shared TLS
transport tests do not establish a per-endpoint TLS matrix. Evidence below is
additional scoped evidence, not a repetition of that baseline.

| Selected pairs | Count | Additional behavior already evidenced | Remaining concrete closure obligation |
| --- | ---: | --- | --- |
| GET list/get projects, profiles, networks, storage pools and volumes | 10 | **Complete** (`b02_projects_v1` … `b02_storage_volume_v1`) with every mapped method. initial_inspection_v1: typed populated/empty/corrupt/403/404 results, routing, binding, byte/extension/lifetime bounds on Unix/mutual HTTPS | Only the named catalogue queries and tested DTO fields; custom volume samples. Other list selectors/types/fields/errors and backend/tool acceptance remain separate. |
| GET server discovery | 1 | **Complete** (`b02_discovery_v1`) with every mapped method. core_inspection_v1: populated/minimal valid metadata, RawQuery transport, required-field/version guards, 403/404 and scoped byte/readiness/lifetime cleanup on both transports | Broader discovery/auth fields and options remain open; no named-Go GetServer DTO parity. PUT/PATCH/root discovery are separate. |
| GET instances, instance and state | 3 | **Complete** (`b02_instances_v1`, `b02_instance_v1`, `b02_instance_state_v1`) with every mapped method. core_inspection_v1: catalogue queries with container samples, populated/empty/corrupt/403/404 fields, binding/ETags and byte/readiness/lifetime cleanup on both transports | Other recursion/filter/all-projects/instance-type/field/error/cluster variants remain open. |
| PATCH instance | 1 | **Complete** (`b04_instance_patch_v1`). Conditional typed InstancePut, explicit ETag, native empty sync result, Unix/mutual-HTTPS transport and independent failure/lifetime fixtures | Unconditional updates, full field/cluster behavior and real-daemon merge acceptance remain unverified. |
| PATCH project/profile/image/instance snapshot | 4 | Explicit ETag, valid field presence, scoped routes, native 200 empty sync versus 202 snapshot acceptance, errors, uncertain response loss and lifetime cleanup on Unix/mutual HTTPS | Conditional subset only; B05 certification, unconditional variants, additional fields/cluster/rejections and real-daemon merge/expiry acceptance remain separate. |
| POST instance; PUT instance/state; DELETE instance | 4 | PUT instance, PUT state and DELETE instance are **complete** (`b01_update_instance_v1`, `b01_update_instance_state_v1`, `b01_delete_instance_v1`); POST instance stays partial while S06/S10 are open. initial_mutation_lifecycle_v1: named-Go submission plus native /wait composition; populated update and restore bodies, applicable PUT ETags, running/success/failure, rejection, uncertainty/no replay and binding on both transports | Additional source/state/body/extension/error/cluster variants and real-daemon effects remain unverified. |
| GET snapshots and snapshot | 2 | **Complete** (`b02_instance_snapshots_v1`, `b02_instance_snapshot_v1`) with every mapped method. core_inspection_v1: catalogue list/get queries, populated/empty/corrupt/403/404 fields, binding/ETags and byte/readiness/lifetime cleanup on both transports | Names/other recursion, stateful/expiry/field/error/cluster variants remain open. |
| POST/DELETE snapshot | 2 | **Complete** (`b01_create_instance_snapshot_v1`, `b01_delete_instance_snapshot_v1`). initial_mutation_lifecycle_v1: native acceptance/wait outcomes, rejection, response loss/no replay and binding on both transports; instance PUT separately verifies restore-body linkage | Additional snapshot fields/expiry/stateful/cluster/error behavior and real-daemon restore effects remain unverified. |
| GET images and image | 2 | **Complete** (`b02_images_v1`, `b02_image_v1`) with every mapped method. core_inspection_v1: catalogue list/get populated/empty/corrupt/403/404 fields, binding/ETags and byte/readiness/lifetime cleanup on both transports | Public/private/filter/all-projects/recursion/field/error variants remain open; alias/export/token behavior is separate. |
| DELETE image | 1 | **Complete** (`b01_delete_image_v1`). initial_mutation_lifecycle_v1: native acceptance/wait outcomes, rejection, response loss/no replay and binding on both transports | Further image/cluster/error cases and daemon effects remain unverified; no implicit file or alias deletion. |
| GET operations and operation | 2 | **Complete** (`b02_operations_v1`, `b02_operation_v1`) with every mapped method. core_inspection_v1: grouped list flattening and direct get with fixed populated/empty/corrupt/403/404 fields, binding/ETags and byte/readiness/lifetime cleanup on both transports; separate poll/wait/event evidence | All-projects/other query/status/field/error/cluster variants remain open. No cross-group result ordering claim. |
| DELETE operation | 1 | **Complete** (`b01_cancel_operation_v1`). initial_mutation_lifecycle_v1: named-Go synchronous DELETE plus independent may_cancel denial, one DELETE, completion race, native rejection and lost-reply identity on both transports | Other cancellation states/errors/cluster behavior and daemon acceptance remain unverified. Acknowledgement is not proven cancellation completion or a new operation. |
| GET native operation wait | 1 | **Complete** (`b03_native_wait_v1`): finite timeout queries, gated bodies, ETags, running/completed/failed/cancelled snapshots, 403/404, EOF and pre-header loss, local lifetime cleanup and preflight on Unix/mutual HTTPS | None within the record. Approved exclusions: `?public`, arbitrary/empty secrets (rejected before I/O) and cluster forwarding; timeout=-1 rejection is an approved difference. Real-daemon timeout behavior is separate acceptance. |
| GET events | 1 | **Complete** (`b03_events_v1`, S03): named-Go type/all-projects/project/target upgrade targets, native 400/403/404, Event fields, listener/send matrix, inbound bounds, deadline/cancellation and peer closure on Unix/mutual HTTPS | None within the record. Approved exclusions: cluster forwarding and callback ordering. Real-daemon event streams are separate acceptance. |
| POST exec | 1 | **Complete** (`b03_exec_v1`, S01): named-Go collected, non-waiting, interactive PTY and record-output submission with user/group/cwd/size, extension guards, control frames, native 400/403/404 and upgrade targets; independent channel-failure, status, redaction, limit, lifetime and peer-closure fixtures on Unix/mutual HTTPS | None within the record. Approved exclusions: recorded-output retrieval (B07), cluster forwarding, arbitrary producers and tool capture/truncation policy. Real-daemon exec/PTY is separate acceptance. |
| GET operation WebSocket | 1 | Exec channels, barriers, bounded queues/frames, control and write-lifetime cleanup | Classify non-exec channel contracts and secret/query scope separately; exec evidence does not close console/events/migration. |

Primary evidence: `test/client_test.exs`, `test/discovery_helpers_test.exs`,
`test/resource_slice_test.exs`, `test/operation_test.exs`,
`test/operation_handler_test.exs`, `test/request_context_test.exs`,
`test/native_wait_reference_test.exs`, `test/exec_output_test.exs`,
`test/session_test.exs`, `test/web_socket_test.exs`,
`test/web_socket_failure_test.exs`. The machine manifest contains
specific test anchors; this table adds human closure obligations.

### Streaming and upgrade checklist

Each row has fixture evidence; none is an unrestricted protocol-parity claim.
The initial operations catalogue excludes event subscriptions, console and binary
file/image transfers. They remain foundation classification obligations.

| Contract | Existing bounded implementation/evidence | Remaining scope or evidence decision |
| --- | --- | --- |
| Live exec | `Session.run/collect/exec`; `test/exec_output_test.exs`, `test/session_test.exs` | S01 certified by `b03_exec_v1` on Unix/mutual HTTPS: bounded noninteractive collection plus interactive host-owned channels. Recorded-output retrieval stays B07; tools own capture/truncation/schema policy. |
| Static and dynamic console WebSocket | `Session.console`, `DynamicConsole`; `test/dynamic_console_reference_test.exs` includes native frames, repeated attachments, TLS, bounds and peer cleanup | Full native callback/reader/writer orchestration and all console types/options remain partial. Earlier blanket “dynamic console missing” notes are superseded. |
| Events and operation callbacks | `EventListener`, `Events`; `test/event_contract_test.exs`, `test/event_listener_test.exs`, `test/event_send_test.exs`, `test/operation_handler_test.exs` | S03 certified by `b03_events_v1` on Unix/mutual HTTPS. Explicit listener ownership is a recorded difference; Go callback order is never asserted. Operation handler orchestration stays with its own rows. |
| Instance/volume file GET/POST/DELETE | `Files`, `FileHeaders`; `test/file_reference_test.exs`, `test/file_variants_reference_test.exs`, `test/file_headers_reference_test.exs` | HEAD is absent; reconcile link/type/mode/query variants and both-transport failure matrix. Directory metadata and binary sinks already have separate evidence. |
| Image import/export/private token | `Images`; `test/image_transfer_test.exs`, `test/private_image_reference_test.exs` | Unified/split bytes, private token encoding, aliases and copy uncertainty have evidence; remaining compression/header/options and multipart failure cases need bounded classification. |
| Instance/volume/bucket archives | `Files`; `test/file_variants_reference_test.exs`, `test/backup_variants_test.exs` | Export/import/direct POST are implemented; classify each archive/name/pool/config/device/ISO variant and TLS/failure evidence rather than treating backups as absent. |
| Metrics, logs, console log, templates, debug memory | `Streams`; `test/streams_test.exs` | Typed byte/header/error and TLS evidence exists. Recorded exec log paths and debug repair are separate missing wrappers; define the remaining per-helper option contracts. |
| Raw instance/volume SFTP and NBD | `RawChannel`, explicit Incus helpers; `test/native_upgrade_reference_test.exs`, `test/volume_upgrade_reference_test.exs`, `test/raw_channel_test.exs`, `test/tls_stream_test.exs` | Raw transport/half-close/coalesced-byte/bounds evidence exists. NBD protocol implementation stays caller-owned; record all request options and the approved coalesced-byte oracle difference. |
| Typed SFTP v3 subset | `SFTP`; `test/sftp_helpers_reference_test.exs` | Approved init/extensions/open/read/write/close subset is implemented on Unix/HTTPS; classify unsupported operations explicitly. Full pkg/sftp parity is not the gate for this approved subset. |
| Copy/migration negotiation and relay | `Migration`, `Copy`, `ImageInstances`; `test/copy_negotiation_reference_test.exs`, `test/copy_guards_test.exs`, `test/migration_test.exs` | Recorded boolean/locality/cluster/project/member combinations, identities and relay cleanup have evidence. Enumerate remaining channel/option/remote-wait cases and single-origin differences; do not restart an already implemented copy port. |
| OCI host-adapter handoff | `OCI`; `test/oci_test.exs`, `test/oci_origin_reference_test.exs` | All 20 concrete methods have partial mappings. Explicit adapter/native projections/bounds/cleanup have evidence; installed conversion/authentication and unclassified cache/options remain separate. |
| SimpleStreams HTTPS and host delta | `SimpleStreams`; `test/simple_streams_test.exs` | All 20 concrete methods have partial mappings. Catalog/architecture/formats/checksums/full-file/delta/bounds/cleanup have evidence; refresh/cache/fallback variants and installed converter acceptance remain separate. |

- [x] Map explicit helpers to all documented routes and assign S01–S12 finite
  streaming obligations in the full inventory; source anchors do not certify completion.
- [x] Separate missing implementation, contract/evidence work, source differences
  and separately owned acceptance for every row. New scope exclusions still need
  explicit approval; existing boundaries are retained. No blanket “full matrix” gate.
- [ ] Finish independent review and canonical/both-platform/immutable-consumer
  checks for each implemented slice. Real Incus acceptance requires fresh explicit
  opt-in and isolated state; historical 4.3 and Macus hardware are separate gates.

### Ten inspection contracts — fixture-verified

The five remaining initial-tool inspection families now each have two checked
method contracts: list and get. `test/inspection_contract_test.exs` performs 100
unchanged named-Go comparisons over Unix/mutual HTTPS: populated/empty DTOs,
known metadata type corruption and native 403/404. Native getters return ETags;
list methods do not, so list-header retention and unknown-field preservation
are independent evidence. Every method also checks response-byte rejection,
declared extensions where applicable, deadline/cancellation and actual peer EOF
with one local GET. Fixture waits are finite without elapsed success assertions.

`fixture_contracts.initial_inspection_v1` is one profile applied to ten method
rows. The validator rejects removed methods/cases/transports/evidence, unknown
profiles, wrong attachments and completion overclaims. Canonical tests establish
behavior; anchor validation alone cannot. The outer endpoint status stays partial.
This is not a claim of complete REST, Go declaration, tool or backend acceptance.
Default named-method queries only, custom volume samples only; per-family gaps
remain recorded. Tool authorization, list/output limits and truncation are separate.

Progress: selected pairs 22 -> 32; fixture-verified inspection method contracts
0 -> 10 across projects/profiles/networks/storage pools/volumes. Catalogue routes
and descriptors are unchanged. Next prioritize bounded mutation-lifecycle closure
and the finite endpoint/stream backlog; declaration status is separate.

### Conditional instance PATCH — approved and fixture-verified

`Incus.call(client, "PatchInstance", %{"name" => name}, body: partial, etag: etag)`
adds one typed endpoint with a nonempty ETag capped at 1024 bytes. It preserves
field presence without client read/merge, expects HTTP 200 native empty sync
metadata `{}`, retains native rejection and reports dispatched failure as
uncertain without replay. Any actual unexpected operation identity is retained.

`test/instance_patch_test.exs` covers Unix/mutual HTTPS. The unchanged RawQuery
oracle takes the complete path/query explicitly; it does not supply automatic
API-prefix or project/member selection. Comparisons establish request/result
transport projection; endpoint-specific fixtures and pinned server-source review
establish the expected contract. They do not prove real-daemon merge behavior.
The original raw-operation PATCH fixture remains synthetic async-helper evidence.

Progress: catalogue descriptors 268 -> 269, catalogue routes 188 -> 189,
selected partial pairs 21 -> 22, uncatalogued PATCH pairs 25 -> 24. Go declarations
remain 1239 partial / 41 missing, complete_port=false, and task 3.9 remains open.
Unconditional PATCH, other PATCH routes and full field/error/cluster/backend
matrices remain gaps. The inspection batch is recorded above; next prioritize bounded mutation-lifecycle
closure and the finite stream contracts.
No tools, installed converter or real-backend acceptance is added.

## Historical evidence (chronological)

Earlier verified slices include the four response metadata extraction helpers,
operation-to-certificate/cluster token conversion and both token String helpers,
and the five EventListener lifecycle helpers. Permanent unchanged-native
differential drivers and independent failure/budget/owner-cleanup fixtures are
linked from `priv/incus/coverage.json`.

The approved OCI host-adapter slice adds 15 concrete partial method mappings and
the passive constructor. Alias normalization, all pinned architecture aliases,
layer fingerprints, native image JSON and 11 unsupported-method errors use an
unchanged native oracle with a fixture-only skopeo stdout stub. Binary delivery,
deadlines, cleanup failure, caller loss and credential/config isolation use fake
adapters. OCI connection-info/HTTP helpers still have no OCI-specific evidence;
alias-architecture and no-op disconnect now have pinned differential evidence. No installed host converter is provided or accepted.

The current checklist above supersedes broad historical “remaining groups”
statements. In particular, copy matrices, dynamic console, origin helpers,
operation handlers, bounded exec and SFTP subsets have acquired evidence since
those statements were written; their remaining scope is listed individually.

## Approved OCI host boundary

The approved design excludes host commands and keeps platform behavior at the
host boundary. The pinned `client/oci_images.go` has `exec.LookPath("skopeo")`,
external process execution, a root requirement for `GetImageFile`, and private
temporary image conversion directories. A literal runtime port conflicts with
those constraints. The explicit adapter now supplies partial evidence for 15 of
its 20 concrete OCI methods; three now remain missing and none is fully accepted.
SimpleStreams is a separate protocol and is not excluded by this finding.

The user approved keeping OCI in scope through an explicitly supplied host
adapter on 2026-10-11. The revised design/spec define native projection,
bounded callbacks and acknowledged binary sinks, per-call cleanup and a separate
installed-adapter acceptance gate. Opsmaru supplies no command runner, root
escalation or temporary conversion directory. SimpleStreams remains in scope.

## Closure gate

Under the approved endpoint/method, streaming and consumer-behavior gate, every
supported remaining behavior needs implementation and pinned differential
or independent protocol evidence, including errors, extension checks, project/
member selection, operation identities, credential redaction, bounded queues/
deadlines/streams and cleanup. Possibly accepted mutations must never be replayed.
Keep the approved coalesced-byte oracle exception and local-wait-no-cancellation
contract visible. Then run macOS/Linux library checks, immutable consumer build,
strict Credo/precommit, isolated canonical checks, strict OpenSpec and independent review
(the user approved this replacement after Greptile quota exhaustion).
Only after those gates pass can the task checkbox be updated. Backend/hardware
acceptance stays separate and cannot substitute for missing client evidence.


## Approved SimpleStreams boundary and verified partial slice

On 2026-10-12 the user approved keeping SimpleStreams in scope with explicit
verified HTTPS and an optional host delta adapter. The unchanged native reference
probes `/dev/incus/sock`, tries HTTP before HTTPS and runs xdelta3 with temporary
files. Opsmaru omits that discovery/downgrade and delegates conversion/state to
the host. These approved exceptions do not remove SimpleStreams from task 3.9.

The first slice supplies 16 partial concrete method mappings and passive
construction. The unchanged oracle verifies catalogs, newest aliases, native
architecture preference, fingerprint ambiguity/errors, all six image formats,
optional fields, delta manifests and unsupported-method errors. Independent TLS
fixtures verify full-file binary/hash/name/size fidelity, empty parts, sink
rejection, aggregate byte bounds, caller/deadline cleanup and redirect rejection.
The host explicitly supplies architecture; reproducing pinned platform preference
requires the same value, including its x86_64 Darwin fallback. Metadata has an
immutable in-memory cache, not a shared/on-disk cache. Catalog entry and alias
expansion limits are explicit and failure is visible.

The optional host delta adapter is now fixture-verified: explicit base/source and converter, verified delta input, size/SHA-256-verified output, unique call identity, absolute deadlines, sticky emitter rejection and bounded cleanup. No converter or temporary files are bundled. SimpleStreams connection-info remains missing; origin HTTP and no-op disconnect
now have pinned differential and independent path/budget/redirect evidence. Actual installed delta conversion,
cache/fallback variants, exhaustive malformed metadata and any installed converter
acceptance remain open. Full-file success must not be advertised as complete
SimpleStreams support or used to close task 3.9. Task 4.3 remains separate.


Image create/rebuild now has complete native body comparisons and explicit source
project binding. The unchanged reference omits project inference; a dedicated
oracle test records that defect, while corrected comparisons supply its explicit
request field. Conflicting projects reject before token/target I/O. Raw upgrades
and writes have independent caller-loss guards verified under stalled I/O. These
corrections do not close the remaining copy matrix, helper or acceptance gates.


## Direct-backend gate is now independent and verified

Task 4.3 passed on 2026-10-12; see [direct acceptance evidence](real-incus-acceptance.md).
That backend result does not promote partial/missing inventory mappings or close
3.9. Installed host converters, gateway and Macus integration/hardware gates
remain separate. Earlier references to open 4.3 above describe their recorded
validation point, before this direct-backend run.


## Verified remaining origin helpers

The unchanged OCI oracle now verifies alias-architecture mapping with an explicit
host local architecture, including different image/local architectures, native
VM-type errors and no adapter activation on rejected configuration. OCI and
SimpleStreams disconnect match the native no-op. SimpleStreams HTTP handles
are passive and origin-confined; native 200/305/409 responses, binary bodies,
ETags and duplicate queries compare with unchanged native DoHTTP/GetHTTPClient.
Independent fixtures reject cross-origin URLs, traversal/control/malformed
queries and redirects, and enforce readiness and request/response budgets.
All 69 focused OCI/SimpleStreams/native-HTTP cases pass. OCI now has 17 partial
and three missing concrete methods; SimpleStreams has 19 partial and one missing.
No mapping is promoted to complete, and 3.9 remains open.


## Native constants, origin metadata and explicit request lifetimes

All 188 exported API constants now have unchanged-native value comparison; 171
previously missing constant rows gain partial evidence. Constant values remain
model data and do not implement the named authentication/features. SimpleStreams
CA-configured connection-info has native default/origin comparison and independent
no-I/O/readiness/binding evidence; all 20 concrete SimpleStreams methods now have
partial mappings, without claiming complete protocol/cache/option coverage.

Explicit request contexts add finite absolute deadlines, idempotent local
cancellation and owner lifetime. Unix/HTTPS constructors and WithContext preserve
query/ETag/native profile results against unchanged helpers. The Elixir client
remains immutable; it does not reproduce the Go WithContext shared-pointer
mutation. Independent fixtures cover pre-dispatch rejection, uncertain dispatched
POSTs, stalled I/O and exit-trapping sinks, raw/WebSocket/listener callbacks,
long poll intervals, retained operation snapshots and adapter cleanup ordering.
No cancellation sends Incus DELETE or replays mutations. Original clients remain
independent. Native get/refresh/wait-context/websocket interface helpers gain
scoped partial evidence; callback handler orchestration remains unimplemented.

The manifest remains complete_port=false with 1108 partial and 172 missing
declarations. Task 3.9 is still open: supported-scope/evidence completion gates,
remaining client methods and model/helper/protocol matrices need further work.
The user subsequently approved independent review in place of quota-blocked Greptile;
review does not replace any implementation or acceptance gate.


## Verified native file headers and pure model projections

ParseFileHeaders now compares native signed ownership, overflow, leading zeros,
base-zero permission masks, malformed octal fallback, defaults and first duplicate
semantics. A binary Unix file download compares the actual resulting metadata;
transfer response maps preserve the native first value rather than the last.
The helper bounds aggregate headers and returns a redacted failure on invalid
structure or excess input. No file state is created.

Server.Filtered and Event.ToLogging now compare unchanged native output: exact
case-sensitive config suffix filtering, certificate removal, extension counts,
logging/network-ACL/lifecycle/operation records, requestor formatting, timestamps,
float64 contexts and native defaults. Go map-context pair order is unspecified;
only those unordered pairs are normalized for comparison. Operation context
order remains exact. Null event metadata is rejected explicitly instead of
propagating the reference's nil-pointer panic. The library emits no log and does
not broaden the native filter into an authorization or general secret detector.

Eight additional declarations gain partial evidence. No mapping becomes complete;
1116 partial and 164 missing declarations remain, with complete_port=false.


## Native configuration metadata lookup

GetKeys now has native last-map-wins/default/null-entry and exact entity/group
error comparisons, including control/Unicode quoting. Codec validation supports
its aliased string entity/group map keys and rejects malformed nested groups or
key types. Inputs and names are bounded; original models remain unchanged and
no runtime atoms or backend calls are created. Six more declarations gain partial
evidence: 1122 partial, 158 missing, complete_port=false. All prior protocol,
model, complete-evidence and installed/hardware acceptance gates remain open.


## OCI origin helpers

OCI connection-info, GetHTTPClient and DoHTTP now have unchanged-native
CA-configured origin/status/body/ETag/query comparisons. Helpers use only the
explicit verified HTTPS connection, not an origin or credential inferred from
opaque adapter configuration. Metadata/handle construction is passive and needs
no credential-file reads or converter. Raw HTTP checks readiness/owner, rejects
foreign/invalid paths, bounds requests/responses and retains uncertain dispatched
mutations without replay. Redirect rejection is independently verified. Unix
adapter-only configurations cannot supply these HTTPS-origin helpers. All 20
concrete OCI and all 20 SimpleStreams methods now have partial mappings; registry
authentication, installed conversion and complete option/protocol matrices remain
unverified. Three declarations gain partial evidence: 1125 partial, 155 missing.

## URL values, copy combinations and relay cleanup

The unchanged URL builder now compares all eight exported construction/setter
helpers: replacement paths and byte escaping, sorted query keys with stable
duplicate values, project/member suppression, Unicode authority and fragments.
The portable immutable value has component/count/rendered-byte bounds and a
redacted Inspect implementation. It never becomes an authorized connection or
performs I/O. Nine declarations gain partial evidence (including its type):
1134 partial, 146 missing; complete_port=false.

Copy comparisons now enumerate all 32 instance, two snapshot and eight volume
boolean combinations, pull/push modes, active/inactive source states and local
or separate HTTPS fixtures. Same-origin cluster comparisons add member placement,
internal-copy extensions, absent targets and different source/destination projects.
Fixture completion waits for both negotiation requests where needed, preserving
the unchanged oracle despite its asynchronous completion race. Requests, native
identities and acceptance/completion remain independently checked.

Independent review found duplicate option keys could silently select the first
value, and malformed migration mode/deadline values could select defaults.
Copy/move, negotiation and relay now reject those cases before I/O; relay errors
retain accepted handles. New peer-observable fixtures prove cleanup of all opened
sockets after a later channel upgrade fails and after caller loss. No retries,
backend cancellation or deletion are introduced.

Task 3.9 remains unchecked: operation handler/remote-operation orchestration,
full SFTP helpers, remaining model/JSON/YAML/status-error helpers, constructors,
recorded exec/dynamic console behavior, complete protocol/option matrices and
supported-entry completeness gates still need verification. Existing real-backend
4.3 evidence is independent; no new backend or Macus hardware acceptance follows
from these fixtures. Installed OCI/delta conversion and gateway remain separate.

Greptile review `5c8949b1-a836-4ab0-b642-3285f32cc998` scored this continuation
5/5 with one P2 malformed-input finding. The full historical branch exceeded
its payload limit before submission; the single completed sweep covered
8a8a9b224fc3aefbf2a614fd4872eabd739cbc61 through
32228aa4277083571701a35ce81a9e3301bc6952, not the whole foundation. Both improper
path/query list crashes were independently reproduced against the reviewed source.
Bounded proper-list validation fixes them, with permanent direct-value/setter
regressions. The correction is independently verified, without another quota-
consuming Greptile sweep. Review confidence does not close 3.9 or authorize merge.


## Native status-error helpers

StatusErrorf, StatusError.Error/Status and StatusErrorMatch/Check now compare
with the unchanged native helpers: native status text for every status 0..999
and int64 extremes, verbatim messages (including literal `%`, Unicode and control
bytes), the literal zero value, duplicate and non-matching codes, and non-status
errors. The Elixir value takes a preformatted message without emulating Go `fmt`
verbs, and only a direct struct matches because Go `errors.As` unwrapping has no
Elixir counterpart. Inputs are bounded and Inspect is redacted. Six declarations
gain partial evidence: 1140 partial, 140 missing, complete_port=false. Task 3.9
remains open; this slice was implemented by a delegated pi-web agent session and
independently reviewed and re-verified before commit.


## Nested shared/api model schemas

Seventy-nine nested resource, state, source/target and control models now have
unchanged-native JSON evidence through `Model.decode/2`. Schema-generated values
(bounded at depth three for the mutually recursive GPU/network SR-IOV card
types) are accepted by both sides, native canonical output decodes in Elixir,
and emitted top-level keys equal the schema fields, including Go-promoted inline
structs. Empty and all-null inputs are accepted by both; every scalar field's
wrong-type, float-into-integer, out-of-range and negative-unsigned values are
rejected by both. Two recorded differences remain open, asserted side by side:
native `time.Time` requires RFC 3339 while `Model.decode/2` accepts any string,
and native decoding drops unknown fields while the lossless model retains them
(intended). Seventy-nine declarations gain partial evidence: 1219 partial, 61
missing, complete_port=false. `Response`, `ResponseRaw` and `ResponseType`
remain missing.

The status-error Inspect redaction applies to values with the struct's own
keys. Hand-built maps with different keys bypass custom Inspect implementations
entirely (as with `Opsmaru.Incus.Error`); they cannot be intercepted.


## Native ConfigMap/DevicesMap YAML decoding

`NativeConfig.from_yaml/3` decodes from yamerl's public token stream rather than
its YAML 1.2 resolved values, so go-yaml v4 resolution applies only to plain
untagged scalars; quoted and block scalars stay strings. Explicit tags, anchors,
undefined/forward/self aliases, duplicate keys, merge keys (including anchored
flow and block templates), null/dropped keys, null versus absent documents and
first-document selection follow the unchanged native decoder. Alias expansion
is charged against an explicit node/byte budget before construction. A 318-row
oracle matrix and 13,800 randomized reviewer-generated config/device documents
across twelve seeds match the unchanged native decoder, including values under
dropped null keys, anchored merge templates and leading-dot exponents. Three differences remain
recorded side by side: yamerl accepts tab indentation that the native scanner
rejects; native replaces invalid UTF-8 in `!!binary` with U+FFFD while ours
rejects; go-yaml's aliasing-ratio check rejects some expansions that remain
within our bounded budget; and native accepts flow nesting to 10,000 levels while
ours bounds total flow-nesting work (10,000,000 depth-weighted structural points)
before yamerl runs, so pathological deep documents are rejected quickly. `ServerFiltered.MarshalYAML` is still missing. Two
declarations gain partial evidence: 1221 partial, 59 missing, complete_port=false.

Batch Greptile review `bf9291d9-973d-46d3-b589-34ffff9d08e4` (1/5) found four
YAML parity defects after the slice was committed: anchors under dropped null
keys lost their contents, sequences under dropped keys were rejected, a merge
flag leaked into later device maps, and leading-dot exponents ending the input
stayed strings. All four were confirmed against the unchanged native driver and
fixed, together with trailing-dot floats, alias-to-sequence merge sources,
flow-sequence anchors and lazy tag resolution under dropped keys found by a
broader reviewer differential. Each case is now an oracle matrix row.

Greptile batch re-review `bc6c830a-6675-4890-8069-946d21e2dad8` (2/5) confirmed
those fixes and found three more: aliases to maps stored under dropped keys
skipped key-type and duplicate checks, duplicate handling under dropped keys was
quadratic (6.1 s for 458 KB), and `._5` became a number. Key and duplicate
checks now run when a node is constructed, by any path; duplicate tracking is
keyed; and underscore validation mirrors Go `strconv`. Decoding is linear in
our code at roughly twice yamerl's own tokenizer time, about 1.4 s at the 1 MiB
input bound in the worst measured shape.

Greptile batch pass `64430408-5f07-4998-93d1-55b34a3e87fa` (3/5) confirmed those
fixes and found two more: a syntax error in an unused later document rejected
a valid first document, and literal nested merge chains did quadratic folding
outside the work budget (six depth-9,999 chains in 953 KB took 91 s; yamerl
alone needs 26.5 s to tokenize them). Decoding now stops where go-yaml's scanner
stops after the first document, matches native's 10,000-level depth limit,
folds merge chains innermost-out once with every folded entry charged to the
node budget, and rejects documents whose total flow-nesting work exceeds the
bound in a pre-pass before yamerl runs. The pathological documents are rejected
in milliseconds; the slowest accepted reviewer-measured shapes (hundreds of
moderately nested merge chains near the input bound) take about 1.7 s, linear in
input size.


## YAML rescoped to a strict subset (supersedes the YAML sections above)

The exact go-yaml re-implementation grew to about 2,050 lines and each review
round found further corner-case or denial-of-service defects. The user chose
on 2026-10-13 to rescope ConfigMap/DevicesMap UnmarshalYAML to a strict subset
with a simpler contract: every accepted document equals the unchanged native
result, and everything else is rejected. `Opsmaru.Incus.NativeYaml` (about 535
lines) replaces the previous implementation; `NativeConfig` returns to its JSON
code plus a delegate.

Supported: one document of block or flow mappings (ConfigMap scalar values;
DevicesMap mappings of scalars), string keys, quoted/block scalars, plain scalars
resolved with go-yaml v4 rules (nulls, booleans, base-0 integers including
leading-zero octal and underscores, uint64, floats, .inf/.nan), anchors on
scalars and block mappings, aliases, `<<` merges with native precedence,
duplicate-key rejection, null versus absent documents and existing-map merges.
Recorded rejections where native accepts: explicit tags, directives, additional
documents, sequences other than merge lists, null and non-string keys, anchors
inside flow collections or on keys (yamerl misplaces them), date-like plain
scalars, numeric forms outside the mirrored resolver, more than 100 alias
expansions (go-yaml's aliasing check cannot fire at or below 100), and plain
scalars starting with reserved indicators (`@`, backtick) that yamerl accepts.

yamerl rescans flow collections that could become implicit keys quadratically
before emitting tokens, so a token gate alone cannot bound it. Decoding runs in
a linked worker with a 2 s deadline, a 100 M reduction budget and a 64 M-word
heap cap; pathological 1 MiB documents are rejected at the deadline and
realistic 1 MiB documents decode in about 0.1-0.2 s. yamerl's own crashes on
malformed input (for example `: :`) are converted to rejections at the scanner
call only. A 310-row contract matrix, realistic Incus documents, a seeded
randomized contract test and 17,600 reviewer-generated documents across eight
seeds show no contract violation; about 83% of native-accepted random
documents are accepted.

Greptile batch review `a6e929ef-5592-42e4-91d1-01caf5d51dcc` (4/5) found that a
long-mantissa float such as `99999999999999999999e300` overflowed float64 and
crashed the linked worker (terminating callers that do not trap exits), and
that a timed-out worker could still deliver a late result after cleanup. The
float range check now uses the leading significant digit's decimal magnitude,
worker failures return a rejection, and cleanup waits for the worker's
termination before draining its messages. Both cases are regression tests.


## ServerFiltered.MarshalYAML (byte-exact subset)

`Projections.filtered_server_yaml/1` renders the filtered server through
`Opsmaru.Incus.ServerYaml` and must equal the bytes of go-yaml v4
`yaml.Marshal(server.Filtered())` (v3-compatible defaults: four-space indent,
unlimited width), or reject. It mirrors the native field order and inline
structs, `api_extensions_count` insertion before `api_status` when positive,
empty collections as `{}`/`[]`, lowercase driver-info keys, go-yaml's natural
map-key ordering, double quotes for strings that would resolve to another type,
single quotes for YAML 1.1 booleans, base-60 floats, `<<` and strings the
emitter cannot write plain, and plain style otherwise. Recorded rejections where
native renders: strings with tabs or line breaks (native emits literal blocks or
escapes), date-like plain values and float-overflow forms outside the mirrored
resolver, and map keys over 128 bytes, non-ASCII or with 19+ digit runs. The
server-filter config coercion and SENSITIVE censoring are reused unchanged.

Byte comparisons against the unchanged native driver: realistic, empty and null
servers; every one- and two-atom string (5,391) as a value and as a key with no
mismatch (99.8% rendered); 6,400 randomized adversarial servers and 1,500
typed-config servers with no mismatch. One declaration gains partial evidence:
1222 partial, 58 missing, complete_port=false. Task 3.9 remains open.

Greptile batch review `9f48556b-0bb4-4b8e-82e7-e6a5175d2350` scored the YAML
subset decoder and ServerFiltered renderer 5/5 and confirmed the earlier
findings resolved. Its one non-blocking finding (a struct passed as the existing
map made `from_yaml/3` raise) is fixed: structs are rejected as existing values
on both the JSON and YAML paths, with a regression test.


## Operation handlers and remote-operation waits

`Operation.add_handler/3` and `remove_handler/3` are the immutable counterparts
of native operation AddHandler/RemoveHandler. The caller passes an explicit
`EventListener`, which must be bound to the same backend (owner, transport,
address, TLS, project, member) and identity; no listener is opened implicitly.
As natively, the operation is refreshed first: a successful final operation
returns no target, a failed one returns its native error, otherwise the
callback receives each decoded Operation event for this ID while other IDs and
undecodable metadata are ignored. A pinned differential drives the unchanged
client and ours over the same echoed event sequence (another ID, running,
malformed, final): both deliver the running and final events with identical
decoded data; removal, repeated removal and nil-target removal agree.
`Migration.add_handler/3` forwards to the accepted target (the native
placeholder for a missing target becomes `{:ok, nil}`), and RemoteOperation
Wait maps to `Migration.wait_target/2`, compared with native `rop.Wait()` for
a successful and a failed (`err: "boom"`) target. Recorded differences: native
disconnects its internal listener on the final event and attaches handlers to
a later target asynchronously; here the caller owns listener lifetime and the
target is fixed at negotiation. Native multi-address copies wrap target errors
as "Failed ... creation"; with one approved origin the native operation `err`
is retained. The test fixture now echoes 16-bit-length WebSocket frames.
Ten declarations gain partial evidence: 1232 partial, 48 missing.


## Native response model types

`Response.decode_native/2` adds an explicit pure JSON projection for shared/api
`Response`, `ResponseRaw` and `ResponseType`, alongside the lossless
`Model.decode/2` schemas and the existing wire envelope decoder. The unchanged
native driver compares all seven envelope fields, empty/null defaults, unknown
field dropping, arbitrary response-type strings, signed int64 limits, field-type
rejections and case-insensitive ASCII field names. Response RawMessage metadata
retains parsed integer precision; ResponseRaw's `any` metadata is compared by
exact native float64 bits, including large numbers and decimal signed zero.
Go can marshal large float64 values as integer-looking decimals whose exact
integer value differs from the represented float; bit comparisons avoid treating
that serialization spelling as a type-value mismatch.

The 12 focused tests include 1,600 seeded valid/adversarial comparisons, nested
metadata, near-1-MiB plain/escaped strings and independently recorded native-
accepted rejections. Input/output are bounded to 1 MiB and nesting to 64 levels.
Duplicate-key merging, ambiguous case aliases and non-ASCII envelope keys reject;
ResponseRaw also rejects negative zero with an integer mantissa (with or without
an exponent), because Jason discards its native float sign. JSON whitespace and
number spelling are not preserved. These are partial JSON type mappings, not
YAML parity, Go RawMessage byte preservation or full type acceptance.

Self-review verified signed-zero behavior against the unchanged driver before
adding the rejection guard. No external review was run for this small slice;
the new commit and the previously recorded unreviewed commits remain for the
next significant batch review. Three declarations gain partial evidence:
1235 partial, 45 missing, complete_port=false. Task 3.9 remains unchecked.
Formatting, warnings-as-errors library compilation, strict Credo, 959 library
tests, passive embedded startup/restart and strict OpenSpec all pass. Full
standalone checks and any new installed/backend/hardware acceptance are separate.


## Approved bounded SFTP v3 helpers

On 2026-10-13 the user approved a safe SFTP v3 subset for
`GetInstanceFileSFTP` and `GetStoragePoolVolumeFileSFTP`. OTP's `ssh_sftp` requires
an SSH connection; Incus supplies a raw SFTP upgrade. The approved design is
recorded in section 4c and was strictly validated before implementation. Existing
`Incus.sftp/2` and `volume_sftp/4` still expose raw channels. New
`Incus.file_sftp/2`, `volume_file_sftp/4` and both native names through `call/4`
return an owner-bound `SFTP` session with initialization, extension metadata,
five explicit open modes, positional read/write, file close and session close.

The unchanged native driver calls both actual Incus helpers and pkg/sftp file
methods against private Unix and mutually verified HTTPS fixtures. Comparisons
cover HTTP paths/project/member/upgrade, INIT v3, duplicate extension last-wins,
open flags, binary request/response bytes and native IDs, EOF, successful close
and failed close's handle invalidation. Maximum 128-KiB data reads/writes compare
exactly; a 30-row seeded version/extension corpus checks success/rejection.
Native constructor failures demonstrably close the peer connection. Independent
fixtures cover the pinned coalesced-byte exception, fragmentation, malformed/
oversized replies, pre-I/O validation, absolute deadlines, cancellation, caller
loss, idle EOF and stream expiry. Local stream expiry leaves a shared host request
context and another session usable. Inspect redacts session and native handle
bytes; failed mutations retain request identity/uncertainty without replay.

Scope is explicit: one creator-owned request at a time; at most 64 extensions
(name 1024/data 4096 bytes), 128 live handles further limited by queue_limit,
256-byte nonempty handle values, 4096-byte UTF-8/NUL-free paths, positive transfers
up to 128 KiB, nonnegative int64 offsets and 132096-byte reply packets further
limited by max_response_bytes. Outgoing packets must fit request/chunk budgets.
Short/empty DATA, invalid/mismatched/trailing packets, unsupported versions and
other SFTP operations reject. Reads do not perform Go's additional requests to
fill a short result; directory/stat/attribute/extension operations, arbitrary
flags, concurrent pipelines and full pkg/sftp.Client behavior are not provided.
Status code/message/language are retained from the wire rather than replacing
known codes with Go filesystem errors. These differences do not close 3.9.

Self-review added regressions for request timeout identity, invalidation after a
failed close, unrelated-PID protection, idle EOF cleanup and shared-context
isolation. Four method/interface declarations gain partial mappings: 1239 partial,
41 missing, complete_port=false. No entry is promoted to complete. New Linux,
immutable-consumer, installed/backend/Macus hardware and significant-batch review
acceptance remain separate; no such acceptance follows from these fixtures.
The final slice checks pass: formatting, warnings-as-errors library compilation,
strict Credo, 981 library tests, passive embedded startup/restart and strict
OpenSpec. SFTP failure values retain the original connection, verified host
identity, session reference and native request ID for reconciliation. PostgreSQL
and full standalone checks were not started. Task 3.9 remains unchecked.

## Bounded noninteractive exec collection — 2026-10-13

`Session.collect/4` consumes an already accepted creator-owned noninteractive
live exec session. Both host sinks must acknowledge each binary chunk with `:ok`.
The caller sends stdin explicitly before collection; the helper sends its native
write barrier. At most one read per output channel is outstanding, so a blocked
stdout cannot prevent stderr delivery. Aggregate stdout/stderr payload bytes,
per-chunk connection limits and an absolute collection deadline bound work,
including callbacks and authoritative operation completion. Final success retains
the operation, native exit status and per-stream delivered byte counts. A nonzero
guest exit remains data. Output EOF/barriers alone cannot establish completion.

The unchanged native `ExecInstance` driver compares actual stdin, binary stdout/
stderr, barriers, project/member POST paths/bodies and exit status over private
Unix and verified mutual HTTPS. Comparisons explicitly supply all native exec
default fields; the library's lossless model still does not materialize Go's
omitted zero values. Independent fixtures verify exact aggregate limits, excess
output, sink rejection/exception, exit-trapping callback deadlines, host
cancellation, owner loss (including peer-observed closure), concurrent output,
normal close versus malformed barrier/abrupt disconnect and operation failures.

Scope stays bounded: live noninteractive sessions with `wait-for-websocket=true`,
stdin/stdout/stderr channels and optional control; both sinks are mandatory.
Only empty text barriers and normal stream EOF end output. Nonempty text rejects
rather than reproducing native acceptance of any text as EOF. Frames exceeding
the host chunk limit reject rather than splitting or buffering. Invalid options,
foreign creators and recorded/interactive sessions reject before channel IO and
leave the session usable by its creator. Collection closes all local channels
after it starts; local expiry never cancels a shared host context or the backend.
No replay, recorded-file retrieval/deletion, console collector or MCP tool is
added. Sink side effects already acknowledged before failure remain host-owned.

The user approved retaining this bounded subset with its larger fixture evidence
after the size stop. The two ExecInstance declaration mappings gain partial
evidence; the 31 missing Go types, other missing declarations and all previous
gaps remain visible: 1239 partial, 41 missing, `complete_port=false`. Task 3.9
stays open under the new endpoint/method, streaming and consumer-behavior gate.

## Bounded full-duplex exec continuation — 2026-10-13

The approved `Session.run/7` slice combines native submission/negotiation,
preflight bounded binary stdin, concurrent acknowledged input/output and final
completion under one lifetime starting before POST. It reuses the collector,
retains accepted identity before upgrades, restores original client bindings and
never replays or cancels Incus. Existing Unix/mutual-HTTPS unchanged ExecInstance
comparisons now cover the combined helper. Independent fixtures cover blocked
stdin, chunk/input/output limits, submission/negotiation deadlines, shorter host
contexts, cancellation, sink failure and owner cleanup without elapsed-time bounds.
ExecInstance remains partial; InstanceExecArgs and other declaration gaps remain
visible. Task 3.9 stays open and `complete_port=false`. Interactive/recorded IO,
arbitrary input producers and tool capture/truncation/policy are outside this slice.

PR #5's Greptile finding reproduced valid 8192-byte stdin failing after acceptance
when the independently configured WebSocket frame limit was 4096 bytes. The
writer now chunks to the smaller frame/chunk limit. Permanent Unix and verified
mutual-HTTPS regressions require two exact binary chunks, input closure, native
completion and a single POST without DELETE. Declaration status is unchanged.

## Blocked-stdin failure evidence — 2026-10-14

Two independent Unix fixtures hold input unread and observe the owned channel
waiting in the actual socket send before local deadline or host cancellation.
Both outputs still progress; errors retain the original accepted identity/binding,
all four channels terminate and peers observe closure without an input barrier,
final-completion poll, DELETE or replay. Local expiry leaves the shared host
context active and the original operation pollable. Production code and the
native oracle are unchanged; this adds evidence to the existing partial scope.

## Selected endpoint/method evidence — 2026-10-14

`priv/incus/endpoint-evidence.json` now selects 21 priority pairs for
`add-incus-operations`: server (1), instances/state (7), snapshots (4), images (3),
operations (5) and exec (1). All 21 are partial. Native `/wait` is already
implemented through GetOperationWait/GetOperationWaitSecret with typed request/
result evidence. Bounded `Operation.wait` separately polls operation GET; its
local-cancellation fixtures do not prove native long-poll behavior. Server-side
blocking/timeout/disconnect/cancellation and secret matrices remain open. Native
timeout=-1 rejects; explicit native waits accept 0..3600 seconds under finite
connection/context bounds. The initial proposal incorrectly called /wait missing;
source review corrected that classification without adding runtime behavior.
Restore is an instance PUT behavior, not a fabricated snapshot restore route.

The development-only Go extractor uses the already pinned go-yaml dependency to
read unchanged `doc/rest-api.yaml`; the validator checks its SHA-256, native
verb/path pairs and selected recursion variants. Path placeholder names normalize
for catalogue comparison. Query/body/model/result/extensions/guards resolve from
`methods.json`; scope, ETag/error/acceptance/completion and stream evidence links
are recorded per pair. The validator checks public function arities and test AST
anchors, not correctness of those tests. Differential/fixture tests themselves
run in the canonical suite. Shared uncertainty evidence is a transport fixture,
not an exhaustive per-mutation matrix. All other REST pairs, option/error/transport
matrices, non-exec upgrade and public-secret variants remain unclassified/open.
This manifest cannot authorize tool exports or close task 3.9. Coverage adds only
a manifest pointer: 1239 partial, 41 missing, `complete_port=false`. No runtime,
native oracle, tool/gateway implementation or real-backend acceptance changed.

PR #6's Greptile P2 finding exposed an evidence-validator gap: omitting the native
secret-wait variant still passed. The validator now requires exactly the expected
GetOperationWaitSecret mapping; regression checks reject both a removed variants
field and an empty list. This strengthens inventory preservation only. All 21
pairs remain partial, native long-poll/secret behavior gaps stay open, and coverage
regeneration preserves every declaration and `complete_port=false` byte-for-byte.

## Scheduler-tolerant cleanup evidence — 2026-10-14

The macOS cleanup fixture repair separates observing termination from the
unchanged runtime budget. Existing 500 ms elapsed/report assertions failed in
controlled reproductions after all console actors had terminated or the event
socket had closed, solely because observation/reporting was delayed by 600 ms.
This establishes the assertion weakness; historical runner delays remain
unmeasured. Real blocked-I/O tests now use a shared five-second process observation
window and explicit closed-socket results against thirty-second I/O lifetimes.
They retain native identity, pending-writer errors and no DELETE/replay checks.
Controlled delayed-console-observer and delayed-event-peer cases are permanent.

A direct call-trace test verifies close requests are batched before waiting and
only the first blocked wait spends the existing shared allowance (at most 100 ms);
remaining waits get zero. A fresh-per-channel 100 ms mutation fails this check.
Removing the independent WebSocket owner guard fails actual blocked-control
termination and stalled-attachment EOF checks before natural I/O expiry. Both
mutations were restored; no library or native-oracle source changes are included.
A live-process negative case verifies bounded observations still fail with owned
process/status/stack diagnostics. Neither this repair nor CI success promotes
endpoint/declaration coverage or closes task 3.9.

The first repair CI run exposed the same elapsed-observation weakness in the raw
blocked-write fixture. Raw owner-loss cases use bounded termination/EOF evidence;
the write-expiry case adds a delayed observer and traces socket send-timeout caps
against its configured stream lifetime. Oversized send-timeout mutation evidence
rejects a regression independently of scheduler timing; coverage stays partial.

## Incus helper namespace cleanup — 2026-10-14

The trusted host context and optional supervisor now live under `Opsmaru.Incus`.
Runtime changes are limited to module names and aliases; call semantics, passive
startup and host ownership remain unchanged. Repository references and the
isolated consumer adopt the new names. This compatibility change supplies no new
native endpoint evidence: task 3.9, all 21 partial endpoint pairs and declaration
gaps remain open with `complete_port=false`.

## WebSocket write-lifetime observation repair — 2026-10-14

Unix/TLS blocked-write fixtures now separate a delayed observer from write-budget
evidence. Local channel clock returns and socket-option traces verify each actual
timeout equals the remaining stream deadline capped by the request budget, with
timeout-close enabled. Deadline errors, normal channel termination and one GET
remain required; the permanent observer pause is 750 ms. Fixture streams last
three seconds against thirty-second request/peer lifetimes, with bounded process
observation. Enlarged-timeout and disabled-timeout-close mutations fail both
transports; runtime source was restored after each probe. Native behavior/oracle,
declaration statuses, endpoint gaps and the task 3.9 completion gate are unchanged.

## Native operation-wait evidence — 2026-10-15

`test/native_wait_reference_test.exs` extends both GetOperationWait and
GetOperationWaitSecret without changing the typed API or polling Operation.wait.
Twenty differential comparisons reuse the unchanged pinned Go driver over Unix
and verified mutual HTTPS: finite timeout 0/1, project/member queries, ETags,
operation identity, running/success/failure snapshots, HTTP 403 and premature EOF.
The fixture gates the body after headers, matching the pinned server's header
flush before op.Wait. Release is explicit; running snapshots model the response
at server timeout rather than prove a live daemon's waiting implementation.

Twelve independent stalled-body cases verify local deadline, explicit context
cancellation and caller loss with actual peer EOF, one wait GET and no replay or
DELETE. Pre-dispatch checks reject timeout=-1 and canceled contexts without I/O;
hex-secret error Inspect output is redacted. Finite observation windows are
separate from local request deadlines; no elapsed success threshold is asserted.
Arbitrary/empty-secret encoding, cluster forwarding, exhaustive timeout/error
matrices and real-daemon acceptance remain open. This supersedes the selected
manifest's earlier blanket blocking/lifetime evidence gap only within that
fixture scope. Both wait methods and their interface mappings, plus the endpoint
pair, stay partial: 1239 partial declarations, 41 missing, 21 partial pairs,
`inventory_complete=false`, `complete_port=false`; task 3.9 remains open.

### B02 core inspection — approved and fixture-verified

The remaining ten initial read contracts are now covered by core_inspection_v1:
nine named Go reads and connect/2 discovery. The shared inspection fixture uses
fixed expected fields before native DTO comparison; native defaults in nested
state memory are supplied explicitly. Operation groups flatten to an ID-sorted
comparison, preserving native unspecified cross-group order. Discovery uses
unchanged RawQuery transport with discovery disabled in the Go driver; local
required-field and API-version guards are independent evidence, not GetServer
DTO parity. Minimal valid discovery retains required fields rather than accepting
an empty server. Getter ETags and independent list-header retention are separate.

All ten contracts cover both Unix and mutual HTTPS, native permission/absence,
byte/readiness bounds and deadline/cancellation with peer EOF. Existing ten
inspection and eight mutation scopes remain visible. Progress is 18 -> 28 scoped
contracts inside the same 36 partial rows. B02's additional selectors/types/fields/
errors remain in the backlog; no whole endpoint, declaration or task is promoted.

#### B02 receive-timeout follow-up

PR #15's first CI attempt passed Ubuntu, but macOS exposed :response where the
HTTPS stalled read required :deadline. The approved narrow follow-up fixes only
Mint receive-timeout classification; deadlines/budgets and strict assertions are
unchanged. A deterministic regression on both transports suspends the test-owned
outer observers, traces the real Mint timeout and receive result, and verifies
GET/HEAD deadline, POST uncertainty, peer EOF, early EOF as response failure and
one request per call. The regression failed on both transports before the fix;
no flaky-run retry was used as evidence. core_inspection_v1 requires this separate
receive_expiry anchor. Whole endpoint/declaration/task statuses remain unchanged.

The expanded negative evidence matrix retains every case without raising its
timeout: source test names are parsed once per file per validation, while each
row/anchor is checked separately and subsequent calls reread source. A source-drift
regression protects those boundaries. This is test-support bookkeeping, with no
additional transport change or scope promotion.

#### Test-only YAML atom-safety stabilization

The user-approved follow-up retains all 200 atom probes across twenty ten-key
successful decodes, with exact expected maps and pre/post atom absence. It avoids
requiring a single large document to finish inside a wall-clock parser cap under
CI load. No rejection is accepted as success, no retry or timeout increase is
introduced, and parser/oracle code and all production limits are unchanged. The
remaining YAML subset and declaration gaps stay open.

Resource-sensitive YAML fixtures run serially so native large-document acceptance
and elapsed assertions do not compete with other async fixture suites. Actual
worker tracing and message cleanup remain; parser budgets, success assertions and
test timeouts are unchanged. This scheduling change adds no parser capability.

## B03 completion records, native wait and events (PR 1)

Approved 2026-10-19. This is the first slice to promote endpoint rows. Two rows
and one stream contract are complete under reviewed records in
`priv/incus/endpoint-inventory.json`. Task 3.9, global `behavior_complete`,
`complete_port` and every Go declaration (1239 partial / 41 missing) are unchanged.

- [x] Native wait: `GetOperationWaitSecret` now rejects empty, non-lowercase-hex
  or oversized secrets before I/O. Previously an empty secret was silently dropped,
  turning the call into a plain wait; `GetPrivateImage` keeps its existing
  empty-secret behavior. Named-Go comparisons add 404 absence, the cancelled (401)
  snapshot and connection loss before headers (one GET, `:response`, no replay);
  preflight adds 3601, string and float timeouts, and 3600 is accepted.
- [x] Events: the pinned `eventselectors` driver compares GetEvents, ByType,
  AllProjects and AllProjectsByType upgrade targets and populated/minimal Event
  fields over Unix and mutual HTTPS. Unknown types are forwarded and the native
  400 is preserved. Native 403/404 are also compared, and a rejection is never
  retried. Because `all-projects` suppresses `project` (as in the pinned client),
  the server's project-conflict 400 cannot be produced by either client.
- [x] The listener and explicit-send matrices run on both transports with actual
  peer-closure assertions. `WebSocketFixture` gained a loopback mutual-TLS mode
  and closure notification. Caller loss blocked in upgrade or write is covered on
  both transports. Inbound bounds: bytes coalesced with the 101 fail the open with
  `:frame_limit`; a later oversized frame ends with `:overflow`, and exceeding the
  stream byte budget ends with `:frame_limit`.
- [x] `EventListener.wait/2` now reports `:canceled` or `:deadline` when the
  connection's request context ended the listener, instead of `:listener_failed`.
  This holds whichever context watcher acts first: a read that fails because the
  channel's own watcher closed it also records the context's reason.
- [x] Review follow-up: `WebSocket.recv/2` waits for the channel's own answer
  (its read timer, or channel end) instead of a caller-side 100 ms margin.
  Previously a channel slowed past that margin (seen on macOS CI over TLS)
  reported false `:channel_closed` and killed the listener; an interim fix that
  kept the request outstanding could leave a late reply for a catch-all handler
  to discard, stalling reads and losing the frame. Both are covered by tests on
  Unix and mutual HTTPS. Completion selectors must carry a nonempty description.
- [x] PR 2: `POST /1.0/instances/{name}/exec` with S01 (see below). The operation
  WebSocket row stays partial while S02 (console) and S10 (copy/migration) are open.

## B03 exec with S01 (PR 2)

Approved 2026-10-19. `POST /1.0/instances/{name}/exec` is complete and S01 is
certified under `b03_exec_v1`. Task 3.9, global `behavior_complete`,
`complete_port` and every Go declaration (1239 partial / 41 missing) are unchanged.

- [x] The pinned `execio` driver gained submit and interactive modes. Named-Go
  comparisons over Unix and mutual HTTPS cover collected `Session.run`,
  `wait-for-websocket=false` via `Incus.call`, interactive PTY via `Session.exec`
  (channel 0 plus control, resize/signal frames decoded as `InstanceExecControl`),
  `record-output=true` submission, empty output with exit 0, and nonzero
  user/group/size with a nonempty cwd. Out-of-range resize/signal raise before
  any frame.
- [x] `container_exec_recording` and `container_exec_user_group_cwd` reject before
  dispatch through `call`, `exec` and `run`, with the pinned client's message.
  Native 400/403/404 match through `exec` and `run` with one POST each and no
  upgrade, poll or replay.
- [x] Upgrade targets match per channel by path and secret. The pinned
  `GetOperationWebsocket` sends only the secret; this client also sends the host
  `project`/`target`, which the pinned daemon's operation WebSocket handler ignores.
  By user decision (2026-10-19) this routing is maintained and recorded as an
  approved difference on `b03_exec_v1`.
- [x] Approved narrow fix: a request context that ends while a channel upgrade is
  pending is reported as `:deadline`/`:canceled` with the accepted operation, not
  `:stream_negotiation`. Previously the context watcher could win the race against
  the run guard (seen once over TLS). `WebSocket.open` reports the ended context
  and `Session.channels` propagates it. Regressions on both transports failed
  before the fix; budgets and timeouts are unchanged.
- [x] `:stream_negotiation` closes already opened channels and `:invalid_stream_metadata`
  rejects unsupported fds before any upgrade, both retaining acceptance. Pending
  exit status, missing channels and Session/Error Inspect redaction are covered.
- [x] Preflight, stdin chunking, blocked stdin, deadline/cancellation, owner loss,
  lost response/no replay, sink limits, running/failed completion and
  close/barrier/abrupt cases now also run over mutual HTTPS. On TLS the blocked
  write is confirmed in the TLS sender the channel waits on. Only the Unix
  fixture peer shrinks its receive buffer while gated. TLS peers keep default TCP
  buffers, because shrinking an established Linux 6.x TCP socket clamps its window
  for good, and the blocked TLS write uses 32 MiB of stdin to exceed autotuned
  buffers (reproduced on kernel 6.12).
- [x] Same race during collection: when a request context ends, its watchers stop
  the exec channels, and if that happened before the collection guard fired,
  collection reported `:exec_output_protocol` (seen once on macOS over TLS). A
  channel that stops while the request context has ended now reports that
  context's `:deadline`/`:canceled`. A guard-suspended cancellation regression on
  both transports failed before the fix.
- [x] Negative validator tests reject a removed exec case, transport or evidence
  kind, unlinked evidence, unclassified selectors, unapproved exclusions or
  differences, reopened or misattributed S01 and a partial selected exec row.

## B01 mutation and B04 instance PATCH completion

Approved 2026-10-19. Eight single-method rows are complete under reviewed
records with three new kinds: `async_mutation` (six rows), `sync_cancellation`
(`DELETE /1.0/operations/{id}`) and `conditional_patch` (`PATCH /1.0/instances/{name}`).
`POST /1.0/instances` stays partial while S06 and S10 are open. Task 3.9,
`complete_port` and every Go declaration status (1239 partial / 41 missing) are
unchanged.

- [x] Every `InstancePut` field (architecture, config, devices, ephemeral,
  profiles, stateful, description), stateful and `disk_only` restore, every
  `InstanceStatePut` action (start, stop, restart, freeze, unfreeze) with
  timeout, force and stateful, and `InstanceSnapshotsPost` with `expires_at` are
  compared with the named Go methods over Unix and mutual HTTPS, each through an
  accepted operation to completed and cancelled `/wait` snapshots.
- [x] The cancelled (401) snapshot joins running/completed/failed for every
  asynchronous lifecycle row.
- [x] `disk_only` restore without `instance_snapshot_disk_only_restore` and
  `expires_at` without `snapshot_expiry_creation` are rejected before dispatch,
  as the pinned client refuses them; with the extension the field is sent.
- [x] The validator now derives required cases from the method catalogue: a body
  requires `body_fields`, guarded fields require `extension_guards`, and a PUT or
  conditional method requires `etag`. The existing exec record gained its
  `body_fields` case. Negative tests cover each derived case, unlinked evidence,
  an unapproved PATCH exclusion and completing instance creation while its
  stream contracts are open.
- Approved exclusions (2026-10-19): cluster forwarding for all eight rows, and
  unconditional PATCH (rejected before I/O). PATCH evidence remains RawQuery
  transport comparison, distinct from named-Go and daemon merge evidence.

## B02 inspection completion (PR 1)

Approved 2026-10-20. Ten B02 rows are complete under reviewed `read_contract`
records: discovery, images, image, instances, instance, snapshots, snapshot,
state, operations and operation. The other ten B02 rows (projects, profiles,
networks and storage) follow in PR 2. Task 3.9, `complete_port` and every Go
declaration status (1239 partial / 41 missing) are unchanged.

- [x] All 27 methods mapped to these rows, not just the 9 core methods, are
  compared with the named Go method over Unix and mutual HTTPS through the
  data-driven inspection contract test: names, project-grouped names, list,
  full (`InstanceFull`, recursion=2), filter and all-projects variants, and
  `GetPrivateImage` with its secret. Each covers populated, empty and corrupt
  results, native 403/404, routing and binding, declared extensions before
  dispatch, response and readiness bounds, and deadline/cancellation cleanup.
- [x] All-projects variants omit `project`, matching the pinned client. Nested
  results are compared field by field at every depth, allowing only the
  zero-valued fields the Go DTO adds.
- [x] `GetOperationUUIDs` follows the daemon's status-grouped response, which the
  pinned Go method cannot decode (approved difference, user decision 2026-10-21).
  A flat list stays accepted and is compared with the pinned client.
- [x] The validator adds the `read_contract` kind. Required cases now also derive
  `extension_guards` from a method's top-level extension, `selectors` from
  filter/all-projects/instance-type queries, and discovery guards from the
  `connect` helper. Negative tests cover each.
- Approved exclusions (2026-10-20): names-only filter/all-projects selectors,
  the `?public` views and cluster forwarding.

## B02 inspection completion (PR 2)

The remaining ten B02 rows are complete under reviewed `read_contract` records:
projects, project, profiles, profile, networks, network, storage pools, pool,
volumes and volume. All twenty B02 rows are now complete. Task 3.9,
`complete_port` and every Go declaration status (1239 partial / 41 missing) are
unchanged.

- [x] All 32 methods mapped to these rows are compared with the named Go method
  over Unix and mutual HTTPS through the inspection contract test (59 methods
  plus discovery in total): names, filter and all-projects variants, the
  recursion=2 `StorageVolumeFull` list variants, `GetStoragePoolVolumeFull`
  and project-grouped volume URLs (`GetStoragePoolVolumeNamesAllProjects`).
  Volume names keep their `type/name` path, as in the pinned client.
- [x] Names methods reject a status-grouped map; only `GetOperationUUIDs`
  accepts one (approved difference).
- Source gap recorded on `b02_storage_volumes_v1`: the recursion=2 full-volume
  methods use a recursion level the pinned `rest-api.yaml` does not document for
  the volumes collection. They are certified with the row but not listed as
  documented manifest variants.
- Approved exclusions (2026-10-20): names-only filter/all-projects selectors and
  cluster forwarding.

## B09 network completion (PR 1: reads)

Approved 2026-10-21. Twenty B09 network read rows are complete under reviewed
`read_contract` records and join the selected manifest, which grows from 37 to
57 pairs: ACLs, address sets, allocations, integrations, zones and records,
and per-network forwards, leases, load balancers (including state), peers and
state. Their 31 write rows follow in PR 2, and `GET /1.0/metrics` and the ACL
log stay partial while S07 is open. Task 3.9, `complete_port` and every Go
declaration status (1239 partial / 41 missing) are unchanged.

- [x] All 32 B09 read methods are compared with the named Go method over Unix
  and mutual HTTPS through the inspection contract test (91 methods plus
  discovery in total), covering populated, empty and corrupt results, native
  403/404, routing, binding, applicable ETags, declared extensions before
  dispatch, bounds, readiness and deadline/cancellation cleanup.
- [x] New models use a schema-driven sample generator over `models.json`: every
  field gets a typed non-zero value and nested structs, pointers, lists and maps
  recurse. Existing hand-written samples are unchanged. Generated corrupt
  samples break a string field, or a collection field where the model has none.
- [x] `GetNetworkState` and `GetNetworkLoadBalancerState` return no ETag in the
  pinned client; the client still reports the native header, and ETags are
  compared only where the pinned method returns one.
- Approved exclusions (2026-10-21): `filter`/`all-projects` selectors the pinned
  client does not send (names-only views, and recursion views without a filtered
  method) and cluster forwarding.

## B09 network completion (PR 2: writes)

The 31 B09 synchronous write rows (create, rename, update and delete for
networks, ACLs, address sets, integrations, zones and records, forwards, load
balancers and peers) are complete under reviewed `sync_mutation` records and
join the selected manifest (57 -> 88 pairs). With PR 1, 51 of the 53 B09 rows are
complete; `GET /1.0/metrics` and the ACL log stay partial while S07 is open. Task
3.9, `complete_port` and every Go declaration status (1239 partial / 41 missing)
are unchanged.

- [x] A new data-driven `sync_mutation_contract_test.exs` compares each write with
  the named Go method over Unix and mutual HTTPS: schema-generated request bodies
  (via the shared `ModelSamples` generator), path escaping, project/target
  routing, PUT If-Match ETags, native synchronous success and 400/403/404/409/412.
  Lost and malformed replies are `:uncertain` after exactly one request.
- [x] Preflight rejects invalid bodies, unready hosts and every missing declared
  extension before dispatch. A non-local peer type without `network_integrations`
  is refused before dispatch, as the pinned client refuses it; a local peer
  needs no integration extension.
- [x] The validator adds the `sync_mutation` kind, with negative tests for removed
  base and ETag cases, a missing guard evidence kind and a wrong record kind.
- Approved exclusion (2026-10-21): cluster forwarding. Real-daemon network effects
  remain separately recorded.

## B10 administrative completion (PR 1: reads and root discovery)

Approved 2026-10-22. Fifteen B10 rows are complete under reviewed `read_contract`
records and join the selected manifest (88 -> 103 pairs): root discovery,
certificates, cluster, cluster groups and members (including member state),
metadata configuration, project access and state, resources and warnings. The
25 write rows follow in PR 2. Task 3.9, `complete_port` and every Go declaration
status (1239 partial / 41 missing) are unchanged.

- [x] New typed `GetAPIVersions` REST descriptor for `GET /`, which the pinned
  client lacks. The client now accepts exactly `/` as a request path and sends it
  without project or target, as the daemon serves it. Evidence compares unchanged
  Go RawQuery on both transports plus independent populated, empty, corrupt,
  403/404, bound, readiness and lifetime cases. Confirmed typed implementation
  gaps fall from 32 to 31.
- [x] All 20 B10 read methods are compared with the named Go method over Unix and
  mutual HTTPS through the inspection contract test (111 methods plus discovery
  and root discovery in total).
- [x] The shared `ModelSamples` generator now covers timestamps, floats, `uint16`,
  maps keyed by named string types and alias models (`Access` is a list,
  `MetadataConfig` a nested map). Samples are populated at every depth (no
  generated collection is empty); the one self-referencing field, a GPU card's
  SR-IOV `vfs`, is left out rather than sent empty. List-shaped models answer
  `:empty` with `[]`; corrupt samples break the first field whatever its type.
  Comparisons still require every sent field, with no empty-collection exception.
- Approved exclusions (2026-10-22): names-only `filter` (certificates, cluster
  members) and cluster forwarding.


## B10 administrative completion (PR 2: writes)

Approved 2026-10-22. The 25 B10 write rows (server, certificates, cluster,
cluster certificate, groups and members, member state, profiles, projects and
warnings; 28 methods, 5 of them asynchronous) are complete and join the selected
manifest (103 -> 128 pairs). All 40 B10 rows are now complete. Task 3.9,
`complete_port` and every Go declaration status (1239 partial / 41 missing) are
unchanged.

- [x] `sync_mutation_contract_test.exs` now covers 59 write methods. Each
  synchronous write is compared as in B09; an unset `force` flag is also compared
  (no force query). Each asynchronous write is compared with the named Go method
  through acceptance, operation binding and native `/wait` running, completed,
  failed and cancelled snapshots, then local deadline and cancellation of the wait
  with the handle unchanged. Unusable acceptance keeps the operation identity and
  is never replayed.
- [x] Guarded fields reject before dispatch, compared with the pinned client:
  each cluster join field without `clustering_join`, `failure_domain` without
  `clustering_failure_domains`, and `CreateCertificateToken` with `token: false`.
- [x] The trust-token bootstrap (`POST /1.0/certificates?public`) is certified:
  discovery reports `auth: "untrusted"`, and `CreateCertificate` with a
  `trust_token` body is sent and answered (success and native 403) as in the
  pinned client on both transports.
- [x] Four rows whose every method is asynchronous use `async_mutation` records.
  The mixed `POST /1.0/certificates` row stays `sync_mutation`; the validator
  derives the acceptance and `/wait` cases for any `sync_mutation` record that
  lists an operation-returning method, with negative tests.
- Approved exclusion (2026-10-22): cluster forwarding. Real-daemon administrative
  effects remain separately recorded.

## B05 PATCH completion (PR 1: existing and administrative PATCH)

Approved 2026-10-23. Eleven B05 rows are complete under reviewed
`conditional_patch` records: the four earlier descriptors (`PatchProject`,
`PatchProfile`, `PatchImage`, `PatchInstanceSnapshot`) and seven new REST
descriptors for server, certificate, cluster group, cluster member, image alias,
instance metadata and warning PATCH. The selected manifest grows 128 -> 135 pairs
(133 complete), and confirmed typed implementation gaps fall 31 -> 24. The nine
network and four storage PATCH rows follow in PR 2. Task 3.9, `complete_port` and
every Go declaration status (1239 partial / 41 missing) are unchanged.

- [x] Each new descriptor takes the path arguments, body model, extension and
  field guards of its pinned PUT counterpart. The pinned client has no PATCH
  method, so a new data-driven `patch_contract_test.exs` compares every B05
  method with unchanged Go RawQuery over Unix and mutual HTTPS. It covers empty,
  one-field, every-field (schema-generated), cleared (every field `false`, empty
  or zero), explicit-null and unknown-field bodies, path escaping, If-Match, routing, native empty sync success and native
  400/403/404/412.
- [x] Instance snapshot PATCH is accepted as an operation and observed through
  native `/wait` running, completed, failed and cancelled snapshots, compared with
  the named Go `GetOperationWait`, with local wait deadline and cancellation.
- [x] Independent fixtures prove that lost, malformed and wrong-kind replies are
  uncertain after one PATCH, and that deadline and cancellation close the peer.
  Preflight before I/O rejects a missing, empty, oversized, duplicate or injected
  ETag (unconditional PATCH), an invalid body, empty path arguments, oversized
  requests, unready hosts, missing extensions and a guarded `failure_domain`.
- [x] The `conditional_patch` kind keeps its shared cases. `empty_sync`,
  `restore_rejection` (instance bodies) and the acceptance/`/wait` cases are
  derived from each method, with negative tests; the B04 record is unchanged.
- The daemon does not check If-Match on warning PATCH; the ETag is still
  required and sent. Approved exclusions (2026-10-23): unconditional PATCH and
  cluster forwarding. Real-daemon merge semantics remain separately recorded.

## B05 PATCH completion (PR 2: network and storage PATCH)

Approved 2026-10-23. The remaining thirteen B05 rows are complete under reviewed
`conditional_patch` records, so all 24 B05 rows are complete. Thirteen new REST
descriptors cover network, ACL, address set, integration, zone, zone record,
forward, load balancer and peer PATCH, plus storage pool, bucket, custom volume
and custom volume snapshot PATCH. The selected manifest grows 135 -> 148 pairs
(146 complete), and confirmed typed implementation gaps fall 24 -> 11. Task 3.9,
`complete_port` and every Go declaration status (1239 partial / 41 missing) are
unchanged.

- [x] `patch_contract_test.exs` now covers all 24 B05 methods (192 tests) with the
  same RawQuery comparison, cleared-value bodies, failure, lifetime and preflight
  evidence as PR 1.
- [x] Volume and volume snapshot PATCH map the literal custom subtype
  (`catalogue_custom` rows with a recorded restriction). The evidence validator
  accepts a custom-subtype method only on its own documented `{type}` row, with
  negative tests.
- The daemon does not check If-Match on forward, load balancer, peer or bucket
  PATCH; the ETag is still required and sent. Network peer PATCH is certified as
  the daemon's full replace and documented. Approved exclusions (2026-10-23):
  unconditional PATCH, non-custom volume snapshot types and cluster forwarding.
  Real-daemon merge semantics remain separately recorded.

## B08 stream-free storage completion (PR 1: reads)

Approved 2026-10-24. Eleven stream-free B08 read rows are complete under
reviewed `read_contract` records: buckets, bucket, bucket keys, bucket key, pool
resources, volumes by type, bitmaps, bitmap, volume snapshots, volume snapshot
and volume state. They map 25 methods. The selected manifest grows 148 -> 159
pairs (157 complete), and confirmed typed implementation gaps fall 11 -> 9. The
17 stream-free write rows follow in PR 2. Task 3.9, `complete_port` and every Go
declaration status (1239 partial / 41 missing) are unchanged.

- [x] Four new REST descriptors cover reads the pinned client lacks:
  `GetStoragePoolVolumeTypeNames`, `GetStoragePoolVolumesByType` and
  `GetStoragePoolVolumesByTypeFull` for `GET /volumes/{type}`, and
  `GetStorageVolumeBitmap`. The inspection contract test compares them with
  unchanged Go RawQuery on both transports. The independent cases are
  populated, empty, corrupt, 403/404, bound, readiness and lifetime.
- [x] The 21 named read methods are compared with the pinned client through the
  inspection contract test (132 named methods plus discovery, root discovery and
  the four storage REST reads). Schema-driven samples cover bucket, bucket key,
  pool resource, bitmap, volume snapshot and volume state models.
- [x] The volume type is a pass-through path argument. Every method that takes
  one is also compared for custom, container, virtual-machine and image volumes,
  so no volume type exclusion is recorded.
- Approved exclusions (2026-10-24): `filter` and `all-projects` on the
  names-only bucket view, and cluster forwarding. The collection volume POST is
  deferred to the stream-linked volume create row.

## B08 stream-free storage completion (PR 2: writes)

Approved 2026-10-24. The 17 stream-free B08 write rows are complete:

- 13 under `sync_mutation` records and 4 under `async_mutation` records
- pools: create, update and delete
- buckets: update and delete
- bucket keys: create, update and delete
- volumes: update and delete
- bitmaps: create and delete
- volume snapshots: create, rename, update and delete
- volumes: rebuild

With PR 1, 28 of the 29 stream-free B08 rows are complete. The collection volume
POST stays partial until it is reconciled with volume create. The selected
manifest grows 159 -> 176 pairs (174 complete). Task 3.9, `complete_port` and
every Go declaration status (1239 partial / 41 missing) are unchanged.

- [x] `sync_mutation_contract_test.exs` now covers 76 write methods. Each storage
  write is compared with the named Go method as in B09/B10. The four
  asynchronous writes add acceptance and native `/wait`. Every method that takes
  a volume type is also compared for custom, container, virtual-machine and
  image volumes.
- [x] `CreateStoragePoolBucketKey` answers with a schema-generated
  `StorageBucketKey`, compared field by field with the pinned DTO. A corrupt
  model leaves the write uncertain. An empty request model (rebuild) is rejected
  as a non-map body in preflight.
- [x] A volume `restore` without `storage_api_volume_snapshots` is refused before
  dispatch, as the pinned client refuses it.
- The pinned `UpdateStoragePoolVolumeSnapshot` uses `queryOperation` but accepts
  the daemon's empty synchronous reply, and so does the client. Approved
  exclusion (2026-10-24): cluster forwarding. Real-daemon storage effects remain
  separately recorded.

## B11 stream-free instance and image completion

Approved 2026-10-24. All 19 B11 rows without a stream contract are complete:

- 5 read rows (6 methods) under `read_contract` records
- 9 synchronous writes under `sync_mutation` records
- 5 asynchronous writes under `async_mutation` records (image refresh, image
  secret, instance rebuild, instance snapshot update and `UpdateInstances`)

The selected manifest grows 176 -> 195 pairs (193 complete). The 23
stream-linked B11 rows stay partial. Task 3.9, `complete_port` and every Go
declaration status (1239 partial / 41 missing) are unchanged.

- [x] The inspection contract test now covers 138 named methods. The B11 reads
  use schema-driven samples for image aliases, instance access and metadata.
- [x] The sync-mutation contract test now covers 90 write methods. The pinned
  `DeleteInstanceConsoleLog` takes an unused trailing argument, which the
  oracle passes from the catalogue's `oracle_trailing`. Every accepted write now also asserts that operation
  metadata (an image secret, for one) never appears in `Inspect` output.
- [x] `UpdateInstances` is certified as an ordinary asynchronous write
  (approved). Whether tools may expose it is a separate tool-policy decision.
- Approved exclusions (2026-10-24): the untrusted `?public` alias view and
  cluster forwarding. Real-daemon instance and image effects remain separately
  recorded.

## B07 recorded exec output and B12 debug repair

Approved 2026-10-25. The three B07 rows and the B12 row are complete. So is the
supplemental `POST /1.0/instances/{name}/debug/repair` server row. These are the
last stream-free rows apart from the deferred collection volume POST.

- The selected manifest grows 195 -> 199 pairs (197 complete).
- Confirmed typed implementation gaps fall 9 -> 5. The two B06 HEAD pairs and
  three bucket backup pairs remain.
- Task 3.9, `complete_port` and every Go declaration status (1239 partial / 41
  missing) are unchanged.

- [x] `GetInstanceExecOutputNames` and `DeleteInstanceExecOutput` are REST
  descriptors, compared through unchanged Go RawQuery on both transports. The
  delete rejects empty, `.`, `..` and slash names before dispatch.
- [x] `Streams.instance_exec_output/4` streams one recorded file to an
  acknowledged sink. A new `binary_download` record kind covers it. Its
  independent fixtures prove:
  - the exact path and routing, with no implicit delete
  - native 400/403/404
  - the byte bound, deadline, and cancellation both before and mid-stream (the
    sink is never called again and the peer sees the socket close)
  - unsafe names and a missing extension rejected before I/O
- [x] `RepairInstance` sends the daemon's registered POST, compared through Go
  RawQuery. The documented GET row lists it through an approved reconciliation,
  with its GET view excluded (never sent). The validator now completes a
  supplemental server row only through that record, and the evidence validator
  accepts a manifest row's `server_route` only when it is a registered server
  route. Negative tests cover both.
- [x] The write harness gains a RawQuery path for REST-only writes, with fixed
  native paths.
- Approved exclusion (2026-10-25): cluster forwarding. Real-daemon recorded
  output and repair effects remain separately recorded.

## S07 auxiliary byte stream certification

Approved 2026-10-26. Stream contract S07 is certified by the single reviewed
record `s07_byte_streams_v1`. That record completes the 8 rows linked only to
S07:

- metrics
- network ACL log
- instance log file
- console log
- debug memory
- metadata templates: list, download, upload and delete

The selected manifest grows 199 -> 207 pairs (205 complete), and the certified
stream contracts are now S01, S03 and S07. Task 3.9, `complete_port` and every
Go declaration status (1239 partial / 41 missing) are unchanged.

- [x] A new `byte_stream_contract_test.exs` runs every S07 helper on Unix and
  mutual TLS against the pinned streams driver. The fixture requires a client
  certificate, which the streams driver now presents:
  - request path, exact selectors (`path`, `format`) and project/target routing
  - the bytes delivered to an acknowledged sink
  - template upload body bytes and content type
  - native 400/403/404 with one request on each side
  - byte, chunk and deadline bounds
  - mid-stream cancellation and caller loss: the peer sees the socket close
    and the sink is never called again
  - a lost upload reply is uncertain and never replayed
- [x] The template list (`GetInstanceTemplateFiles`, a strings result) and delete
  (`DeleteInstanceTemplateFile`) join the inspection and sync-mutation contract
  tests. A new `byte_stream` record kind names the S07 cases. Negative tests
  remove the caller-loss case and the stream link.
- Approved exclusions (2026-10-26): the console `type` selector and cluster
  forwarding. Real-daemon stream contents remain separately recorded.

## S04 file transfer certification with B06 HEAD

Approved 2026-10-26. Stream contract S04 is certified by the single reviewed
record `s04_file_transfer_v1`. That record completes all 8 S04 rows:

- instance files: read, create, delete and HEAD
- custom volume files: read, create, delete and HEAD

The two HEAD rows were the B06 gaps.

- The selected manifest grows 207 -> 215 pairs (213 complete).
- Confirmed typed implementation gaps fall 5 -> 3, leaving only the bucket
  backup pairs.
- The certified stream contracts are now S01, S03, S04 and S07.
- Task 3.9, `complete_port` and every Go declaration status (1239 partial / 41
  missing) are unchanged.

- [x] New `Files.head/3` and `Files.volume_head/5` send a native HEAD
  (`Transfer.head/3`). They return parsed metadata (owner, group, mode, type,
  modification time and, for files, size) through the shared `FileHeaders`
  parser, which is already compared with the pinned header parsing. A HEAD
  rejection keeps its HTTP status. A response with body bytes, an early close
  and invalid metadata fail with their own kind (`:transfer`,
  `:invalid_file_headers`), never `:uncertain`. A handler's own error now keeps
  its kind for reads too.
- [x] A new files reference driver invokes the pinned `GetInstanceFile`,
  `CreateInstanceFile`, `DeleteInstanceFile`, `GetStorageVolumeFile`,
  `CreateStorageVolumeFile` and `DeleteStorageVolumeFile` over Unix or mutual
  TLS.
- [x] `file_transfer_contract_test.exs` runs every S04 operation on Unix and
  mutual TLS (the fixture requires a client certificate). It covers:
  - instance files and all four volume types
  - file, directory and symlink reads (bytes, entries and metadata)
  - creates with type, write mode, uid, gid and mode headers
  - deletes, including a lost reply that is never replayed
  - HEAD metadata with no body
  - native 400/403/404
  - byte and upload bounds and the deadline
  - mid-stream cancellation and caller loss
  - extension guards and invalid options rejected before I/O

  Breaking the mode header encoding made the create comparison fail, so the
  test does catch header errors. A new `file_transfer` record kind names the
  cases, with negative tests.
- Approved exclusions (2026-10-26): agent-mode file access and cluster
  forwarding. Real-daemon file effects remain separately recorded.

## S06 backup and archive certification (PR 1: backup control plane)

Approved 2026-10-26. PR 1 adds contract evidence for the S06 backup control
plane. No row completes and S06 stays open until PR 2 adds the archive streams
and certifies it. Task 3.9, `complete_port` and every Go declaration status
(1239 partial / 41 missing) are unchanged.

- [x] Four REST descriptors cover bucket backup calls the pinned client lacks:
  `GetStoragePoolBucketBackupNames`, `GetStoragePoolBucketBackups`,
  `GetStoragePoolBucketBackup` and the asynchronous
  `RenameStoragePoolBucketBackup`. The three missing-typed rows become
  `catalogue`, so no confirmed typed implementation gap remains (3 -> 0).
- [x] The inspection contract test now covers 145 named methods plus the
  bucket backup REST reads, with fixed native paths. It includes instance and
  custom volume backup names, lists and gets.
- [x] The sync-mutation contract test now covers 103 write methods. It adds:
  - instance and custom volume backup create, rename and delete
  - bucket backup create and delete
  - the REST bucket backup rename
  - JSON bucket creation

  Bodies are schema-driven, and accepted operations use native `/wait`. The
  pinned `CreateStoragePoolBucket` returns the created key only with
  `storage_buckets_create_credentials`, so the fixture advertises it. For
  REST-only writes, `RawQuery` decodes no operation; only named methods also
  reject an unusable acceptance.
- Approved exclusion: cluster forwarding. Export, direct backup POST, imports,
  ISO and the certification of all 19 rows follow in PR 2.

## S06 backup and archive certification (PR 2: archive streams)

Approved 2026-10-26. Stream contract S06 is certified by the single reviewed
record `s06_archives_v1`. That record completes all 19 S06 rows:

- instance, custom volume and bucket backups: list, get, create, rename,
  delete and export
- bucket creation, whose archive mode is bucket import

It also certifies the import modes of the two rows shared with S10: instance
backup import on `POST /1.0/instances` and volume and ISO import on
`POST /1.0/storage-pools/{pool}/volumes/{type}`. Those rows stay partial until
S10 is certified.

- The selected manifest grows 215 -> 234 pairs (232 complete).
- The certified stream contracts are now S01, S03, S04, S06 and S07.
- Task 3.9, `complete_port` and every Go declaration status (1239 partial / 41
  missing) are unchanged.

- [x] A new archives reference driver invokes the pinned
  `GetInstanceBackupFile`, `GetStorageVolumeBackupFile`,
  `GetStoragePoolBucketBackupFile`, the three `*BackupStream` methods,
  `CreateInstanceFromBackup`, `CreateStoragePoolVolumeFromBackup`,
  `CreateStoragePoolVolumeFromISO` and `CreateStoragePoolBucketFromBackup` over
  Unix or mutual TLS.
- [x] `archive_contract_test.exs` runs every archive helper on Unix and mutual
  TLS (the fixture requires a client certificate). It covers:
  - export bytes for instance, bucket and all four volume types
  - direct backup POST with schema-generated bodies, sent as the pinned client
    normalizes them
  - instance import with name, pool, config and device overrides (including
    empty overrides), volume, ISO and bucket import, comparing headers, bytes
    and the accepted operation
  - routing with and without a target
  - native 400/403/404
  - byte and upload bounds and the deadline
  - mid-stream cancellation and caller loss for exports and direct POST
  - lost import and direct backup replies that are uncertain and never resent
  - no implicit host files
  - extension guards, the ISO name and invalid or oversized bodies rejected
    before I/O

  Renaming the pool override header made the import comparison fail, so the
  test does catch header errors. The pinned volume methods address only custom
  volumes, and the pinned instance and bucket exports and every pinned direct
  backup POST omit the target; those cases are fixture-checked. Canceling a
  direct backup POST is uncertain, like every canceled mutation.
- [x] The control plane keeps its PR 1 evidence in the inspection and
  sync-mutation contract tests. A new `archive` record kind names all cases,
  with negative tests. Export, direct POST and import helpers are linked to
  their rows.
- Approved exclusion (2026-10-26): cluster forwarding beyond host project and
  target routing. Real-daemon archive contents and restores remain separately
  recorded.
