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
| Database-free `mise run check:library` | 441 tests passed with the expanded task 3.9 fixtures | macOS local fixtures; full parity incomplete |
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
| macOS/Linux CI | 441 core tests and clean immutable consumer passed on both platforms at 2827c6ea1e8ef3f9ff3205a70148bba197e4cb59 | Protocol fixtures only; no real Incus/Macus |
| Independent immutable consumer | 1 clean consumer test passed at published 2827c6ea1e8ef3f9ff3205a70148bba197e4cb59 | Fetched from GitHub into a disposable directory; resolved consumer lock recorded |

The coverage manifest records 268 differential JSON methods, 877 partial
reference mappings and 403 missing declarations. Missing entries prevent a
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
against one fresh disposable test database; both 5-test scaffold runs passed.
Greptile CLI review is requested but currently blocked: the authenticated account
reports `upmaru/opsmaru` as not connected. Automatic approval review rejected
`greptile init` because it changes persistent repository/organization access;
explicit approval is pending. No Greptile acceptance is claimed.

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

Visible client gaps include server preseed, full dynamic console callback/IO and
SFTP protocol helpers, direct HTTP/WebSocket/context convenience helpers,
OCI/SimpleStreams sources, event/operation handlers, remaining type/JSON/YAML
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
