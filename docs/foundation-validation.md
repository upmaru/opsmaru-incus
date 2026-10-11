# Foundation verification — 2026-10-11

This is fixture/library evidence for `add-embedded-incus-foundation`, not full
client, installed-service or real-backend acceptance. The approved scaffold
was extended on `feature/phoenix-bootstrap-and-remote-access`; no phx.new,
Macus source modification, VM startup, backend install or workload mutation
was used. Full copy/migration option and remaining reference parity remain incomplete.

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
