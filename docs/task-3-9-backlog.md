# Task 3.9 finite closure backlog

Audited at Incus v7.0.1 `13f3992766142d5087fff2e362cd2e1a75294fe8`
after merged PR #13 (`8e9ce89`), with B01 bounded mutation lifecycle and B02 core inspection evidence added. The authoritative classified rows are in
[`endpoint-inventory.json`](../priv/incus/endpoint-inventory.json). This is a
classified backlog, updated with bounded implementation evidence; it does not claim behavioral completion.

## Inventory result

All **247 documented endpoint/method pairs** and **293 operation views** are
classified: 46 views are additional query/access variants, including ten public
access views. `?public` documents untrusted/public behavior; it is not an invented
wire selector. All **273 catalogue descriptors** map to these rows. No documented
pair or view is left unclassified.

| Classification | Pairs | What still needs closing |
| --- | ---: | --- |
| Exact JSON catalogue mapping | 188 | Certify a finite supported contract, reusing existing native fixtures. |
| Custom-volume-only catalogue mapping | 5 | Certify native custom-only backup scope; the server rejects other backup subtypes. |
| Explicit discovery/binary/upgrade helper | 22 | Certify the helper's finite options, streams, errors and cleanup. |
| Missing typed implementation | 30 | Implement and verify, or obtain an explicit user-approved exclusion. |
| Equivalent volume collection POST | 1 | Same native handler as typed-volume POST; certify supported route/body behavior or resolve scope. |
| Incorrect documented GET repair | 1 | Retain the source discrepancy; actual mutation is POST, below. |
| **Documented total** | **247** | No classification is a completion claim. |

The standard Go AST extractor accounts for **246 public v1.0 registered pairs**,
including image suffix actions. Root discovery is a separately checked source
anchor in `cmd/incusd/api.go:restServer`. All documented routes reconcile except
`GET /1.0/instances/{name}/debug/repair`: `instances.go:instanceDebugRepairCmd`
registers **POST**. One supplemental server row tracks that missing typed mutation.
Thus there are **no remaining confirmed typed implementation gaps** (root discovery `GET /`
now has the typed `GetAPIVersions` descriptor), plus the equivalent
collection-route decision. These are not a count of missing Go declarations. Raw HTTP support does not implement those typed contracts.
No source file in the pinned module was modified.

## Exact implementation backlog

- **None remain.** The last three, bucket backup list/get/rename (B08), have
  typed REST descriptors (S06 PR 1, 2026-10-26) and are complete under
  `s06_archives_v1` (S06 PR 2). Custom-volume backup methods already existed.

The corrected per-view parameter audit identifies **28 distinct endpoint/selector
gaps across 20 implemented routes**. The original route-wide check reported nine:
it incorrectly borrowed filter/all-projects support from other recursion views.
There are 38 affected documented operation/selector views on these routes; public
and recursion views can repeat an endpoint/selector obligation. The two file HEAD
`path` selectors add two more views but already overlap B06's missing methods.

| Implemented endpoint | Unmapped selector in at least one documented view | Backlog |
| --- | --- | --- |
| `GET /1.0/certificates` | `filter` | B10 |
| `GET /1.0/cluster/members` | `filter` | B10 |
| `GET /1.0/images` | `all-projects`, `filter` | B02 |
| `GET /1.0/instances` | `all-projects`, `filter` | B02 |
| `GET /1.0/instances/{}/console` | `type` | B11 |
| `GET /1.0/network-acls` | `all-projects`, `filter` | B09 |
| `GET /1.0/network-address-sets` | `all-projects`, `filter` | B09 |
| `GET /1.0/network-integrations` | `filter` | B09 |
| `GET /1.0/network-zones` | `all-projects`, `filter` | B09 |
| `GET /1.0/network-zones/{}/records` | `filter` | B09 |
| `GET /1.0/networks` | `all-projects`, `filter` | B02 |
| `GET /1.0/networks/{}/forwards` | `filter` | B09 |
| `GET /1.0/networks/{}/load-balancers` | `filter` | B09 |
| `GET /1.0/networks/{}/peers` | `filter` | B09 |
| `GET /1.0/operations` | `all-projects` | B02 |
| `GET /1.0/profiles` | `all-projects`, `filter` | B02 |
| `GET /1.0/projects` | `filter` | B02 |
| `GET /1.0/storage-pools` | `filter` | B02 |
| `GET /1.0/storage-pools/{}/buckets` | `all-projects`, `filter` | B08 |
| `GET /1.0/storage-pools/{}/volumes` | `filter` | B02 |

Every operation view retains its exact methods and parameter classifications in
the full ledger. For example, names-only `GET /1.0/instances` lacks typed filter/
all-projects options; its recursion=1 methods support them. Implementing an option
on one view cannot close the other view's obligation. Host routing and explicit
helper queries are classified separately. Selector-compatible candidates do not
establish public access or body semantics. Copied verified scopes must exactly
match the selected evidence entries, including absence on unrelated rows.

No new exclusions are approved. Existing bounded implementations still need
contract certification; this count must not imply that only 32 tests or changes
remain, nor that every remaining method requires a new implementation.

## Endpoint batches and finite exits

These assignments partition the 247 documented rows exactly once; the extra
server POST is assigned to B12. Batch sizes are endpoint/method pairs, not
estimates of lines or commits. Split a batch into bounded slices before coding.

| Batch | Assigned documented pairs | Exit |
| --- | ---: | --- |
| B01: Initial mutation lifecycle | 8 | Seven single-method rows are **complete** under reviewed `b01_*` records: every body field/action, extension guards before dispatch, running/completed/failed/cancelled snapshots, ETags, native rejection and no replay on both transports; cluster forwarding is an approved exclusion. `POST /1.0/instances` stays partial while S06/S10 are open. |
| B02: Initial inspection certification | 20 | All twenty rows are **complete** under reviewed `b02_*` read records with every mapped method. Names-only filter/all-projects, `?public` views and cluster forwarding are approved exclusions; `GetOperationUUIDs` follows the daemon grouped response. |
| B03: Exec and operation channel/wait scope | 4 | Native wait (`b03_native_wait_v1`) and events with S03 (`b03_events_v1`) are complete; `?public`, arbitrary/empty wait secrets and cluster forwarding are approved exclusions (2026-10-19). Exec with S01 (`b03_exec_v1`) is complete; recorded-output retrieval, cluster forwarding, arbitrary producers and tool capture policy are approved exclusions (2026-10-19). The operation WebSocket row stays partial while S02/S10 are open. Recorded output belongs to B07. |
| B04: Instance PATCH contract certification | 1 | **Complete** (`b04_instance_patch_v1`): conditional InstancePut with caller ETag; unconditional PATCH and cluster forwarding are approved exclusions (2026-10-19). Daemon merge acceptance stays separate. |
| B05: Conditional PATCH and remaining PATCH contracts | 24 | All 24 rows are **complete** under reviewed `b05_*` conditional-PATCH records: the four earlier descriptors plus 20 new REST descriptors (server, certificate, cluster group/member, image alias, instance metadata, warning, nine network and four custom-volume storage PATCH), compared through Go RawQuery. Unconditional PATCH, non-custom volume snapshot types and cluster forwarding are approved exclusions (2026-10-23); network peer PATCH is certified as the daemon's full replace. PUT/raw-query success cannot close these rows. |
| B06: File metadata HEAD | 2 | Both rows are **complete** (2026-10-26) through the typed `Files.head/3` and `Files.volume_head/5` helpers under `s04_file_transfer_v1`. Original exit: Implement instance and volume metadata-only typed helpers with header fidelity, empty body, rejection and bounded cleanup evidence on both transports. |
| B07: Recorded exec output | 3 | All 3 rows are **complete** (2026-10-25): `GetInstanceExecOutputNames` and `DeleteInstanceExecOutput` REST descriptors (RawQuery evidence) and the `Streams.instance_exec_output/4` bounded download helper (`binary_download` record, independent fixtures); deletion is only explicit. Original exit: Implement typed list, acknowledged binary download and explicit delete. Verify identity/path isolation, missing output, bounds and uncertain deletion; never imply automatic deletion. |
| B08: Storage endpoint contracts | 49 | Eleven stream-free read rows are **complete** under reviewed `b08_*` read records (buckets, bucket keys, pool resources, volumes by type, bitmaps, volume snapshots and state), for every daemon volume type; list-by-type and the single bitmap read use new REST descriptors (RawQuery evidence). Names-only bucket selectors and cluster forwarding are approved exclusions (2026-10-24). The 17 stream-free write rows are also **complete** under `b08_*` sync- and async-mutation records (pools, buckets and keys, volumes, bitmaps, volume snapshots and rebuild), for every daemon volume type; the collection volume POST is deferred to volume create. Certify the exact catalogue/helpers for each remaining row; implement bucket backup list/get/rename. Reconcile equivalent collection POST, custom restrictions and recursion views; add evidence for declared fields/errors/lifetimes only. |
| B09: Network endpoint contracts | 53 | 51 rows are **complete**: twenty reads under `b09_*` read records and 31 synchronous writes under `b09_*` sync-mutation records, with every mapped method. Selectors the pinned client does not send and cluster forwarding are approved exclusions (2026-10-21). Metrics and the ACL log stay partial while S07 is open. PATCH rows remain B05. |
| B10: Administrative endpoint contracts | 40 | All 40 rows are **complete**: fifteen reads under reviewed `b10_*` read records, including root discovery through the new typed `GetAPIVersions` helper (RawQuery evidence), and 25 writes under `b10_*` sync- and async-mutation records, with the trust-token certificate bootstrap certified. Names-only filter and cluster forwarding are approved exclusions (2026-10-22). PATCH rows remain B05. |
| B11: Remaining instance/image contracts | 42 | All 19 stream-free rows are **complete** under reviewed `b11_*` read, sync- and async-mutation records (image aliases, image update/refresh/secret, instance access, logs, metadata, console log delete, bitmaps, rebuild, snapshot update and the project-wide `UpdateInstances`). The public alias view and cluster forwarding are approved exclusions (2026-10-24). The 23 stream-linked rows remain: Certify assigned instance/snapshot/backup/image/alias typed/helper scopes, including listed body modes. Verify supported fields/selectors, result/error/identity/ETag and bounds; copy/streams have additional S-contract obligations. |
| B12: Pinned source reconciliation | 1 | **Complete** (2026-10-25): the typed `RepairInstance` POST (RawQuery evidence) completes the documented GET row, whose GET view is an approved source discrepancy that is never sent, and the supplemental POST server row. Original exit: Keep the documented GET debug repair mismatch and actual POST registered route linked. Design a typed mutation contract against the server POST or obtain explicit scope approval; never implement a repair mutation as a GET. |

## Streaming and non-REST obligations

The twelve contracts below overlap endpoint batches: they are not another set of
routes to add to the denominator. Evidence already exists for each. Finish each
by enumerating its supported modes and linking existing checks, then implement or
verify only identified holes. OCI/SimpleStreams are public client behaviors beyond
the Incus REST document and remain in the completion gate.

| Contract | Remaining finite obligation | Boundary |
| --- | --- | --- |
| S01: Live exec | **Certified** by `b03_exec_v1`: collected, non-waiting, interactive PTY and record-output submission, user/group/cwd/size, extension guards, control frames and bounds, native rejection, channel failures, limits, lifetimes and peer closure on both transports. Recorded-output retrieval remains B07. | Bounded noninteractive collection plus interactive host-owned channels; no arbitrary producer or tool capture policy. |
| S02: Console | Enumerate supported static/dynamic attachment/control types and existing repeated-attachment/cleanup evidence; resolve remaining callback orchestration scope. | Host-owned streams and finite lifetimes. |
| S03: Events and callbacks | **Certified** by `b03_events_v1`: type/all-projects/target selectors, native rejection, Event fields, capacity/callback/owner/caller-loss, bounds and peer closure on both transports. | Explicit listener ownership; native callback order is unspecified. |
| S04: Files | **Certified** by `s04_file_transfer_v1` (2026-10-26): instance and volume file read/create/delete and the B06 HEAD helpers on both transports, every volume type. Agent-mode file access and cluster forwarding are approved exclusions. Original obligation: certify file/directory/symlink, uid/gid/mode, overwrite/append, path/routing, binary bounds and native failures; HEAD remains B06. | Acknowledged host sources/sinks; no implicit host files. |
| S05: Image binary handoff | Enumerate supported unified/split/compression/header/token modes; link existing private-token/copy/uncertainty evidence and identify uncovered cases. | Host-owned sources/sinks/staging; no implicit tools. |
| S06: Archives | **Certified** by `s06_archives_v1` (2026-10-26), completing all 19 S06 rows: instance, volume and bucket backup list/get/create/rename/delete/export, JSON bucket creation, direct backup POST and instance (name/pool/config/device), volume, ISO and bucket imports on both transports. The instance and volume import rows are shared with S10 and stay partial. Cluster forwarding is an approved exclusion. Original obligation: Enumerate instance/volume/bucket import/export/direct POST, name/pool/config/device and ISO modes; reconcile existing fixtures and remaining transport/failure evidence. | No implicit host filesystem state. |
| S07: Auxiliary byte streams | **Certified** by `s07_byte_streams_v1` (2026-10-26): metrics, ACL log, instance log file, console log, debug memory and metadata template list/download/upload/delete on both transports, with exact selectors, headers, native failures, byte/chunk/deadline bounds and mid-stream cancellation and caller-loss cleanup. The console `type` selector and cluster forwarding are approved exclusions. | Recorded output remains B07; repair remains B12. |
| S08: Raw SFTP/NBD | Certify instance/volume path, instance reuse and volume writable options, 101/coalesced bytes, half-close and bounds against existing evidence; retain approved oracle byte-loss difference. | Raw NBD payload protocol is caller-owned. |
| S09: Typed SFTP | Link existing v3 subset packet/status/fragment/bounds/owner/uncertainty evidence and explicit unsupported-operation rejection. | Approved init/extensions/open/read/write/close subset; no full pkg/sftp requirement. |
| S10: Copy/migration | PR 1 (2026-10-27) adds evidence for the migration control plane: instance, snapshot and custom volume rename and migration, volume creation as a copy or migration target and `CreateInstance` migration/copy sources, with every guard before dispatch, on both transports. Copy orchestration, relay, remote wait, the collection volume POST descriptor and certification follow in PR 2; no S10 row is complete yet. Original obligation: Enumerate existing local/pull/push/relay instance/snapshot/volume/image combinations, approved address/channel sets, remote wait and no-replay cleanup; resolve any unsupported options explicitly. | Host approves origins; preserve source and target identities; no following arbitrary addresses. |
| S11: OCI adapter | Map all public OCI behaviors to projection/cache/options/bounds/cleanup evidence and explicitly rejected methods. | Explicit host conversion/credentials/state; installed adapter acceptance separate. |
| S12: SimpleStreams | Map catalog selectors, checksum/full-file/delta, refresh/cache/fallback and unsupported methods to existing evidence; resolve uncovered modes. | Explicit verified HTTPS; optional host delta; no socket probe/HTTP downgrade/tool discovery; installed converter separate. |

## Certification rule and checklist

For each row, the finite starting scope is its listed named methods and their
catalogue query/body/model/result/extension/guard descriptors, or the exact
helper options in its source. Every documented operation view is a separate
obligation. A supported-contract record must name its methods, selectors,
body/result fields, subtype/mode and rejected variants; broader variants need
implementation/evidence or explicit user-approved exclusion. Do not silently
reduce the endpoint gate to whichever fixtures already pass.

Required cases are supported populated/empty results and field presence;
routing/identity and applicable ETags/extensions; native success and representative
permission/absence/conflict rejection; accepted/completed/failed/running behavior
where asynchronous; uncertainty without replay on possible dispatch; applicable
byte/lifetime/owner/cancellation cleanup. Cover Unix and verified mutual HTTPS.
Reuse existing tests and record whether evidence is named-Go differential,
RawQuery transport, independent protocol fixture or real-backend acceptance.
No exhaustive cross-product of every possible field/error is required.

- [x] Exhaustively classify documented pairs/views and catalogue mappings.
- [x] Reconcile public registrations, image suffixes, root, custom subtypes and repair verb.
- [x] Identify real missing implementations separately from missing evidence.
- [x] Assign all rows and twelve streaming contracts finite backlog obligations.
- [x] Preserve the ten fixture-verified inspection scopes and existing bounded slices.
- [ ] Finish B01–B12: implement/verify the required contracts or record explicit approvals.
- [ ] Finish S01–S12 certification within the existing approved host/protocol boundaries.
- [ ] Add reviewed completion records for finite contracts; classification alone cannot set behavior_complete. 232 rows (three B03, seven B01, B04, twenty B02, 51 B09, all forty B10, all 24 B05, 28 stream-free B08, nineteen stream-free B11, all three B07, B12, the eight S07 rows, the eight S04 rows, including both B06 rows, and the nineteen S06 rows) plus S01/S03/S04/S06/S07 are complete.
- [ ] Independently review and pass canonical/reference/platform/immutable-consumer checks for closing slices.

Installed OCI/delta converters, explicitly opted-in isolated real-Incus acceptance
and consumer-owned Macus hardware remain separate acceptance records. No automatic
acceptance run is authorized by this audit. Go declaration parity remains a
separate claim; no declaration status is promoted.

## Four-method progress and next priority

- [x] Add conditional PatchProject, PatchProfile, PatchImage and
  PatchInstanceSnapshot, with explicit nonempty caller ETag and existing Put models.
- [x] Preserve native empty synchronous success for project/profile/image and
  HTTP 202 asynchronous operation acceptance for snapshot expiry updates.
- [x] Parameterize Unix/mutual-HTTPS transport comparisons and independent
  preflight/rejection/uncertainty/deadline/cancellation cleanup evidence.
- [x] Reclassify four missing typed pairs (36 -> 32 actual implementation gaps),
  expand the selected partial evidence rows (32 -> 36) and retain declaration gaps.
- [x] Certify the four B05 scopes under reviewed records (2026-10-23): every
  schema field, explicit nulls, unknown fields and native 400/403/404/412.
  Unconditional variants and cluster forwarding are approved exclusions; daemon
  merge/expiry acceptance stays separately owned.

The fixture compares unchanged Go RawQuery, not named Go PATCH methods or daemon
merges. It keeps valid field presence without local read/merge/defaults. Image
PATCH evidence covers auto_update/public/properties only. Snapshot success is an
accepted handle, not completion. No endpoint or declaration is promoted to parity.

## B01 bounded lifecycle progress

- [x] Verify all eight existing B01 pairs, including separate instance update and
  snapshot-restore bodies, on Unix and verified mutual HTTPS.
- [x] Compose seven asynchronous pairs with native `/wait` running/success/failure
  snapshots, accepted identity, routing/binding, applicable PUT ETags and errors.
- [x] Verify synchronous cancellation acknowledgement, may_cancel=false denial,
  terminal completion race, native rejection and lost-reply identity without replay.
- [x] Record initial_mutation_lifecycle_v1 on exactly eight partial rows, with
  checked methods/cases/transports/evidence and copied full-ledger scopes.
- [ ] Verify broader body/source/state/extension/error/cluster variants or obtain
  explicit scope decisions; real-daemon lifecycle acceptance remains separate.

There are now 28 explicitly fixture-verified scopes (nineteen inspection methods,
connect/2 discovery and eight lifecycle methods), within the same 36 partial selected endpoint pairs.
This closes the listed bounded evidence obligations, not all B01 endpoint behavior
or task 3.9. The 32 missing typed implementations and 28 selector gaps are unchanged.
Other backlog batches and shared tool implementation remain outside this batch.

The ledger is curated audit data. `test/endpoint_evidence_test.exs` independently
extracts the unchanged REST document and server AST, checks hashes, exhaustiveness,
method/query/helper mappings, source/test anchors and backlog integrity. It rejects
missing/duplicate views, stale sources/methods and completion overclaims.

## B02 core inspection progress

- [x] Verify the remaining nine named reads: instance list/get/state, snapshot
  list/get, image list/get and operation list/get on Unix and mutual HTTPS.
- [x] Compare fixed populated/empty fields, corruption and native 403/404 with the
  unchanged named Go methods; flatten grouped operations without ordering claims.
- [x] Verify connect/2 discovery separately using RawQuery transport and independent
  required-field/version guards; an empty server object is rejected, not accepted.
- [x] Check scoped binding, applicable getter ETags, byte/readiness rejection and
  deadline/cancellation with actual peer EOF for all ten new contracts.
- [x] Record core_inspection_v1 on exactly ten partial rows in both ledgers.
- [ ] Close additional recursion/filter/all-projects/private-image/instance-type,
  field/error/cluster and discovery/auth variants or obtain explicit scope decisions.

B02 now has initial scoped evidence for all twenty assigned rows. Together with
B01 this raises explicit scoped contracts from 18 to 28 (27 methods and one helper).
It does not close every view or imply tool export/backend acceptance. No typed
implementation or selector gap is removed by an evidence-only batch.
