# Foundation verification — 2026-10-10

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
| Database-free `mise run check:library` | 343 tests passed with copy and migration regression fixtures | macOS local fixtures; full parity incomplete |
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
| Inventory and schemas regenerated | 1,280 entries/86 source hashes; byte-for-byte match | Inventory/schema presence is not coverage |
| Go inventory parser regressions | Passed | Verifier-only tooling |
| `mise run check` via `python3 scripts/check-isolated.py` | Format, warning-free compile, assets, 5 web tests, embedding and strict specs passed | New disposable UTF-8 PostgreSQL cluster, stopped/deleted afterward |
| Strict OpenSpec validation | All three changes passed | Artifact consistency, not runtime acceptance |
| macOS/Linux CI | 343 core tests and clean immutable consumer passed on both platforms at 8449648eab8d4c1dd1f5b793ed060185b7575938 | Protocol fixtures only; no real Incus/Macus |
| Independent immutable consumer | 1 clean consumer test passed at published 8449648eab8d4c1dd1f5b793ed060185b7575938 | Fetched from GitHub into a disposable directory; resolved consumer lock recorded |

The coverage manifest records 268 differential JSON methods, 754 partial
reference mappings and 526 missing declarations. Missing entries prevent a
complete-port claim. See `incus-client.md` for the exact API and limitations.
The v7.0.1 rawConn prefetch defect is negative oracle evidence; Opsmaru's
required preservation behavior is independently checked without patching the
oracle or treating the discrepancy as an approval gate.

The independent consumer supplies its own Phoenix endpoint, runtime readiness,
private backend and secrets, and calls the client with Opsmaru stopped. It uses
Phoenix 1.8.15, Mint 1.11.0, plug_cowboy 2.9.0, Cowboy 2.19.0 and TamaMCP 0.1.1.
`scripts/check-consumer.py` builds the exact requested Git revision in a new
temporary directory, with no source path dependency or sibling checkout.

Final platform run: https://github.com/upmaru/opsmaru/actions/runs/38068178025.
OpenSpec progress is 20/22: task 3.9 remains open for remaining reference parity;
task 4.3 remains open for explicit isolated real-backend acceptance.

Remaining gates: complete canonical copy/migration option and missing method/type
coverage; explicit isolated live Incus Unix/HTTPS mutation/operation/stream
acceptance; consumer-owned installed Macus/VZ/hardware acceptance. Real-backend
and hardware acceptance remain unchecked without explicit opt-in. No merge,
release tag, deployment or OpenSpec archive is performed by these checks.

The clean consumer reports the existing cowlib 2.21.0 advisory
[EEF-CVE-2026-43966](https://osv.dev/vulnerability/EEF-CVE-2026-43966).
Hex confirms 2.21.0 is the latest release at this check. The pinned Cowboy
2.19.0 source retains the default `invalid_response_headers: error_terminate`
guard in HTTP/1 and HTTP/2, matching the
[CNA documented mitigation](https://cna.erlef.org/cves/CVE-2026-43966.html).
The portable client uses Mint and does not invoke Cowlib structured-field
builders. This records the advisory and mitigation; it is not blanket security
or standalone-service acceptance, and host applications still own their headers.
