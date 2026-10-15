# Task 3.9 finite closure backlog

Audited at Incus v7.0.1 `13f3992766142d5087fff2e362cd2e1a75294fe8`
after merged PR #11 (`7658fea`). The authoritative classified rows are in
[`endpoint-inventory.json`](../priv/incus/endpoint-inventory.json). This is an
inventory classification, not new endpoint support or behavioral completion.

## Inventory result

All **247 documented endpoint/method pairs** and **293 operation views** are
classified: 46 views are additional query/access variants, including ten public
access views. `?public` documents untrusted/public behavior; it is not an invented
wire selector. All **269 catalogue descriptors** map to these rows. No documented
pair or view is left unclassified.

| Classification | Pairs | What still needs closing |
| --- | ---: | --- |
| Exact JSON catalogue mapping | 183 | Certify a finite supported contract, reusing existing native fixtures. |
| Custom-volume-only catalogue mapping | 5 | Certify native custom-only backup scope; the server rejects other backup subtypes. |
| Explicit discovery/binary/upgrade helper | 22 | Certify the helper's finite options, streams, errors and cleanup. |
| Missing typed implementation | 35 | Implement and verify, or obtain an explicit user-approved exclusion. |
| Equivalent volume collection POST | 1 | Same native handler as typed-volume POST; certify supported route/body behavior or resolve scope. |
| Incorrect documented GET repair | 1 | Retain the source discrepancy; actual mutation is POST, below. |
| **Documented total** | **247** | No classification is a completion claim. |

The standard Go AST extractor accounts for **246 public v1.0 registered pairs**,
including image suffix actions. Root discovery is a separately checked source
anchor in `cmd/incusd/api.go:restServer`. All documented routes reconcile except
`GET /1.0/instances/{name}/debug/repair`: `instances.go:instanceDebugRepairCmd`
registers **POST**. One supplemental server row tracks that missing typed mutation.
Thus there are **36 confirmed typed implementation gaps**, plus the equivalent
collection-route decision. These are not a count of missing Go declarations. Raw HTTP support does not implement those typed contracts.
No source file in the pinned module was modified.

## Exact implementation backlog

- **24 PATCH pairs (B05):** server; certificate; cluster group/member; image/alias;
  instance metadata/snapshot; network, forward, load balancer, peer, ACL,
  address set, integration, zone and zone record; profile; project; storage pool,
  bucket, volume and volume snapshot; warning. The conditional instance PATCH is
  already implemented and is B04 contract certification, not one of these gaps.
- **2 HEAD pairs (B06):** instance files and storage-volume files.
- **3 recorded exec output pairs (B07):** list, binary download and explicit delete.
- **5 storage pairs (B08):** volume list by type, bitmap download, bucket backup
  list/get/rename. Custom-volume backup methods already exist and are not absent.
- **1 discovery pair (B10):** `GET /`.
- **1 actual repair mutation (B12):** `POST /1.0/instances/{name}/debug/repair`.

The parameter audit also identifies **nine selector gaps on implemented routes**:
`filter` on network ACLs, address sets, integrations, zones, zone records,
forwards, load balancers and peers (B09), plus console-log `type` (B11/S07).
They are recorded as `unmapped_selector`, not hidden under route matches.
The two file HEAD `path` selectors are also unmapped but already included in B06.
Each view retains every query parameter declared inside its REST operation,
classified as host routing, catalogue, explicit helper query or unmapped selector.
Selector-compatible method candidates do not establish public access or body
semantics; those remain certification obligations.

No new exclusions are approved. Existing bounded implementations still need
contract certification; this count must not imply that only 36 tests or changes
remain, nor that every remaining method requires a new implementation.

## Endpoint batches and finite exits

These assignments partition the 247 documented rows exactly once; the extra
server POST is assigned to B12. Batch sizes are endpoint/method pairs, not
estimates of lines or commits. Split a batch into bounded slices before coding.

| Batch | Assigned documented pairs | Exit |
| --- | ---: | --- |
| B01: Initial mutation lifecycle | 8 | Verify eight pairs: instance create/update (including restore)/state/delete, snapshot create/delete, image delete and operation cancel. Reuse native baselines; compare accepted identity through completed/failed/running, applicable preconditions, response loss and no replay on Unix/mutual HTTPS. |
| B02: Initial inspection certification | 20 | Reuse ten verified inspection scopes; certify ten other selected JSON/discovery read contracts. Enumerate catalogue selectors/fields, populated/empty/native rejection, routing/ETag and transport/bound/lifetime evidence; no exhaustive field cross-product. |
| B03: Exec and operation channel/wait scope | 4 | Attach existing live exec/native wait/channel and events-listener (S03) evidence to finite supported contracts; resolve secret/public-access views and forwarding scope explicitly. Recorded output belongs to B07. |
| B04: Instance PATCH contract certification | 1 | Retain the verified conditional InstancePut contract; resolve unconditional/restore/field scope explicitly without inferring daemon merge acceptance. |
| B05: Remaining typed PATCH implementations | 24 | 24 pairs need dedicated typed request/result contracts, conditional semantics and representative native errors; implement and verify or obtain explicit exclusions. PUT/raw-query success cannot close these rows. |
| B06: File metadata HEAD | 2 | Implement instance and volume metadata-only typed helpers with header fidelity, empty body, rejection and bounded cleanup evidence on both transports. |
| B07: Recorded exec output | 3 | Implement typed list, acknowledged binary download and explicit delete. Verify identity/path isolation, missing output, bounds and uncertain deletion; never imply automatic deletion. |
| B08: Storage endpoint contracts | 49 | Certify the exact catalogue/helpers for each assigned row; implement by-type volume list, bitmap download and bucket backup list/get/rename. Reconcile equivalent collection POST, custom restrictions and recursion views; add evidence for declared fields/errors/lifetimes only. |
| B09: Network endpoint contracts | 53 | Certify the exact assigned network/ACL/address-set/integration/zone catalogue contracts, their selector/extension/ETag/routing/results and representative rejection/uncertainty over both transports. PATCH rows remain B05. |
| B10: Administrative endpoint contracts | 40 | Certify assigned server/project/profile/certificate/cluster/resource/metadata/warning contracts; implement root discovery. Resolve public-access views explicitly, preserving host verification. PATCH rows remain B05. |
| B11: Remaining instance/image contracts | 42 | Certify assigned instance/snapshot/backup/image/alias typed/helper scopes, including listed body modes. Verify supported fields/selectors, result/error/identity/ETag and bounds; copy/streams have additional S-contract obligations. |
| B12: Pinned source reconciliation | 1 | Keep the documented GET debug repair mismatch and actual POST registered route linked. Design a typed mutation contract against the server POST or obtain explicit scope approval; never implement a repair mutation as a GET. |

## Streaming and non-REST obligations

The twelve contracts below overlap endpoint batches: they are not another set of
routes to add to the denominator. Evidence already exists for each. Finish each
by enumerating its supported modes and linking existing checks, then implement or
verify only identified holes. OCI/SimpleStreams are public client behaviors beyond
the Incus REST document and remain in the completion gate.

| Contract | Remaining finite obligation | Boundary |
| --- | --- | --- |
| S01: Live exec | Certify finite binary stdin, acknowledged output, authoritative exit, limits and accepted-error identity using existing evidence. | Live noninteractive bounded subset; no arbitrary producer or tool capture policy. |
| S02: Console | Enumerate supported static/dynamic attachment/control types and existing repeated-attachment/cleanup evidence; resolve remaining callback orchestration scope. | Host-owned streams and finite lifetimes. |
| S03: Events and callbacks | Enumerate type filters, all-projects/target/lifecycle selectors and link capacity/callback/owner-loss evidence. | Explicit listener ownership; native callback order is unspecified. |
| S04: Files | Certify file/directory/symlink, uid/gid/mode, overwrite/append, path/routing, binary bounds and native failures; HEAD remains B06. | Acknowledged host sources/sinks; no implicit host files. |
| S05: Image binary handoff | Enumerate supported unified/split/compression/header/token modes; link existing private-token/copy/uncertainty evidence and identify uncovered cases. | Host-owned sources/sinks/staging; no implicit tools. |
| S06: Archives | Enumerate instance/volume/bucket import/export/direct POST, name/pool/config/device and ISO modes; reconcile existing fixtures and remaining transport/failure evidence. | No implicit host filesystem state. |
| S07: Auxiliary byte streams | Certify each mapped metrics/log/console-log/template/debug-memory helper including exact selectors, headers, native failures and cleanup. | Recorded output remains B07; repair remains B12. |
| S08: Raw SFTP/NBD | Certify instance/volume path, instance reuse and volume writable options, 101/coalesced bytes, half-close and bounds against existing evidence; retain approved oracle byte-loss difference. | Raw NBD payload protocol is caller-owned. |
| S09: Typed SFTP | Link existing v3 subset packet/status/fragment/bounds/owner/uncertainty evidence and explicit unsupported-operation rejection. | Approved init/extensions/open/read/write/close subset; no full pkg/sftp requirement. |
| S10: Copy/migration | Enumerate existing local/pull/push/relay instance/snapshot/volume/image combinations, approved address/channel sets, remote wait and no-replay cleanup; resolve any unsupported options explicitly. | Host approves origins; preserve source and target identities; no following arbitrary addresses. |
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
- [ ] Add reviewed completion records for finite contracts; classification alone cannot set behavior_complete.
- [ ] Independently review and pass canonical/reference/platform/immutable-consumer checks for closing slices.

Installed OCI/delta converters, explicitly opted-in isolated real-Incus acceptance
and consumer-owned Macus hardware remain separate acceptance records. No automatic
acceptance run is authorized by this audit. Go declaration parity remains a
separate claim; no declaration status is promoted.

## Recommended next implementation batch

Implement **four conditional typed PATCH methods** under B05: project, profile,
image and instance snapshot. They share existing PUT models and the bounded
conditional instance PATCH approach: caller ETag, lossless field presence, native
result/errors, no local merge and no replay. Inspect each server handler's result
shape rather than copying PUT's asynchronous classification. Use unchanged Go
RawQuery only for transport comparison plus independent endpoint fixtures, on
Unix/mutual HTTPS. This would remove four actual typed implementation gaps while
keeping broader unsupported scope explicit; it does not certify daemon merges.

Then prioritize B01's eight mutation lifecycle contracts for the initial
`add-incus-operations` surface. Those methods already exist: this is composition
and evidence work, not eight absent implementations. This audit implements neither
batch. Stop and re-scope before parsers, unrelated runtime changes or fixture
expansion exceed a bounded slice.

The ledger is curated audit data. `test/endpoint_evidence_test.exs` independently
extracts the unchanged REST document and server AST, checks hashes, exhaustiveness,
method/query/helper mappings, source/test anchors and backlog integrity. It rejects
missing/duplicate views, stale sources/methods and completion overclaims.
