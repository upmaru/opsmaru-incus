# Gateway real-Incus gate (G6 / 7.4)

The live gateway gate remains **unrun**. Portable gateway fixtures and the
immutable host consumer produce separate evidence; neither establishes live
Incus, installed host or Macus hardware acceptance. Historical direct-client
and shared-operations runs in `real-incus-acceptance.md` do not authorize a new
gateway run or select a current backend.

`python3 scripts/gateway-acceptance-preflight.py` checks explicit private input
references and writes a fresh owner-private **unrun** report. Select its JSON
with `OPSMARU_GATEWAY_ACCEPTANCE_CONFIG=/absolute/private/config.json`. It makes
no backend connection, invokes no CLI, starts no listener and performs no
backend mutation. This is preparation for task 7.4; the live protocol runner
and its execution remain outstanding until the isolated setup is supplied.

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
A live runner must independently verify authenticated
backend identity and version, project absence and a fresh run marker before
scenario mutations. Configurations and reports stay outside Git. Existing
reports are never overwritten; unavailable inputs produce no report.

The outstanding live suite must mount the host-owned gateway and use the
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
