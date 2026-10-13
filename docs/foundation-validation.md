# Foundation verification — rolling fixture ledger

> **Extraction note (2026-10-13).** Everything below this note was recorded
> while the client lived in [upmaru/opsmaru](https://github.com/upmaru/opsmaru)
> on `feature/phoenix-bootstrap-and-remote-access`, up to `a00805d`. Revisions,
> CI run links, `mise run check:library`/`MIX_ENV=library` commands and
> PostgreSQL scaffold checks refer to that repository. The history was carried
> into this repository with `test/library/` renamed to `test/`; test file
> references below were updated to the new paths. New entries are recorded in
> this repository against `mise run check`.

## Merge preparation — 2026-10-12

The earlier corrected published runtime is
`3b172fbe7453ecc7b0063bb567e702db0babd1b5`. All 545 database-free library tests,
strict Credo, a forced warning-free library rebuild, canonical checks and actual
`mix precommit` passed locally. Scaffold checks used a new disposable PostgreSQL
cluster (five tests in each run), stopped and removed afterward. All four
OpenSpec changes passed strict validation. The fresh independent Git consumer
passed at this runtime; its default source pin and captured dependency lock now
record the correction. No Macus source or real workload was modified.

The full-branch Greptile review against `develop` at `61cbb45` returned 3/5 and
two P1 findings (run `edd5b788-fff3-4131-bd50-53711109f54a`). The duplicate client
Inspect definition was removed; the reported compile failure did not reproduce
with a forced compile. Split-image relay data loss did reproduce: a missing
rootfs source allowed a metadata-only target upload, and an empty rootfs part
was omitted even with a valid source. Four permanent regressions now verify
missing/wrong-arity/invalid sources reject before target POST and both empty
and nonempty rootfs bytes survive a single multipart upload. Host staging stays
owned by the host. Final follow-up review and exact-head platform CI are
submission gates recorded in the PR, not inferred from this local evidence.

The earlier exact-head run at `61cbb45` passed macOS/Linux CI and immutable
consumers: https://github.com/upmaru/opsmaru/actions/runs/38199888936. It predates
these corrections and does not establish their platform acceptance.

Current coverage is 916 partial and 364 missing declarations of 1,280;
`complete_port` remains false. Foundation tasks 3.9 and 4.3 stay open. Gateway
implementation stays at 0/19 and has separate acceptance. Installed OCI adapter,
real Incus and Macus installed/VZ/hardware gates remain unverified. The rest of
this document records historical slices against their own revisions.


This is fixture/library evidence for `add-embedded-incus-foundation`, not full
client, installed-service or real-backend acceptance. The approved scaffold
was extended on `feature/phoenix-bootstrap-and-remote-access`; the initial fixture
phase used no phx.new, Macus source modification, VM startup, backend install
or workload mutation. Later explicitly opted-in real preflight is recorded below. Full copy/migration option and remaining reference parity remain incomplete.

Toolchain: Elixir 1.19.5/OTP 27.3.4.16, Node 26.10.0/OpenSpec 1.14.0,
Go 1.25.14 (verification only), PostgreSQL 16.9 (disposable web checks only).
Transport: Mint 1.11.0/hpax 1.1.0 and MintWebSocket 1.0.5 in `mix.lock`.
Phoenix 1.8.15/plug_cowboy 2.9.0/Cowboy 2.19.0 locks remain compatible.

| Evidence | Result | Limits |
| --- | --- | --- |
| Database-free `mise run check:library` | 541 tests passed after the OCI host-adapter continuation and review corrections | macOS local fixtures; full parity incomplete |
| Archive variants/TLS/migration focused checks | 5 tests passed | Native fake-backend archive bytes, HTTPS upgrades and failure preservation |
| Actual embedded startup/restart with PHX_SERVER and invalid PORT | Empty supervision, no new ports/state/Endpoint/Repo | Installed Macus not exercised |
| Official typed resource calls | 268 methods compared | Request/result/error/extension slices, not all-field semantic parity |
| Unix/HTTPS, mTLS, wrong trust/hostname/keys and exact server pin | Passed | Isolated private sockets/loopback TLS |
| Stream helper differential slice | Seven metrics/log/console/template/debug helpers compared with unchanged official methods; 9 independent fixtures passed | Selected helper/Unix/TLS/byte/error/owner/deadline evidence only |
| Native image/file/backup transfers | Binary and multipart comparisons passed | Host-owned staging; backend behavior unverified |
| Raw SFTP/NBD | Coalesced bytes, duplex, half-close, native chunked rejections, bounded blocked writes and cleanup passed | Raw byte connection, not a complete SFTP/NBD protocol implementation |
| WebSocket/events/exec/console | Binary/control/exit/overflow/ownership fixtures passed | Dynamic console, recorded output and complete migration relay parity remain open |
| Operation polling/cancellation | Deadlines, native bindings, completion race and at-most-once DELETE passed | No live-backend cancellation acceptance |
| Migration negotiation | Native copy requests compared; HTTPS secrets/accepted identities, bidirectional control/data binary/text relay, EOF/deadline/mismatch and native upgrade rejection verified | Complete cross-cluster/options/helper acceptance remains incomplete |
| Copy capability preflight | Eight rejected option/extension cases and supported target-side inconsistent copy compared with unchanged official helper | Selected option matrix; no real workload copy |
| Copy/move/image preparation | Local volume moves, six remote copy combinations and local/public/private image create/rebuild compared; source token identity retained on target loss | Selected native Incus sources/options; OCI/SimpleStreams remain missing |
| Native model helpers | All populated fields of 23 writable DTOs, nine resource URL helpers, five ETag input tuples, status names/finality/activity compared | Null/absence remains lossless; remaining custom JSON/YAML/type helpers incomplete |
| Connection information/authenticated requirement | Native Unix/HTTPS discovery metadata/defaults/header comparison; all request frontends preserve connection-local flag | Backend authenticated requirement only; host identity and real backend trust remain separate |
| Event sending | Native JSON text frame comparison, invalid input/overflow/owner cleanup passed | Local write acknowledgement only, no backend processing proof |
| File/archive variants | Twelve official native helper comparisons plus directory metadata, errors, no replay and explicit member wire selection passed | Direct backup native comparison uses no member; actual member forwarding remains unaccepted |
| Migration target lifecycle | Target lookup, bounded wait, completion/cancellation race and uncertain DELETE retain source/target identities | No implicit source wait/cancellation; complete remote-operation/event-handler parity remains missing |
| Inventory and schemas regenerated | 1,280 entries/86 source hashes; byte-for-byte match | Inventory/schema presence is not coverage |
| Go inventory parser regressions | Passed | Verifier-only tooling |
| `mise run check` via `python3 scripts/check-isolated.py` | Format, warning-free compile, assets, 5 web tests, embedding and strict specs passed | New disposable UTF-8 PostgreSQL cluster, stopped/deleted afterward |
| Strict OpenSpec validation | All three changes passed | Artifact consistency, not runtime acceptance |
| macOS/Linux CI | 508 core tests and clean immutable consumer passed on both platforms at 21c21932ea659ce7e2d6eb8448dee8c1270628d7 | Protocol fixtures only; no real Incus/Macus |
| Independent immutable consumer | 1 expanded clean consumer test passed at published 21c21932ea659ce7e2d6eb8448dee8c1270628d7 | Fetched from GitHub into a disposable directory; resolved consumer lock recorded |

The coverage manifest records 268 differential JSON methods, 883 partial
reference mappings and 397 missing declarations. Missing entries prevent a
complete-port claim. See `incus-client.md` for the exact API and limitations.
The v7.0.1 rawConn prefetch defect is negative oracle evidence; Opsmaru's
required preservation behavior is independently checked without patching the
oracle or treating the discrepancy as an approval gate.

This continuation adds 35 library tests and 12 partial declaration mappings:
volume SFTP/read-only/writable NBD typed comparisons over Unix and HTTPS,
private unified/split image exports, explicit native ConfigMap/DevicesMap JSON
coercion, and repeated dynamic-console attachments/control. All 441 database-free
library tests passed locally, as did the canonical full checks with a fresh
isolated PostgreSQL cluster, stopped and removed afterward. The reference tag,
revision and source hashes remain unchanged. No new live-backend evidence is
claimed; the 441-test native-error follow-up at 2827c6e passed on both Linux and macOS.

Private-image unusual token characters match the pinned helper's double form
encoding. Native JSON coercion includes scalar/null/device-property merge and
float64 precision/formatting edge cases; Go's ARM64/AMD64 conversion difference
at positive 2^63 is preserved. Dynamic console uses one accepted POST/control
channel and bounded, owner-bound data attachments. Missing descriptors and
control/data handshake failure retain the accepted identity. Native operation
WebSocket comparisons omit project/member, because the pinned helper does;
Opsmaru's required explicit selection is separately checked on every request.
Full callback/IO/YAML/other architecture and backend forwarding acceptance stay
visible as remaining coverage.

Independent review reproduced native transfer rejection responses missing their
originating connection/host identity. The shared transfer error path now binds
native envelopes as well as successful responses. The private-image regression
failed before this correction and passes afterward; all 441 library tests and
isolated canonical full checks passed again. Native payload, ETag and caller
reconciliation data remain retained and redacted from ordinary inspection.

Credo 1.7.19 is pinned as a development/test/library dependency with `runtime:
false`, and `mix precommit` runs `credo --strict`. Both canonical mise check
profiles also enforce it. `.credo.exs` retains all default checks with finite
complexity/nesting limits, covers library/web/consumer/fixture code, and excludes
consumer dependency/build directories. Existing findings were resolved by alias
ordering and smaller validators/protocol/fixture handlers, without suppressing
checks. Strict Credo reported no issues across 834 modules/functions; all 441
library tests passed after the refactors. `python3 scripts/check-isolated.py
--precommit` ran the actual precommit alias and canonical checks successfully
against one fresh disposable test database; both 5-test scaffold runs passed. The clean immutable consumer also passed at
2fa3fdea9085941e2ae866d5c9e473cb14ee4971 after these refactors.
The initial Credo-enabled CI run passed Linux but failed macOS on an existing
100 ms event-owner fixture handshake wait: https://github.com/upmaru/opsmaru/actions/runs/38106226746.
A 150 ms scripted handshake now reproduces that failure deterministically;
the owner test uses the connection's bounded 5-second handshake allowance and
cleans up its spawned owner even on failure. The subsequent monitor/closure
assertions remain bounded and no backend cancellation/replay is introduced.
The corrected Credo-enabled CI run passed all 441 library tests, strict Credo,
strict OpenSpec, Go verifier checks and clean immutable consumers on macOS and
Linux at e80de4f36d3c24b740ea0be74cb72916ce0101e9:
https://github.com/upmaru/opsmaru/actions/runs/38106635241.
Greptile repository setup was initially blocked by automatic approval review;
the user connected it through the dashboard. Read-only status now confirms
it is enabled, and the requested review ran against the committed
continuation/Credo diff from 03a1452 through e80de4f. The first review returned
4/5 confidence and one P2 finding: dynamic-console actors discarded recognized
child-channel failure messages. Four actual control/data overflow and byte-limit
fixtures reproduced the missing notification before the correction. The fix
forwards exact causes, channel references and accepted operation responses to
the host; unknown references are ignored. All 445 library tests, strict Credo
(840 modules/functions), canonical checks and actual isolated `mix precommit`
passed afterward. The follow-up review confirmed that correction and returned
4/5 with one P1 finding: remote control WebSocket closure retained the actor,
preventing the console's monitor from promptly releasing local attachments.
Actual close-frame and socket-disconnect fixtures reproduced both failures
before the fix. A once-only owner EOF notice now triggers console cleanup,
retains the accepted operation, and performs no DELETE or POST replay. Ordinary
WebSocket readers can still drain queued tail frames after EOF. All 448 library
tests, strict Credo (842 modules/functions), canonical checks and actual isolated
`mix precommit` passed. The third Greptile review
(`8478a4b5-650d-4730-8303-406f1087d1c5`) returned 5/5 confidence and zero
comments, confirming both prior fixes. Its CLI wait returned a server error;
`greptile review show` recovered the completed result. Run status records base
03a1452b4488ff9629724c4e26e5ffdd98baf9aa and head
107eec41d625f512da70b57f58525d56980cf8e4. The review report says comparison
ancestry could not be verified and describes the 49-file patch as `HEAD^..HEAD`;
the actual 49-file scope is the recorded base-to-head diff. This is static code
review evidence, not executed-test or complete-client acceptance.
The clean external consumer passed
at fdd530557bd1a87b36e68f994daef37e4490c9d4 with the correction;
https://github.com/upmaru/opsmaru/actions/runs/38107507422 passed both platforms.
The latest 448-test run and clean immutable consumers passed on macOS and Linux
at 107eec41d625f512da70b57f58525d56980cf8e4:
https://github.com/upmaru/opsmaru/actions/runs/38108133770.
The documented consumer revision and lock now record that independently
verified published code revision.

The preceding continuation added 111 declaration mappings and 63 library tests.
The previously unchecked documentation revision 7d44efe failed macOS CI because
its raw deadline test checked process liveness immediately after the error
notification. The test now waits for a bounded monitor DOWN, preserving the
cleanup assertion while removing the scheduler race.
Linux cold-cache CI also exposed `go list -m` omitting the module source
directory before download. Source verification now explicitly downloads the
pinned module first; all three wire/hash tests passed with a fresh empty Go
module cache. This changes verifier setup, not the reference or transport.

The independent consumer supplies its own Phoenix endpoint, runtime readiness,
private backend and secrets, and calls the client with Opsmaru stopped. It uses
Phoenix 1.8.15, Mint 1.11.0, plug_cowboy 2.9.0, Cowboy 2.19.0 and TamaMCP 0.1.1.
`scripts/check-consumer.py` builds the exact requested Git revision in a new
temporary directory, with no source path dependency or sibling checkout.

Expanded slice platform run: https://github.com/upmaru/opsmaru/actions/runs/38105449541.
Native-error follow-up platform run: https://github.com/upmaru/opsmaru/actions/runs/38105719771 (passed).
OpenSpec progress is 20/22: task 3.9 remains open for remaining reference parity;
task 4.3 remains open for explicit isolated real-backend acceptance.

Remaining gates: complete canonical copy/migration option and missing method/type
coverage; explicit isolated live Incus Unix/HTTPS mutation/operation/stream
acceptance; consumer-owned installed Macus/VZ/hardware acceptance. Real-backend
and hardware acceptance remain unchecked without explicit opt-in. No merge,
release tag, deployment or OpenSpec archive is performed by these checks.

The native preseed continuation adds 22 focused fixtures and eight partial
method/type mappings. The unchanged official ApplyServerPreseed helper agrees
on Unix/HTTPS create/update/empty/mixed sequences, typed JSON defaults, ETags,
project/member selection, dependency order, description/config/device merges,
group membership and native mutation failures. Independent fixtures verify
whole-call deadlines, bounded result capture, uncertain acceptance/no replay,
accepted cluster operation preservation, capabilities and readiness. All 470
library tests, strict Credo (926 modules/functions), canonical full checks and
actual isolated `mix precommit` passed locally. New platform/review evidence
will be recorded after the next published continuation. No real server was
configured by these checks; YAML remains unimplemented.

The network/copy continuation adds 21 further library fixtures and 12 partial
normalizer/type mappings. Eight unchanged native network helpers agree on
populated/empty/null objects, Unicode whitespace, IPv4/IPv6 formatting, nested
ports/backends and deliberately unchanged fields. Copy comparisons now require
complete native POST bodies; local/remote default, empty-name, enabled and
inactive option cases are covered. Permanent regressions reproduced omitted
instance restore/disk-only fields and incorrect volume destination-name defaults
before correction. Typed-input failures preserve native reconciliation data and
fail visibly rather than raising. All 491 library tests, strict Credo
(975 modules/functions), canonical full checks, actual isolated precommit and
strict OpenSpec passed locally. The shared typed-input projection is internal;
normal `Model.decode` remains lossless. New CI, consumer and Greptile results
will be recorded for the published continuation.

Greptile reviewed the committed native preseed/network/copy continuation at
3bcb32bb4d4868a447f0d255489358ba8c8967e4 against f3ca740:
run `14138e80-1d27-43a2-b6c9-6ac68057f019`, 5/5 confidence, zero comments.
The expanded independent consumer passed at that same immutable revision,
including no-op preseed and network normalization with Opsmaru stopped.
Linux CI passed. macOS CI exposed five Go-oracle CA-only trust failures and a
100 ms whole-deadline fixture expiring before its first POST:
https://github.com/upmaru/opsmaru/actions/runs/38110149454.
The preseed oracle now supplies the same explicit server certificate used by
other HTTPS oracle fixtures; TLS verification remains enabled and production
transport is unchanged. The deadline case now uses a 1-second total budget and
700 ms per response, preserving the requirement that it stops before a second
POST. All 28 focused preseed/inventory fixtures passed after these corrections;
the subsequent platform run remains pending.

Coverage scope was also corrected: name-only matching had attributed 32 native
Incus helper/method fixtures to different OCI/SimpleStreams implementations.
All 40 methods in those two concrete classes now remain missing, with a
permanent manifest regression check. The correction adds no new protocol
support and does not change the immutable 1,280-declaration inventory or pin.

The raw HTTP continuation adds 14 fixtures and four partial method/interface
mappings. Unchanged GetHTTPClient/DoHTTP calls agree over Unix and HTTPS on
binary bodies, native status/ETag and authenticated headers, including an
explicitly non-replayable 305 request. Independent fixtures cover all supported
verbs, redirects without forwarding, request/response bounds, uncertainty,
host/connection isolation, ordered duplicate headers and separate trailers.
Native JSON calls now retain the first ETag header without a trailer replacing
it, matching net/http Header.Get. The helper captures finite raw bodies; it
does not claim streaming io.ReadCloser or mutable pool parity. All 505 library
tests, strict Credo (996 modules/functions), canonical full checks and actual
isolated precommit passed, with all three changes strictly validated and the
Go verifier checks passing. Runtime code review/consumer/platform results for
this new slice remain pending until publication.

The raw HTTP runtime revision c8a358d994921e8b9629bd995705723b67c1c950 passed
all 505 library tests, strict Credo/OpenSpec, Go checks and clean immutable
consumer builds on both macOS and Linux:
https://github.com/upmaru/opsmaru/actions/runs/38111311857.
The expanded clean consumer also passed locally at that immutable revision.
Greptile run `ffd7c0b3-aad2-407c-9274-f56feb8112cd` reviewed the full
continuation against f3ca740 and returned 5/5 confidence with zero findings.

Direct DoWebsocket adds three focused fixtures and one concrete native method
mapping. The unchanged helper agrees over Unix and HTTPS on custom/authenticated
request headers, 101 status/ETag, native binary frames and explicit selection.
Transport/protocol/authentication header overrides and invalid options are
rejected before socket access. Handshake metadata keeps connection/identity and
redacts cookie values in ordinary inspection. Existing WebSocket, TLS and
dynamic-console lifecycle regressions passed in the 23-test focused run.
All 508 library tests, strict Credo (1,003 modules/functions), canonical full
checks and actual isolated precommit passed. Default and library formatting
checks both pass; strict OpenSpec remains three changes passed. Runtime review,
platform and expanded consumer results are recorded below.

The final runtime slice at 21c21932ea659ce7e2d6eb8448dee8c1270628d7 passed all
508 library tests, strict Credo/OpenSpec, Go verifier checks and clean immutable
consumer builds on both platforms:
https://github.com/upmaru/opsmaru/actions/runs/38111940448.
The expanded consumer passed locally at that revision with no-op preseed,
network normalization, immutable HTTP handle/origin rejection and protected
WebSocket-header rejection, while Opsmaru was stopped. Its exact dependency
revision/lock and the embedding example now record that implemented source.
Greptile run `6a2b8632-8be3-4b4c-a07f-59a404095dca` reviewed the full runtime
continuation against f3ca740 and returned 5/5 confidence with zero findings.
This continuation adds 60 library tests and 25 native partial mappings while
correcting 32 unsupported protocol mappings. Task 3.9 stays open for the
remaining 410 missing declarations and broader semantic matrices; real Incus
and installed Macus/hardware acceptance stay separately unchecked.

Visible client gaps include full dynamic console callback/IO and
SFTP protocol helpers, direct HTTP/WebSocket/context convenience helpers,
OCI/SimpleStreams sources, operation/remote-operation handlers, remaining type/JSON/YAML
utilities and full cross-cluster/option matrices. Native storage upgrade and
private image-file method evidence are now recorded as partial slices.
OIDC client helpers remain excluded by the approved foundation scope.

The clean consumer reports the existing cowlib 2.21.0 advisory
[EEF-CVE-2026-43966](https://osv.dev/vulnerability/EEF-CVE-2026-43966).
The earlier dependency check confirmed 2.21.0 as the latest release then;
this continuation retains that locked version. The pinned Cowboy
2.19.0 source retains the default `invalid_response_headers: error_terminate`
guard in HTTP/1 and HTTP/2, matching the
[CNA documented mitigation](https://cna.erlef.org/cves/CVE-2026-43966.html).
The portable client uses Mint and does not invoke Cowlib structured-field
builders. This records the advisory and mitigation; it is not blanket security
or standalone-service acceptance, and host applications still own their headers.

The next 3.9 continuation adds 15 permanent library tests and 13 partial helper
mappings: four native response metadata helpers, operation-to-certificate/cluster
token conversion, both exact JSON/base64 token formats, and all five EventListener
lifecycle helpers. The unchanged Go drivers compare native data, type errors,
null initialization, defaults, nanosecond timestamps, float64 precision, escaping,
filtering/removal, activity and repeatable wait. Independent fixtures verify
handler capacity, owner isolation, callback exception/timeout redaction, worker
cleanup (including brutal listener loss and callbacks trapping exits), EOF,
malformed events, lifetime and no DELETE on local wait timeout.

All 523 library tests passed locally. Strict Credo reports zero issues across
1,102 modules/functions. Canonical checks and actual `mix precommit` both passed
with a disposable PostgreSQL cluster, stopped and removed afterward; both web
runs passed five tests. Strict OpenSpec passed all three changes and the Go
inventory verifier passed. A scheduling-sensitive existing preseed fixture was
strengthened: its delayed GET now leaves a wide margin to reach one POST, whose
response remains beyond the total deadline; resetting the POST deadline would
fail the elapsed-time assertion. The focused regression and full suite passed.

Coverage is 883 partial/397 missing, still `complete_port=false`. No backend,
installed Macus or hardware acceptance is added. Task 3.9 and task 4.3 remain
unchecked. `task-3-9-closure.md` records the remaining groups and an unresolved
OCI design conflict at that revision: pinned OCI export requires
root/skopeo/temporary conversion state, while the foundation excludes host
commands and keeps platform behavior host-owned. The user subsequently approved
an explicit host-adapter contract; see the continuation below.

## OCI host-adapter continuation

The approved design/spec now keep OCI in scope through an explicitly supplied
host adapter, with no bundled runner, root escalation or temporary conversion
state. The unchanged pinned client oracle invokes a fake skopeo stdout stub;
it verifies normalized aliases, every pinned architecture name/alias, layer
fingerprints, native image JSON, null/default/nanosecond/int64 overflow values
and eleven native unsupported-method errors. Fake adapter fixtures separately
verify readiness/ownership, bounded immutable cache, inspection size/type limits,
binary metadata/rootfs bytes and sticky sink rejection, foreign-worker rejection,
trapping callback/cleanup deadlines, owner-loss cleanup and redacted structured
failures without replay. Installed conversion, real registry trust/authentication
and external process/file cleanup remain unverified host-adapter gates.

The manifest records 899 partial/381 missing declarations with
`complete_port=false`: fifteen concrete OCI methods plus its constructor gain
explicit partial evidence. The five remaining concrete OCI helpers and all
SimpleStreams methods remain missing. Task 3.9 and real-backend task 4.3 stay
unchecked. The independent consumer fixture exercises the public OCI API while
Opsmaru is stopped and its own endpoint remains alive.

Local verification passed: 540 library tests (14 new OCI cases), strict Credo
with zero issues across 1,160 modules/functions, canonical `mise run check` and
actual `mix precommit` with a disposable PostgreSQL cluster (five web tests each),
strict OpenSpec for all three changes, and the Go inventory/schema tooling.
The disposable database was stopped and removed afterward. Published consumer,
platform CI and Greptile results are recorded against their immutable revisions.

The fresh GitHub consumer passed at
`4e9e113810e79c5e6b250cd286b87eeb0aa8b937`, including the explicit OCI adapter
while Opsmaru was stopped. Independent review then reproduced a conversion
error-preservation gap; conversion now retains a host-supplied native Error just
as inspection does. Its regression and all 540 library tests, strict Credo,
canonical checks and precommit passed after correction. No installed converter,
real registry or backend/hardware acceptance is claimed.

Greptile reviewed `4e9e113810e79c5e6b250cd286b87eeb0aa8b937` against `ae7d22f`
(run `50dbecc2-e0d6-48ce-94d7-175943ef8612`), returning 4/5 with two findings:
P1 caught sink exceptions could conceal failed output and P2 conversion errors
lost structured native details. Both were reproduced before correction. The
emitter now catches raise/throw/exit failures and rejects later chunks; native
conversion errors retain error code, operation and response. All 541 library
tests (15 OCI cases), strict Credo (1,161 modules/functions), canonical checks
and precommit passed with a disposable test database, stopped/removed afterward.

Greptile reviewed e76ca9742fab7f850d8c1931b23714374b19ea5e against eba0875
(run 10a217ac-5cd4-4ca7-9125-a11893bedd69), returning 4/5 with two findings.
Permanent fixtures reproduced both before correction: the callback listener
discarded queued final events on the WebSocket EOF notice, and string metadata
bypassed the documented 1 MiB limit. The listener now drains until its reader
returns EOF; string extraction uses the shared bounded projection path. An
additional regression verifies accepted token-operation identity/response retention
on conversion failure. All 526 library tests, strict Credo and isolated canonical
checks/actual precommit passed after these corrections. No complete-parity or
real-backend/hardware claim is added.

Runtime CI at e76ca97 passed macOS and Linux (523 library tests plus the immutable
consumer): https://github.com/upmaru/opsmaru/actions/runs/38114588535. The expanded
local clean consumer passed at that same published revision, including metadata/
token helpers and listener readiness rejection with Opsmaru stopped. This records
that earlier runtime's fixture evidence; its two review findings are corrected
in the following commit and require their own review/CI evidence.

The expanded independent consumer also passed against corrected runtime revision
2f2d6877a0a2fc60fe7e8d97ea36e1b8eb9f7f3f, fetched from GitHub into a fresh temporary
directory with its exact dependency lock recorded. It exercises the new pure
metadata/token helpers and listener host-readiness rejection with Opsmaru stopped;
its own endpoint remains alive and no host private state is created.

The corrected fresh GitHub consumer passed at
`d16285adc3b88415f1bf723fa8fdf40c3414507a`; its actual resolved lock and the
embedding example now pin that immutable runtime. The initial OCI revision
`4e9e113` passed macOS/Linux CI (run `38143345500`, 540 tests plus consumer),
which precedes the review corrections and is not claimed as their acceptance.

The complete runtime review at `d16285a` (run
`e61d33cb-98dd-413c-bc70-035f43f5592c`) returned 3/5: it flagged the old
default consumer pin at that snapshot and output continuing after a foreign
emitter rejection. The consumer pin was already updated in `d382213`; the
second finding was independently reproduced with an observable sink and fixed
by checking shared rejection before every local emission. All 541 library
tests, strict Credo, canonical checks and actual precommit passed afterward.

The fresh consumer passed again at
`debcea5c5dd0c988191175b3aa17310e0c45b695`, after the foreign-emitter continuation
fix. Its captured lock, default revision and embedding example now pin that
source. Greptile's earlier pin-only review at `d382213` returned 5/5 with zero
findings; that review did not substitute for complete corrected-runtime review.


The full-branch follow-up at `0bf88cd2581d6ecd46cd9461b2c9ddbee5c1f4d6`
(run `00fc9036-2699-42b9-859c-06b1420b6a51`) confirmed the preceding corrections
and returned 3/5 with two further P1 WebSocket findings. Six permanent regressions
reproduced both: blocked Unix/TLS writes lasted about 1.5 seconds despite a
100 ms lifetime; transport loss returned clean EOF to pending readers and
successful listener/migration completion. Writes now use the remaining stream
budget, including pong/close frames, and transport failure emits channel_io.
Native close-frame EOF remains drainable. Console failure retains its accepted
operation, and migration failure retains both accepted handles without DELETE
or POST replay. All 551 library tests, strict Credo and isolated canonical
checks/actual precommit passed locally after correction.

Creating draft PR #1 exposed the first PR-event consumer failure: the workflow
used the synthetic merge SHA, absent from normal dependency fetches. Commit
`ce0c4920b09dd7aff25bccc5b9f3feca1242d2e1` selects the published PR head SHA and
source repository (including fork provenance), while push events retain their
own SHA. Push and PR CI both passed macOS/Linux afterward:
https://github.com/upmaru/opsmaru/actions/runs/38203537209 and
https://github.com/upmaru/opsmaru/actions/runs/38203540111. These runs have 545
tests and precede the subsequent WebSocket correction's platform acceptance.

The user explicitly opted into starting installed Macus for isolated real Incus
testing on 2026-10-12 and requires foundation 3.9 and 4.3 before merge. The signed
installed Macus binary started a fresh private appliance with separate Incus
configuration and a foreground daemon; no default runtime or Macus source was
modified. The backend reports Incus 7.0.1. Direct Opsmaru preflight passed Unix
and native HTTPS discovery plus typed profile inspection using a dedicated
short-lived client certificate and exact native server pin. TLS still verifies
the server hostname; a wrong hostname was rejected. A process-local Erlang
inetrc supplies the isolated guest's certificate hostname without host DNS
changes. Opsmaru's Application, Endpoint and Repo remained stopped. This is
real inspection/TLS preflight only: task 4.3 remains open for mutation, operation
and stream acceptance; full Macus integration/installed hardware acceptance and
gateway acceptance remain separate. No real workload was booted by preflight.

The fresh independent consumer passed at corrected WebSocket runtime
`0bd8e4c032d33e531c5d88106e0c1e8fdb55e6e6`; its default pin, resolved lock and embedding example now record that source.


## Owner-loss cleanup correction and SimpleStreams contract — 2026-10-12

Full-branch Greptile run `627e48e6-635b-4e7b-87b6-a9bf0e4e9266` reviewed
`f97fbbf1999ab63df1e62dcc157e122d3e4dbd50` against develop `2678ed7` and
returned 3/5 with two P1 findings. Both reproduced independently. A source or
sink that traps exits survived the loss of its transfer caller; transport work
now has an independent caller/deadline guard. Two stalled console attachments
kept the console alive during termination; graceful local closes now run under
one shared 100 ms budget, followed by force-stopping remaining owned channel
workers. Detach uses the same bounded local cleanup. Four permanent regressions
verify cleanup while preserving accepted operation identity and no backend
DELETE or mutation replay. All 555 database-free library tests, strict Credo,
canonical checks and actual precommit passed locally using a disposable database.
The two blocked-console cases also passed ten repeated runs.

At `f97fbbf`, PR CI passed macOS/Linux (run `38205111802`), while push CI's
macOS preseed mixed-mode wire comparison failed (run `38205108413`). Thirty
focused repetitions and a full suite at its seed `34849` passed locally; that
has not explained the failure. Redacted first-mismatch diagnostics now report
request position, method/path and differing field names without payloads. The
failure remains visible pending fresh platform CI; no assertion was weakened.

The user approved explicit verified HTTPS and a host delta adapter for
SimpleStreams. Proposal, design, incus-client spec and task 3.9 now retain this
protocol in scope while excluding automatic `/dev/incus/sock` discovery, HTTP
downgrade and library-owned conversion tools/files. The Incus 7.0.1 reference
is unchanged. Native projections/download checksums and adapter deadlines,
ownership and cleanup require implementation evidence; installed adapter,
real-backend and Macus hardware acceptance remain separately recorded. All four
changes passed strict OpenSpec validation after the artifact revision. Foundation
3.9 and 4.3 remain unchecked; this correction does not complete either gate.

The fresh independent Git consumer passed at cleanup runtime
`81460d24703ec8efa4eb4db3fbd80210560d8717`; the captured lock, default pin and embedding example now record this verified revision.


## Blocked-call owner guards and SimpleStreams catalog/full-file slice — 2026-10-12

Full-branch Greptile run `8d76c77a-d61b-49b7-a9ac-353f6d9027e7` at
`0ade70097778706dd65a62207ee09e3741e7650d` returned 4/5. It confirmed all
preceding corrections and found one P1: synchronous attachment negotiation and
control writes prevented the console from processing owner loss. Two regressions
reproduced this. Independent owner watchers now give normal OTP cleanup a short
grace period, then stop blocked console/WebSocket actors, including actors still
negotiating. Existing local channel ownership closes the associated sockets.
Both cases passed ten repeated runs; the attachment case independently observes
closure of the unfinished upgrade socket. Accepted operations remain intact;
there is no backend DELETE or mutation replay.

SimpleStreams now has verified partial evidence for 16 concrete methods and its
passive constructor. The unchanged Incus v7.0.1 oracle verifies catalog images,
newest aliases, explicit architecture preference, partial fingerprint ambiguity,
all six formats, optional fields, delta manifests and six native unsupported
errors. Independent private HTTPS fixtures verify full-file bytes, names/sizes,
SHA-256 checks, empty parts, sink rejection, aggregate byte limits, deadline and
exit-trapping owner-loss cleanup, trust rejection and redirects without downgrade
or replay. The optional host delta converter and four connection/HTTP/disconnect
helpers remain missing; no full SimpleStreams claim is made. Catalog expansion
and metadata share explicit bounds. Source attribution is recorded in the Incus
notice. The declaration manifest is now 916 partial and 364 missing, unchanged
pin and `complete_port=false`.

All 573 library tests, strict Credo, canonical checks and actual precommit passed
locally after the slice; scaffold tests used a disposable PostgreSQL cluster,
stopped and removed afterward. Go inventory checks passed. Both push/PR CI at
`0ade700` passed macOS/Linux (runs `38206776421` and `38206780817`); cleanup-only
`81460d2` also passed both events (runs `38206663081` and `38206664805`). These
platform results precede the new SimpleStreams/blocked-call slice. Fresh consumer,
exact-head platform CI and follow-up Greptile remain gates for that slice.
Foundation 3.9/4.3 and gateway/installed-adapter/Macus acceptance remain open.

The fresh external Git consumer passed at SimpleStreams/owner-guard runtime
`3f48920f36625d0adb92ddca087c9608b4107010`; its resolved lock, default pin and embedding example now record this verified source.


## Raw-owner, image-project and pinned OTP trust-cache corrections — 2026-10-12

Full-branch Greptile run `9e9e3b19-740a-4fae-8bca-101a93c89752` reviewed
`4557fd6f7712a15e1a37be47461aa825110a4e79` against develop `2678ed7`, returned
3/5 and identified two P1 findings. Raw SFTP/NBD actors now start their independent
owner guard before opening a connection, so blocked upgrades and writes cannot
outlive caller loss. Four permanent regressions verify socket closure/worker exit
without replay. Image create/rebuild uses complete pinned request projections,
derives the source project from its explicitly bound connection and rejects a
conflicting request project before token issuance or target mutation.

The unchanged native 7.0.1 `getSourceImageConnectionInfo` also omits automatic
project inference. A dedicated oracle test proves that omission; corrected wire
comparisons pass the project's explicit request field to the unchanged helper.
Opsmaru derives that same field from its source connection, preserving the
user-required project binding. This documented reference exception does not
change the pin, patch the upstream helper or excuse other body differences.
Complete request-object comparisons replaced the old subset checks and exposed
missing native default fields, now normalized through the existing NativeInput.

At `4557fd6`, macOS push CI and Linux push/PR checks passed, while macOS PR
run `38208052669` failed after `ssl_manager` crashed refreshing a deleted test CA.
Pinned OTP 27's periodic PEM invalidation refreshes trusted filenames; a removed
CA raises enoent, destroys trust tables and terminates unrelated fixture listeners.
An isolated child-BEAM regression reproduced that crash deterministically. TLS
setup now reads bounded CA certificate bytes for each authorized connection and
passes DER roots to OTP without registering host filenames in its shared refresh
cache. The reusable TLS fixture also passes DER roots for peer verification.
Peer trust, hostname, validity, fingerprint and client-key checks remain intact.
The child regression now confirms that deleted-file invalidation preserves the
same SSL manager and closes its owned socket. This is a causal correction, not a
retry or suppressed fixture failure; the earlier preseed failure remains historical
and is not claimed independently explained by this different trace.

All 580 library tests, strict Credo, canonical checks and actual precommit passed
locally with a disposable database. The affected 39 tests passed at CI seed
`807195`/max_cases 6; raw/cache cases passed ten repetitions. All four changes pass
strict OpenSpec. New exact-head macOS/Linux CI, fresh immutable consumer and
follow-up Greptile must still verify the published correction. Foundation 3.9 and
4.3 remain open, as do separate gateway, installed converter and Macus gates.

The fresh external Git consumer passed at corrected trust/project/raw-owner runtime
`449a4a6c685b76b1e01cce4170561a286d8e2af3`; the captured lock, default pin and embedding example now record that verified source.


## Explicit host delta adapter and listener owner guard — 2026-10-12

Full-branch Greptile run `58960730-6062-41fd-91a1-4dec15f0e8e3` reviewed
`ba3569164fe9c4125683dc74e099cfce3a91094e`, returned 4/5 and confirmed earlier
corrections. Its one P1 event-listener owner-loss finding reproduced under stalled
subscription and blocked event writes. An independent guard now starts before
subscription. Both cases passed ten repeated runs; no backend DELETE or replay
occurs. All four channel/console/listener actors now install independent guards
before their blocking setup rather than depending only on mailbox processing.

The approved SimpleStreams host delta adapter is implemented and fixture-verified.
The host explicitly supplies its converter/configuration and opaque base source.
A unique call identity and inherited absolute deadline bind conversion; verified
delta input is delivered once through acknowledged sinks, and converted rootfs
must match native size/SHA-256. Repeated/reentrant or foreign calls and failed
acknowledgements latch rejection. Delta plus output share the remaining stream
byte budget. Bounded cleanup runs on completion, failure, timeout and caller loss;
cleanup failure retains its primary result and image identity. There is no bundled
xdelta runner, root escalation, temporary state, implicit base discovery or
fallback/replay after conversion failure. The existing independent OCI adapter
controller is reused with absolute deadline inheritance and truthful deadline
classification when its owner disappears at expiry.

Twelve added delta cases verify construction/readiness, byte integrity, full-file
fallback only when optional inputs are absent, corrupt input, output checksums,
foreign/repeated emission, sticky sink rejection, total byte limits, caller/deadline
cleanup and cleanup failure. All 594 library tests and strict Credo pass locally.
The unchanged native catalog/manifests remain the oracle; fake conversion proves
the host contract only. Actual installed conversion, registry authentication,
external process/file cleanup and Macus hardware remain separately unverified.

Both push/PR CI at `449a4a6` and `ba35691` passed macOS/Linux (runs
`38209542980`, `38209547479`, `38209835871`, `38209840441`). The complete suite
also passed all 580 tests at earlier CI failure seed `807195` before this delta
slice. Read-only real Incus Unix/verified HTTPS preflight passed again with wrong
hostname rejected and Application/Endpoint/Repo stopped. These results are scoped
to their earlier source; they do not imply acceptance of later delta code or close
foundation tasks 3.9/4.3. The four SimpleStreams protocol convenience helpers and
other remaining client/model matrices stay visible in the closure ledger.

Canonical checks and actual mix precommit also passed after the delta slice,
using a disposable database stopped and removed afterward. All four OpenSpec
changes passed strict validation, and all 28 SimpleStreams cases passed five repeated runs.

The fresh independent Git consumer passed at delta/listener runtime
`525c3a788a0f5817fa81a250aa70c6ec86995d5c`; its captured lock, default pin and embedding example now record that verified source.


## Delta sink exceptions and nested teardown ordering — 2026-10-12

Full-branch Greptile run `6f7bff03-8f3b-4d91-852d-0f98e2e1a5e4` reviewed
`14fde6f89a33a84ea3f5cfcce8494a782c60ca50`, returned 3/5 and confirmed earlier
corrections. Both new P1 adapter findings reproduced against the published code:
three converters caught raised/thrown/exited sinks and then completed with further
output; cleanup observed a live nested download sink when its independent guard
was deliberately suspended. Four permanent regressions demonstrate these failures.

The delta emitter now catches all sink failures and latches rejection before
returning to the adapter. A bounded per-call work scope registers callback workers
before they start and propagates into nested native transports. Conversion cleanup
waits for actual worker termination, including nested sinks, and checks descendants
again after observed parents stop. Caller waiting has an explicit deadline plus
cleanup allowance; if termination is delayed, the caller gets a visible privileged
cleanup-pending call identity while the independent controller defers cleanup.
There is no false cleanup success, conversion replay or backend cancellation.

Exact-head push/PR CI at `14fde6f` passed macOS/Linux (runs `38211903966` and
`38211907689`), with 594 library tests and immutable consumers. The delta runtime
`525c3a7` also passed both events (runs `38211683834` and `38211687620`). These
platform results predate the new four regressions and teardown correction; fresh
consumer, CI and Greptile must verify their published source. Foundation 3.9/4.3,
installed converters, Macus hardware and gateway acceptance remain open.

All 598 library tests, strict Credo, canonical checks and actual precommit passed
locally after the correction with a disposable test database. The four reproduced
adapter cases passed ten repetitions; strict OpenSpec validation remains green.

The fresh independent consumer passed at settled callback runtime
`b9cd50fa2fc5f0e9b8026ae00bce722ef5338fb0`; its captured lock, default revision and embedding example now pin that verified source.


## Accepted-response decode uncertainty — 2026-10-12

Full-branch Greptile run `e400d23c-2b0c-4038-ac14-3774b37e61d0` reviewed
`e71335fc2d5188a59619451e60d9c6168ec6fccb`, returned 4/5, and confirmed adapter
corrections. Its one P1 accepted-mutation finding reproduced: malformed async
operation metadata returned invalid_model, and null metadata returned success.
Three permanent cases now return uncertain while preserving raw response,
connection, identity and exact native operation URL. A synchronous successful
bucket-key mutation with invalid typed metadata also returns uncertain. Typed
decode failures after any mutation cannot masquerade as local rejection; native
backend errors and pre-dispatch validation retain their original contracts.
Every regression observes exactly one POST and no replay.

All 602 library tests, strict Credo, canonical checks and actual precommit passed
locally with a disposable database; all 275 native resource-method/model cases
passed in focused verification before the final synchronous case was added.
Both runtime and consumer-pin push/PR CI at `b9cd50f`/`e71335f` passed macOS/Linux
(runs `38213464296`, `38213468987`, `38213764939`, `38213768452`). Those platform
results precede this four-case uncertainty correction; fresh consumer, CI and
Greptile must verify the next published revision. Foundation 3.9/4.3 and separate
installed/Macus/gateway acceptance remain open.

The fresh independent consumer passed at uncertainty-corrected runtime
`51790ed85c55c204863d43690219c9754e26f47c`; its captured lock, default pin and embedding example now record that verified source.


## Accepted image tokens and blocked session close — 2026-10-12

Full-branch Greptile run `5094e3b6-f97a-4102-af40-b1c208aeeeae` reviewed
`9fa7b6295bf0a0f57da463a87b2c637afd74bd1c`, returned 3/5 and confirmed
the earlier accepted-response correction. Both P1 findings reproduced against
that published runtime: three malformed accepted image-token responses lost
their operation/response, and closing two blocked session channels returned
with live workers. Four permanent regressions now preserve uncertainty and
the original operation/response without a target copy or token replay, and
terminate all owned session channels under a shared close deadline.

All 606 library tests, strict Credo, canonical checks and actual precommit passed
locally with a disposable database stopped and removed afterward. The four
regressions failed on the preceding published runtime. Fresh immutable consumer,
macOS/Linux CI and Greptile must verify this correction after publication.
Foundation tasks 3.9 and 4.3, installed converters, Macus hardware and gateway
acceptance remain open.


## Isolated direct-backend gate — 2026-10-12

Foundation task 4.3 now passes at runtime
`2b308f8487a88cfd5b5397b505d61c044c317b19` on an explicitly authorized fresh
Incus 7.0.1 backend. Both Unix and authenticated hostname-verified HTTPS proved
inspection, mutation, stale ETag rejection, binary file transfer, native accepted
snapshot identities, polling completion and matching WebSocket operation events.
The successful run cleaned only its own resources; prior failed-run data is
retained. No Opsmaru supervisor, Endpoint or Repo ran.
See [the reproducible opt-in runner and exact evidence](real-incus-acceptance.md).
This closes 4.3 only; 3.9, installed converters, Macus integration/hardware and
gateway acceptance remain open. The fresh immutable Git consumer also passed
at the same runtime revision with hostile PHX_SERVER/PORT settings.


## Remaining origin conveniences — 2026-10-12

The unchanged native OCI oracle now verifies alias-architecture mapping using
an explicitly supplied host local architecture, native VM rejection and no-op
disconnect. SimpleStreams no-op disconnect and bounded origin HTTP handles
are verified against unchanged native GetHTTPClient/DoHTTP: 200/305/409 status,
binary bytes, ETags and duplicate query values. Independent fixtures prove
readiness, pre-I/O path validation, byte budgets and no redirect following.
All 69 focused OCI/SimpleStreams/native HTTP cases and all 614 library tests
pass. Strict Credo, canonical checks, actual precommit, strict OpenSpec and
whitespace checks pass with a disposable database stopped and removed afterward.
The manifest now retains 921 partial and 359 missing declarations; no complete
port claim is made. Foundation 3.9 remains open and 4.3 remains independently
verified. Fresh consumer/platform/review evidence must follow publication.

Exact-head macOS/Linux push and PR CI at `2b308f8` passed (runs `38217470045`
and `38217476107`). Two Greptile follow-up submissions at that runtime timed
out at the API before creating a job; full-branch review is being retried on
the published acceptance revision. The last completed review remains 3/5 at
`9fa7b62`, with both reproduced findings fixed at `2b308f8`.


## Copy uncertainty and acceptance backend binding — 2026-10-12

Full-branch Greptile run `8283176e-90e3-4186-bfd5-7b7c55fbbf06` reviewed
`16058278db93f52241ebfbef31a14b8d7c990bd5`, returned 3/5, confirmed all earlier
fixes and reported two P1 findings. Nine permanent regressions fail against the
published runtime: pull/push wrappers hid uncertain inner mutation results or
malformed accepted push tokens, and the actual acceptance entrypoint could
write before proving that its two configured transports shared backend state.
All 23 focused image/runner cases now pass after correction. Inner errors, raw
responses and all known operation URLs remain available; no POST is replayed.

The runner now checks matching server certificate pins and names, and absence
of the proposed project through both transports before any mutation. It then
requires visibility of its new project's random per-run description marker
before either volume suite. Private fixtures include different certificates,
an existing HTTPS project and cloned certificate/name with separate state; no
other backend receives a mutation. The isolated real v5 run independently
passed both full transport suites with this strengthened preflight and cleaned
only its successful resources. Earlier failed-run data is retained.

All 624 database-free library tests, strict Credo, canonical checks, actual
precommit and strict OpenSpec pass with a disposable test database stopped
and removed afterward. Fresh immutable consumer, platform CI and Greptile
must verify the published correction. Foundation remains 21/22: 3.9 open,
4.3 independently passed; installed converters, gateway and Macus integration/
hardware acceptance remain separate. Acceptance commit macOS/Linux push and
PR CI passed (runs `38218237414` and `38218242513`).


The fresh independent Git consumer passed at corrected runtime
`27c2f87471e1033572734763524d7a4158340652`; its captured lock, default revision
and embedding example now pin that immutable source. The finalized runner
also passed the complete isolated real v6 transport matrix at that exact
published runtime and cleaned only v6 resources.

Greptile follow-up on `27c2f87` was rejected before review:
"you've used all 50 trial reviews for this account". This is an account-access
gate, not a successful review or an unfixed finding. The last completed full
review remains `8283176e-90e3-4186-bfd5-7b7c55fbbf06` (3/5, both P1 findings
reproduced and fixed); restore review access for current-head confirmation.
Do not merge while 3.9 and current review remain open.


## Task 3.9: constants, origin metadata and local request contexts — 2026-10-12

The unchanged reference now verifies all 188 exported API constants, including
171 previously missing declaration rows. Regeneration verifies the exact native
export set and values. These are plain model data, not protocol activation.
SimpleStreams connection-info matches the native CA-configured origin/default
fields; independent checks prove no requests or credential-file reads, readiness
and owner isolation. All 20 concrete SimpleStreams methods have partial mappings;
full metadata/cache/delta/platform option coverage is still unverified.

RequestContext adds explicit finite absolute deadlines, first-terminal-reason
local cancellation and owner lifetime. Four Unix/HTTPS constructor/WithContext
cases compare native query, ETag and complete profile results. Native canceled
and deadline errors are compared; independent fixtures verify pre-dispatch
rejection, uncertain dispatched POSTs, socket cleanup, blocked exit-trapping
sinks, raw/WebSocket/event-callback cleanup, long poll sleeps, retained native
operation data and adapter cancellation cleanup. Client binding remains immutable
under the host isolation contract rather than reproducing Go shared-pointer
mutation. No local cancellation sends backend DELETE or replays a mutation.

All 647 database-free tests and strict Credo pass. Canonical checks and actual
precommit pass with a disposable database stopped and removed afterward. All four
OpenSpec changes pass strict validation. The existing nested-download cleanup
regression initially could not identify the refactored guard; its identification
now includes guard_until, while actual suspension and all termination/cleanup
assertions remain intact. Focused verification and the full suite pass afterward.

The manifest now records 1108 partial and 172 missing declarations out of 1280,
complete_port=false. Foundation remains 21/22 with 3.9 open. Fresh immutable
consumer/platform checks must verify publication. Greptile trial quota remains
an external final-review gate; it does not stop implementation. Real-backend
4.3 and installed-converter/Macus/gateway acceptance remain separately recorded.


The fresh isolated Git consumer passed at continuation runtime
`e9d3921ddddccc563a4b98c4233d8689bf32b277`, including hostile PHX_SERVER/PORT
and passive startup. The captured dependency lock, default fixture pin and
Macus embedding example now record that exact immutable source. This does not
replace pending per-entry completeness, installed adapter or hardware gates.


## Stock macOS TLS fixture correction — 2026-10-12

The continuation CI failed on macOS (runs 38233018623/38233025415 and
38233451145/38233457928); Linux passed. Running the native context fixtures
with /usr/bin/openssl reproduced LibreSSL's explicit EC parameters and then
SHA-1 signatures, rejected by the unchanged Go verifier. Disposable CA/leaf
generation now explicitly uses named P-256 curves, SHA-256 signatures and
CA signing usage. No client TLS policy or native reference was relaxed.
A permanent certificate-signature assertion accompanies the native checks.
All 19 focused tests pass with stock LibreSSL; all 648 library tests, strict
Credo, isolated canonical checks, actual precommit and strict OpenSpec pass.
Platform CI must verify the published correction.

The user approved independent review in place of quota-blocked Greptile on
2026-10-12. The review gate now requires independent current-source review;
no Greptile follow-up success is claimed. Task 3.9 remains open.


## Task 3.9: native file headers and pure projections — 2026-10-12

All 658 database-free library tests and strict Credo pass. Isolated canonical
checks and actual precommit pass; the disposable database was stopped/removed.
All four OpenSpec changes pass strict validation. The 188-constant verifier
and Go inventory/schema regressions pass. Ten permanent helper tests cover
ParseFileHeaders and the server-filter/event-log native projections, including
an actual binary Unix download with duplicate headers and overflow metadata.
Operation log context ordering is compared exactly; only unordered native map
contexts normalize pair order. Original models remain lossless and no log is
emitted. Eight declarations gain partial mappings, yielding 1116 partial and
164 missing declarations with complete_port=false. No task checkbox changes.

Independent source review of the context/transport/adapter changes and this
helper slice checked passive construction, absolute deadline/cancellation
propagation, uncertain mutation handling, cleanup, immutable model boundaries
and credential-safe diagnostics. Review tightened the new operation-log test
to preserve exact native context order, rather than normalizing an ordered
record. Existing ownership/stream/adapter/copy failure regressions remain in
the full suite. This is review of the continuation, not full-port acceptance.

The stock macOS crypto fixture correction passed locally with both LibreSSL
and Homebrew OpenSSL and the clean Git consumer passed at 1d038cd4886eb6123967231ce52b5c740c50b20e.
However macOS CI still failed its two native context HTTPS positive cases
(runs 38234980305/38234989410); Linux passed. Unchanged-native failure diagnostics
now report only public leaf fingerprints and offline verification errors to
distinguish certificate generation from served-chain mismatch. This remains
an unresolved platform gate; no passing-CI or complete-client claim is made.


The native CA failure is reproduced with disposable ambient OpenSSL v3_ca
defaults: the prior generator emitted duplicate basicConstraints/keyUsage
extensions, and unchanged native verification returned unknown authority.
Explicit request/CA configuration now emits unique extensions and verifies.
A permanent process-isolated ambient-default regression asserts unique OIDs,
SHA-256 signatures and native CA/hostname verification. Stock LibreSSL focused
20-case verification and strict Credo pass; no client verification or SDK patch
is introduced. Updated full/platform checks remain required.


## Task 3.9: configuration metadata and final CA regression checks

GetKeys compares native key defaults, nil entries, later-map replacement and
exact entity/group diagnostics including control/non-ASCII/non-BMP quoting.
Aliased entity/group maps now validate nested structure in Model and normalize
through the existing bounded native projection. Permanent tests reject malformed
entities/groups/keys, bound names/payloads, retain original data and prove no atom
creation. Independent review checked the string-alias key resolution against the
pinned schema, merge order, null/default handling and credential-safe errors.
Six more declarations gain partial evidence: 1122 partial and 158 missing.

All 663 library tests, strict Credo, isolated canonical checks, actual precommit
and strict OpenSpec pass with the explicit CA configuration correction. The
final non-BMP diagnostic case additionally passes its focused oracle test.
Task 3.9 remains open; no complete-port or installed/hardware acceptance claim.
The full published source still requires immutable consumer/platform results.


## Independent review corrections and OCI origin helper completion

Independent review rejects mismatched typed models in server/event/metadata
helpers; permanent regressions preserve valid models and raw native input. HTTP
options now reject duplicate keys before I/O, and adapter-only Unix OCI values
return a structured invalid-origin error instead of raising for an HTTP handle.

OCI connection-info/GetHTTPClient/DoHTTP compare unchanged native CA-configured
origin fields, binary HTTP results/status/ETag and duplicate query parameters.
Independent fixtures verify no credential-file reads or converter activation for
passive handles/metadata, readiness/owner isolation, explicit HTTPS, invalid paths,
request/response bounds, redirect rejection and uncertain canceled POSTs without
replay. All 56 focused OCI-origin/HTTP/SimpleStreams tests and strict Credo pass.
All 20 concrete OCI methods now have partial mappings; full registry/conversion
and protocol/option acceptance remain unverified. The manifest remains
complete_port=false: 1125 partial, 155 missing out of 1280.

The causally corrected CA passed macOS native verification. A subsequent older
CI run failed a 500 ms console owner-loss assertion; both cases passed 20
constrained-scheduler repetitions without changing that bound. Permanent failure
diagnostics now identify the remaining process/status/stack. Another macOS run
reported the OCI adapter's documented independent cleanup failure after a 60 ms
budget. That fixture now verifies either a primary deadline or a visible cleanup
failure retaining that exact deadline, and still requires worker termination,
exact call identity, one cleanup invocation and no retry. Cleanup-pending success
is never inferred. The older metadata PR CI passed both platforms (38237116439);
its push run retained the OCI assertion failure (38237110085).

Consumer resolution reported Decimal 3.1.1's newly published allocation advisory.
The compatible dependency requirement/lock now uses 3.1.2, and the fixture lock
will be captured again from the verified new source. See the
[maintainer advisory](https://github.com/ericmj/decimal/security/advisories/GHSA-6c27-994x-c52f).
Hex also reports the existing Cowlib structured-field encoder advisory; locked
Cowboy 2.19.0 has the default outgoing CR/LF response-header rejection described
by the [CNA mitigation](https://cna.erlef.org/cves/CVE-2026-43966.html). The portable
client uses Mint and does not call that encoder; no blanket dependency-audit or
future gateway acceptance is claimed. Macus source and the native pin are unchanged.


The finalized continuation passes all 667 database-free library tests, warnings-as-
errors compilation, strict Credo, canonical checks and actual precommit with a
disposable test database stopped/removed afterward. Strict OpenSpec validates all
four changes and the unchanged 188-constant verifier passes. No runtime/library
coverage claim is based on the earlier green metadata PR alone: the final
published revision requires its own immutable consumer and macOS/Linux checks.


A fresh isolated Git consumer passed at final runtime 97182a3cf118cd2253bb545fa7a06ce56bafac83,
with hostile PHX_SERVER/PORT and no database/provider configuration. The actual
captured lock, default consumer revision and embedding example now pin that
source, including Decimal 3.1.2. Exact platform check outcomes are recorded on
[the draft foundation PR](https://github.com/upmaru/opsmaru/pull/1); task 3.9
remains open, independently of direct-backend 4.3 and installed/hardware gates.

## URL, copy matrix and relay cleanup continuation (2026-10-12)

Published runtime `f1eea66127c7bb0ed89f385b3f30bed4d526a44f` adds the bounded
immutable native URL builder and strict copy/migration option validation. Native
fixtures compare all boolean copy combinations in pull/push modes across local
and separate HTTPS endpoints, active/inactive source states and same-origin
cluster member/internal-copy/project variants. Relay peers observe every opened
socket close after a later upgrade rejection and after caller loss. Accepted
handles survive errors; these fixtures issue no mutation retries or DELETEs.

The unchanged Incus v7.0.1 reference inventory, model schemas and Go locks match
the prior verified revision byte-for-byte. Eight URL exports and the URL type
gain partial evidence: 1134 partial, 146 missing declarations; complete_port=false.
No other mapping becomes complete. Task 3.9 remains unchecked with its remaining
supported-entry/protocol completeness gates visible in the closure ledger.

Greptile review `5c8949b1-a836-4ab0-b642-3285f32cc998` gave the continuation
5/5 and one P2 finding. The full historical branch exceeded its payload limit
before submission; this single completed sweep reviewed base
`8a8a9b224fc3aefbf2a614fd4872eabd739cbc61` through
`32228aa4277083571701a35ce81a9e3301bc6952`. Its ancestry was also verified locally.
Both improper-list URL crashes were independently reproduced against that source.
The published correction rejects malformed lists with bounded proper-tail checks
and permanent regressions; no second Greptile sweep was requested. The score
does not claim a whole-branch review or satisfy the open merge/3.9 gates.

Post-correction validation passes all 679 database-free library tests,
warnings-as-errors compilation and strict Credo. Canonical `mise run check` and
actual `mix precommit` pass against disposable PostgreSQL (five scaffold tests
each); the cluster is stopped and removed. All four OpenSpec changes validate
strictly, and the 188 native constant comparisons and Go inventory/schema checks
pass. A fresh isolated Git consumer passes at the exact published runtime with
hostile PHX_SERVER/PORT, no database/provider configuration and no sibling checkout.
Its actual captured lock, revision file and Macus embedding example now pin that
source. Hosted macOS/Linux check results are recorded on the draft PR separately.

No new real backend, installed converter, gateway or Macus hardware acceptance
was attempted. The independently recorded direct-client 4.3 evidence remains at
its recorded runtime; Macus source and ordinary workload/data ownership are unchanged.


## Task 3.9: native status-error helpers

`test/status_error_reference_test.exs` builds the fixture-only
`test/reference/statuserror` driver with the pinned Go toolchain and compares
StatusErrorf, the literal StatusError zero value, Error, Status, StatusErrorMatch
and StatusErrorCheck. The pinned Go 1.25.14 `net/http` status text is embedded
and compared for every status 0..999 plus int64 extremes. Independent cases
reject invalid statuses, messages over 64 KiB and malformed/oversized code lists
without raising, and prove Inspect redaction. Focused 8-test run, library
compile with warnings as errors and strict Credo pass. Six declarations gain
partial evidence: 1140 partial and 140 missing. Task 3.9 remains open.


## Task 3.9: nested shared/api model schemas

`test/nested_models_reference_test.exs` (239 cases) builds the
fixture-only `test/reference/nestedmodels` registry of 79 unchanged native types
and compares acceptance, canonical round trips, schema/emitted key sets, empty
and null inputs, and per-field rejection with `Model.decode/2`. Value generation
is depth-bounded and the module has a timeout after an unbounded first draft
recursed through the SR-IOV card types. Recorded open difference: native RFC
3339 `time.Time` validation. Status-error bounded-walk evidence now compares the
rejected walk with a single native `length/1` pass rather than a fixed budget.
Focused runs, library compile with warnings as errors and strict Credo pass.


## Task 3.9: native YAML configuration decoding

`test/native_yaml_reference_test.exs` builds the fixture-only
`test/reference/nativeyaml` driver (unchanged go-yaml v4 into api.ConfigMap and
api.DevicesMap, optionally pre-populated) and compares a 318-row matrix covering
scalar resolution, tags, anchors/aliases, merge keys, duplicates, documents and
existing-map merges. Safety cases bound input/result size, prove a shape-valid
alias fan-out is rejected by the expansion budget in bounded time and memory
while a smaller one is accepted, create no atoms, never raise and leave yamerl's
application environment untouched. Reviewer randomized differentials (13,800
documents, twelve seeds, including dropped-key, merge-template and exponent cases)
found no mismatch after the Greptile and differential corrections. Library compile with warnings as
errors, strict Credo, 944 library tests, embedded startup and strict OpenSpec pass.


## Task 3.9: strict-subset YAML decoding

`test/native_yaml_reference_test.exs` now asserts the contract (native
result or rejection) on 310 reviewed rows and a seeded randomized set, requires
realistic Incus config/profile/device documents to equal native, pins the
recorded rejection categories against the native driver, and checks that
pathological documents are rejected within the 3 s test bound, near-limit
documents decode in under a second without leaving workers or messages, and
inputs never create atoms, raise or change yamerl's environment. Library
compile with warnings as errors, strict Credo, 935 library tests, embedded
startup and strict OpenSpec pass.


## Task 3.9: ServerFiltered YAML rendering

`test/server_yaml_reference_test.exs` builds the fixture-only
`test/reference/serveryaml` driver (unchanged `api.Server.Filtered()` with
go-yaml v4 `yaml.Marshal`) and asserts byte equality or rejection for realistic,
empty and null servers, a one- and two-atom string matrix used as values and
keys, and seeded randomized servers; recorded rejection categories are pinned
as natively rendered, and invalid input is rejected as natively. Library compile
with warnings as errors, strict Credo, 941 library tests, embedded startup and
strict OpenSpec pass.


## Task 3.9: operation handlers and remote-operation waits

`test/operation_handler_test.exs` builds the fixture-only
`test/reference/operationhandlers` driver (unchanged `operation.AddHandler` and
`RemoveHandler` on a DELETE-created operation) and compares delivered decoded
operations, removal results, already-successful (no target) and already-failed
(native error) operations, then checks backend/identity binding rejection
without I/O and Migration forwarding. `copy_negotiation_reference_test.exs`
compares native `RemoteOperation.Wait` with `Migration.wait_target/2` for
successful and failed targets. Library compile, strict Credo, the library suite,
embedded startup and strict OpenSpec pass.


## Task 3.9: response model types

`test/response_models_reference_test.exs` builds the fixture-only
`test/reference/responsemodels` driver with pinned Go and unchanged Incus v7.0.1
types. Twelve tests compare canonical envelope/default/alias fields, integer
validation and parsed RawMessage metadata, while independently extracting Go
float64 bits for ResponseRaw metadata. The seeded corpus has 1,600 comparisons
across valid and adversarial inputs. Boundary cases cover signed zero, nested
metadata, duplicate/ambiguous keys, lossless Model behavior, redacted errors,
invalid input, depth and near-1-MiB plain/escaped strings. Integer-mantissa
negative zero rejects on ResponseRaw because Jason loses its native float sign;
decimal negative zero compares exactly. Other native-accepted rejections and
raw JSON/YAML limitations are recorded in the closure ledger. Three declarations
gain partial evidence: 1235 partial, 45 missing, complete_port=false.
Final formatting, warnings-as-errors library compilation, strict Credo, all
959 library tests, passive embedded startup/restart and strict OpenSpec pass.
PostgreSQL and full standalone `mise run check` were not started; this slice
adds fixture evidence only, with no new installed service/backend/hardware
acceptance. External review remains for the next significant batch.


## Task 3.9: bounded SFTP v3 convenience helpers

The approved design section 4c defines the subset before implementation.
`test/sftp_helpers_reference_test.exs` builds `test/reference/sftphelpers`
using pinned Go, unchanged Incus v7.0.1 and pkg/sftp v1.13.10. Its 22 tests compare
both real convenience helpers over private Unix and verified mutual TLS:
project/member/upgrade requests, INIT/version/extensions, all five supported
open flags, native IDs, binary reads/writes through the 128-KiB limit, EOF and
file/session close, including handle invalidation after close failure. Thirty
seeded version/extension cases compare native acceptance and data. Independent
fixtures verify fragmentation/coalescing, malformed/oversized replies,
pre-dispatch bounds, cancellation, absolute deadlines, caller loss, idle EOF,
unrelated-process protection and shared-context isolation after stream expiry.
All 22 focused tests pass. Four method/interface entries gain partial evidence:
1239 partial, 41 missing, complete_port=false. Full client behavior, other
protocol operations and installed/backend/hardware acceptance remain separate.
Final formatting, warnings-as-errors library compilation, strict Credo, all
981 library tests, passive embedded startup/restart and strict OpenSpec pass.
Failure regressions retain original backend, identity, session and native request
ID after the process ends. PostgreSQL/full standalone `mise run check`, a new
Linux/consumer build and significant-batch review were not run for this slice;
those remain distinct gates. No service, real backend or Macus state was changed.

## Extraction into opsmaru-incus — 2026-10-13

Source `upmaru/opsmaru` `a00805d` was extracted with history; all 195 carried
files were byte-identical to the source apart from `test/library/` becoming
`test/`. At `3c5d6b1` (macOS, local): warning-free compile, format check,
strict Credo (1865 mods/funs, no issues), 981 database-free fixture tests with
0 failures, strict OpenSpec validation, Go inventory/schema verifier tests, 188
generated constants verified and byte-identical `coverage.json` regeneration
(1239 partial, 41 missing declarations; `complete_port=false`). The isolated
consumer built and passed against pushed revision `3c5d6b1` over HTTPS with no
sibling checkout or Opsmaru application. The consumer test moved out of the
library suite (982 to 981 tests). Linux CI evidence for this repository is
pending its first run. Task 3.9 remains open.
