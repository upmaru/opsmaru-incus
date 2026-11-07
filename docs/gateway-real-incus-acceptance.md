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
