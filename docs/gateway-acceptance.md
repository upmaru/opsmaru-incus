# Gateway conformance and evidence

`mise run check:consumer` builds a supplied immutable Git revision in a fresh
temporary consumer. The consumer has its own Phoenix 1.8.15 endpoint and router,
with the gateway's Cowboy dispatch on that endpoint's TLS listener. Native HTTP,
WebSocket and raw SFTP/NBD requests all traverse this consumer-owned listener.
The ordinary consumer endpoint and `/runtime` and `/mcp` host routes retain host
ownership. Neither dependency loading nor `Gateway.new!` starts the gateway.

Run against a pushed source revision:

```sh
OPSMARU_INCUS_FIXTURE_REVISION=<full-40-character-commit> \
OPSMARU_INCUS_GATEWAY_REPORT=/absolute/new/report.json \
mise run check:consumer
```

The report path must not already exist. The optional
`OPSMARU_INCUS_FIXTURE_REPOSITORY` override supports local development clones;
such runs are development fixture evidence, not published-revision acceptance.
The default repository is `https://github.com/upmaru/opsmaru-incus.git`.
The script checks the fetched dependency's exact commit and clean working tree.
The report separately identifies the verifier's source commit, cleanliness and
fixture/driver source hashes because the harness may differ from the dependency
revision being verified. It never copies a sibling checkout into the dependency.

The verifier builds the unmodified Incus v7.0.1 CLI from the module ZIP at
`13f3992766142d5087fff2e362cd2e1a75294fe8`, checks its origin and checksum against
the reference pin, and verifies both the reference and CLI dependency caches.
It records module ZIP and binary SHA-256, module checksum, exact Go tool version
and local `--version` output. The CLI is temporary verifier tooling; it is never
installed or started as a service. Every conformance invocation uses a private
`INCUS_CONF` with ephemeral test-only credentials and explicitly selected remotes.
Build provenance uses the local `--version` flag, never the `version` subcommand
which contacts a configured server.

The independent native suite covers discovery and certificate enrollment,
native HTTP errors and a complete binary file create/get/delete lifecycle,
including normal native discovery and its `file_delete` capability guard, exec/console/events and
operation WebSockets, instance/volume raw SFTP/NBD helpers, actual pkg/sftp binary
read/write/close, and the CLI copy/move matrix: instances and snapshots, relay,
pull and push, with the gateway as source and target. The latter is 24 cases.
Instance CLI move verification observes the CLI's explicit successful source deletion;
gateway disconnect cleanup never synthesizes that deletion. The pinned CLI's
snapshot move has an upstream limitation: its instance-only grammar calls the
instance GET path with `source%2Fsnapshot`; the pinned server rejects
snapshot names on that route with native `400 Invalid instance name`. All six
snapshot move combinations record this failure before any migration mutation
and retain the source. The
matrix therefore has 18 successful transfers and six upstream CLI limitations;
it does not establish working snapshot moves. The user accepted this documented
pinned CLI limitation as native parity on 2026-11-07; the report preserves all
six unsupported outcomes. Native migration
server connections present no client certificate and omit the project query;
the test host binds them to the already verified pending operation/project and
actual peer. The backend still checks the operation secret.

The approved pinned `rawConn` oracle exception remains visible: unchanged native
raw helpers receive their first protocol bytes separately from the 101 headers.
Separate library fixtures enforce the stronger coalesced-byte exactly-once
contract. A raw echo helper alone does not count as a complete SFTP session.

GitHub CI runs the canonical/reference checks and this independent consumer on
both Linux and macOS. Use private temporary directories when running concurrent
BEAM suites. On hosts with ambient tool paths, `MISE_ACTIVATE_AGGRESSIVE=1` keeps
the pinned tools ahead of system installations.

Evidence classes stay distinct:

| Evidence | Meaning |
| --- | --- |
| Library fixtures | Database-free Unix/HTTPS protocol, policy and lifecycle checks |
| Immutable consumer | Published Git dependency, independent endpoint and pinned native conformance |
| Typed client ledger | Separate declaration/differential evidence; gateway passes never change it |
| Isolated real Incus | Explicitly configured native scenarios; unrun without opt-in |
| Installed host / Macus hardware | Consumer-owned installation, bridge, package and hardware acceptance |

See [real gateway acceptance](gateway-real-incus-acceptance.md) for the opt-in
preflight and the outstanding real-backend gate. No portable fixture pass proves
an installed Macus gateway or hardware acceptance.
