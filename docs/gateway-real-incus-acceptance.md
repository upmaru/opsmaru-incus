# Gateway real-Incus gate (G6 / 7.4)

The live gateway gate is **incomplete** because strict NBD stays unrun. The
latest isolated run (2026-11-09) at source
`9224c71700c801105128293b81e75468e2f1a5d0` completed every other case.

## 2026-11-09 run on a flow-relay test appliance

The backend was a throwaway Macus appliance in an isolated state directory. It
ran an unmerged Macus feature build (`1085025`) that serves only the
flow-controlled vsock relay. The appliance reported Incus 7.0.1, server name
`tama-incus` and certificate SHA-256 `e7571648…d502b`. It also ran an
unqualified 6.18.62 kernel/ZFS pair. One daemon served both sides through two
fresh projects (`…-src-20261109-fr3-r15` and `…-dst-20261109-fr3-r15`). The
unchanged pinned v7.0.1 CLI (SHA-256 `0ae2c213…`) and native driver
(`c2f4fc09…`) used isolated `INCUS_CONF` and test-only trust.

| Area | Result |
|---|---|
| Discovery, enrollment, HTTP, binary, exec, console, events, SFTP | passed |
| Denial and interruption | passed. The interrupted operation was reconciled with one gateway POST and zero gateway DELETEs. |
| Instance and snapshot copy, relay/pull/push × each gateway orientation (12) | passed. Each destination canary SHA-256 matched. |
| Instance move, relay/pull/push × each gateway orientation (6) | passed |
| Snapshot move (6) | `native_limitation`. The pinned CLI got 400 before any migration request reached the gateway (zero gateway POSTs or DELETEs). This is the user-accepted pinned-native snapshot-move limitation from task 6.2. |
| NBD | `unrun`. The instance case is VM-only, and none was provisioned. The custom-volume strict read-only verifier failed identically directly and through the gateway with `native_nbd_readonly_unavailable`. |

All 119 recorded steps passed, and the phase ended
`partial-resources-retained`. The gateway issued no replay or cancellation.
Both daemon peer probes were verified. The report keeps `installed_host` and
`macus_hardware` at `unrun`, and typed-client coverage is unchanged.

This run supersedes the earlier relay copy failure. That failure matched a
Macus vsock head-of-line stall, not a gateway defect. With the flow-controlled
relay, all twelve copies and six instance moves completed. This is not Macus
hardware or ZFS qualification evidence, because the appliance runs an
unqualified kernel/ZFS pair on an unmerged Macus build. Task 7.4 stays
unchecked until NBD either passes or the user explicitly accepts it as a
native limitation.

Operator notes from this session:

- Run the live entrypoint with `MIX_ENV=test`. The gateway host needs the
  test-only `plug_cowboy` dependency. Without it, the host fails before any
  backend contact.
- Start the runner with stdin at `/dev/null`. Native commands are spawned
  with `:in`, so they inherit the runner's stdin. If stdin is an open pipe,
  `incus snapshot create` waits for YAML until the step times out.
- Fixture credentials must be within their validity window. Expired test
  certificates fail anonymous discovery as `native_verifier_failure`.

Three earlier attempts in the same session left only test resources on the
throwaway appliance. r12 stopped before backend contact. r13 created two
empty projects before the credential failure. r14 timed out on the first
snapshot setup after passing sixteen cases, including all six instance
copies. Their resources and private journals are retained there.

## Earlier history

The isolated run at source
`2ebc4a6ee3246134105cc4265dc14ecb26ba0a07` passed ten protocol cases, left NBD
unrun, and failed its first instance relay copy. During that copy a backend
metadata connections repeatedly closed before a parsed response throughout the
original 12-second cache window. The host preserved its original timestamps,
then correctly expired authority. An earlier independent unchanged native Go
client also received EOF during the same type of gateway copy. The latest run
verified that its fresh ZFS root disabled per-volume reservation, and retained
its resources and private journal after failure. No successful real migration
matrix is claimed.

An operator-only control also bypassed the gateway and used the unchanged pinned
native SDK against the same supplied daemon and two isolated projects. Distinct
native Unix socket paths prevented the SDK's local-copy optimization, so the
control entered its relay migration path. One copy attempt accepted two native
operations and reached its 120-second local deadline. Subsequent read-only
reconciliation found both operation IDs absent (their final outcomes remain
unknown), no pending operations and no destination instance. The source retains
two stopped test containers and two custom volumes. This diagnostic is separate
from gateway acceptance and does not mark migration passed or accept a new
native limitation. The original reports and private control journal are retained.

Portable gateway fixtures and the immutable host consumer produce separate
evidence, including 18 successful fixture migrations and six accepted pinned
CLI snapshot-move limitations. Those results do not establish live Incus,
installed host or Macus hardware acceptance. Historical direct-client and
shared-operations runs in `real-incus-acceptance.md` do not authorize a new
gateway run or select a current backend.

`python3 scripts/gateway-acceptance-preflight.py` checks explicit private input
references and writes a fresh owner-private **unrun** report. Select its JSON
with `OPSMARU_GATEWAY_ACCEPTANCE_CONFIG=/absolute/private/config.json`. It makes
no backend connection, invokes no CLI, starts no listener and performs no
backend mutation. This prepares inputs for task 7.4; it is separate from the
explicit live runner, `scripts/accept-incus-gateway.exs`, and its retained
execution reports.

The configuration has this shape (all credential values are file references):

```json
{
  "allow_namespaced_mutations": true,
  "expected_version": "7.0.1",
  "project": "opsmaru-acceptance-gateway-unique-run",
  "report": "/absolute/private/fresh-preflight-report.json",
  "source": {
    "gateway": {
      "https": "https://source-gateway.example:8443",
      "server_certificate": "/private/source-gateway.crt",
      "client_certificate": "/private/test-client.crt",
      "client_key": "/private/test-client.key"
    },
    "backend": {"socket": "/explicit/private/source-incus.sock"},
    "image": "approved-local-image-fingerprint-or-alias",
    "pool": "approved-test-pool"
  },
  "target": {
    "gateway": {
      "https": "https://target-gateway.example:8443",
      "server_certificate": "/private/target-gateway.crt",
      "client_certificate": "/private/test-client.crt",
      "client_key": "/private/test-client.key"
    },
    "backend": {"socket": "/explicit/private/target-incus.sock"},
    "image": "approved-local-image-fingerprint-or-alias",
    "pool": "approved-test-pool"
  }
}
```

A backend can instead provide the same explicit `https`, `server_certificate`,
`client_certificate` and `client_key` fields. The preflight checks syntax and
file availability only. Each side can override `project` with its own fresh
`opsmaru-acceptance-gateway-...` namespace, allowing one backend with two isolated
projects. Distinct connection descriptions do not prove distinct backends.
The live runner independently verifies authenticated
backend identity and version, project absence and a fresh run marker before
scenario mutations. Configurations and reports stay outside Git. Existing
reports are never overwritten; unavailable inputs produce no report.

Live execution additionally requires an explicit `network` name on each side.
After verifying backend identity, the runner reads both selected networks and
requires matching names, managed status and native `Created` readiness before
creating either project. The new instance NIC uses that verified binding.
The config-only Python preflight does not establish network readiness.
Both sides must select the same network name because the unchanged default CLI
copies preserve NIC definitions; different names are rejected before backend access.

The live suite mounts the host-owned gateway and uses the
unchanged pinned client/CLI with isolated `INCUS_CONF` and test-only trust. It
must cover HTTP/binary transfers, enrollment and denials, exec/console/events,
instance and custom-volume SFTP/NBD, instance/snapshot copy and move in
relay/pull/push modes with each gateway orientation, and interruption/native
error reconciliation. Host policy must supply verified pending migration
operation bindings, including project and peer authority. Actual native
server peers may have no client certificate and operation WebSockets may omit
the project query.

Keep gateway-owned replay/cancellation counts distinct from retries and
cancellation issued by the unchanged native client. Record exact source,
client/tool hashes, native operation identities and the resource journal.
Failures retain resources for explicit reconciliation; cleanup after a fully
successful run applies only to resources created under its verified fresh
namespace. No default socket, remote discovery, runtime boot, installation or
production data is part of this gate.

Initial journal creation and each replacement check the write, sync and close
results. Replacements sync the new file before rename and then sync the parent
directory; initial creation also syncs its parent. The following backend mutation
is permitted only after these barriers succeed. Unsupported directory sync or
any persistence error fails closed. Files remain private (`0600`), and failed
replacement does not advance the in-memory journal or replay a mutation.

The custom-volume NBD verifier keeps its strict read-only transmission-flag
requirement and requests `Writable: false`. If that exact local verifier
condition occurs through the gateway, the runner compares it with the same
unchanged helper directly on the same owned volume. Only matching
`native_nbd_readonly_unavailable` results leave NBD `unrun` and allow denial,
interruption and migration checks to continue. Unknown or mismatched errors
stop the run. This does not accept an NBD parity exception, mark NBD passed or
complete task 7.4; the incomplete ledger retains resources for reconciliation.

Unexpected native CLI exit results also retain a bounded operator-only diagnostic
sidecar in the run's private `0700` state directory. Each exclusive `0600`
`cli-failure-<digest>.log` contains combined CLI output, which may include
sensitive native details. The JSON journal contains only the exit status,
output SHA-256, digest-only artifact basename and a small local host-health
snapshot; it never includes that raw output. Health records only each side's
readiness flag, last-poll age, owner liveness and known-operation count. A
missing or unresponsive Agent produces an unavailable snapshot after a bounded
local read, without network queries or a state dump. This applies to migration
and setup CLI exit failures and does not retry
the command or alter the resource-retention/completion gate. Keep these
sidecars private with the run state; do not publish them as report artifacts.

The explicitly started live host uses the client's canonical 5-second metadata
request timeout. Its two sequential project/operation reads have a freshness,
operation-binding TTL and initial-readiness bound of twice that timeout plus
2 seconds of scheduling slack (12 seconds at the default), with a 100ms polling
cadence. Hand-built host fixtures keep their 2-second freshness and 5-second
binding defaults. These are acceptance-host settings, not production gateway
or lease policy changes. Only metadata GET `connection` or `response_closed`
errors with no HTTP status may retain an already-ready host's original cache.
They never update `last_poll` or operation expiry, learn an unknown operation,
or turn initial unready state into ready state; an initial failure stops that
poller. New trusted requests may also use the original cached authority during
its remaining lifetime. Certificate grants still consult current trust.
At cache expiry fresh admission fails immediately; existing channels observe
that expiry at their unchanged bounded lease recheck (5 seconds for this host).
Hard native/model/schema, ownership, cancellation and marker failures clear
authority immediately. Both blocked reads are followed by local owner/lifetime
checks before renewal. Hard project failures stop; hard operation-list failures
retain the existing read-only polling behavior.

`response_closed` identifies only an exact Mint closed transport error with no
prior parsed response and an empty current response-event batch. Any parsed
status, including truncated 403/404, malformed HTTP and deadlines stay hard.
Partial unparsed status-line bytes cannot be distinguished from an early EOF;
this does not claim that no raw bytes arrived. The library never retries, and
mutation errors remain uncertain. At most 15 transient details plus one
replaceable decisive detail per side record safe stage/kind/status, elapsed
time and remaining cache bounds, without messages, metadata or secrets. A
decisive expiry or hard failure remains visible after transient suppression.

Console proof uses the unchanged native console helper plus one fixed native
exec command in the owned test container. The command writes a fresh ASCII
nonce, passed as an argv value, to `/dev/console`; a login prompt alone cannot
satisfy the case. The helper clears its temporary control write deadline and
requires the captured console bytes to contain the nonce. Before waiting for
the writer operation, it sends an allowlisted progress record and waits for
the source-owned runner to journal its UUID and nonce SHA-256. Reports retain
only hashes, operation identities, byte counts and local-detach/no-cancellation
proof, never the nonce or console output. Producer failures and missing proof
still fail without a retry.
