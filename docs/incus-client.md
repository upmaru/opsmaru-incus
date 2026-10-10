# Public portable Incus library

The library is usable independently of Opsmaru startup, SQL, Macus, Swift or a
central service. Fixture-tested slices are listed below. This is **not a
complete Incus client port**: `priv/incus/coverage.json` records every pinned
reference declaration and keeps missing coverage visible (`complete_port=false`).

| Public API | Contract |
| --- | --- |
| `Opsmaru.Context.new!/1` | Host-supplied owner, verified identity, local readiness and private state/capability references; no provisioning or token verification |
| `Connection.unix!/2`, `https!/2` | Passive immutable connection values; explicit project/member and resource budgets |
| `Incus.connect/2` | Explicit authorized discovery; native version and extensions, bound connection/context |
| `Incus.project/2`, `member/2` | Immutable native project/target selection |
| `Incus.has_extension?/2`, `require_extension/2` | Explicit discovered extension checks |
| `Incus.call/4`, `methods/0` | Native method names, native string-key argument map, `body:` and `etag:`; missing names fail explicitly |
| `Incus.raw_query/3`, `/4`, `/5` | Low-level native JSON envelope; no typed-parity claim |
| `Model.decode/2`, `encode/1` | Pinned native field schemas, preserving null/unknown fields without atom creation |
| `Images.import/4`, `download/4`, `copy/4` | Bounded unified/multipart binary handoff; pull/push and host-staged relay copies retain native operations |
| `Files.read/4`, `create/5`, `backup_import/3`, `backup_download/4` | Binary files, separate directory metadata, native UID/GID/octal mode and backup headers |
| `Files.volume_read/6`, `volume_create/7`, volume/bucket backup helpers, `backup_stream/4` | Native volume/bucket byte handoff; further differential coverage remains required |
| `Incus.sftp/2`, `nbd/3`, `volume_sftp/4`, `volume_nbd/5` | Native raw 101 byte channels; consumers supply their SFTP/NBD implementation |
| `RawChannel.recv/2`, `send_data/2`, `shutdown_write/1`, `close/1` | Bounded binary duplex and native half-close |
| `Operation.from_response/2`, `poll/1`, `wait/2`, `cancel/1`, `websocket/2` | Bound native handles; authoritative completion and supported cancellation |
| `Events.subscribe/2`, `next/2`, `close/1` | Native events through an owner-monitored bounded WebSocket queue |
| `Session.exec/3`, `console/3`, `input/2`, `output/3`, `control/2`, `resize/3`, `signal/2`, `exit_status/1`, `close/1` | Native operation channels and control messages; local closure does not cancel Incus |
| `Copy.instance/4`, `snapshot/5`, `volume/6` | Native writable configuration, local/project copies and explicit migration preparation; accepted handles |
| `Migration.negotiate/5`, `relay/2` | Explicit native request tuples and approved origin, retaining both accepted handles; full reset/reconnection and helper parity remains incomplete |

Example conditional mutation and reconciliation:

```elixir
{:ok, profile} = Opsmaru.Incus.call(client, "GetProfile", %{"name" => "default"})
{:ok, updated} = Opsmaru.Incus.call(client, "UpdateProfile", %{"name" => "default"},
  body: profile.metadata, etag: profile.etag)

{:ok, accepted} = Opsmaru.Incus.call(client, "CreateInstance", %{}, body: native_instances_post)
{:ok, operation} = Opsmaru.Incus.Operation.from_response(client, accepted)
# Accepted is not completed. A deadline leaves this native handle available.
Opsmaru.Incus.Operation.wait(operation, timeout: 5_000)
```

JSON methods cover projects, profiles, certificates/access, instances/state/
snapshots, images/aliases, networks and their subresources, cluster members/
groups, storage pools/volumes/snapshots/buckets/keys/backups/bitmaps, operations,
metadata and warnings. Each declarative entry in `methods.json` runs the actual
unchanged official typed Go method and compares query, normalized native body,
ETag, response model, unsupported extensions and separate HTTP/native errors.
Bodies may contain future native fields; optional/null fields remain lossless.
Schemas alone do not establish all-field, helper or complete model parity.

Response fields retain native metadata, errors, ETags, HTTP/native status codes
and operation URLs. `async` means accepted. Possibly accepted mutations with a
lost/malformed response return `:uncertain` without retry. Polling or local
stream timeout never cancels an operation. Cancellation first polls
`may_cancel`, issues at most one DELETE and still requires reconciliation.
Readiness is a fast, local host callback, not a backend startup hook.

HTTPS uses peer trust, hostname and certificate validity checks. Hosts select
CA and client certificate/private-key files, or an exact SHA-256 server pin.
A pin without a CA allows only matching self-signed/unknown-CA peers; combined
CA plus pin requires both. Keys are read only by an authorized connection.
Inspect and process status redact payloads, endpoints, identities and secrets;
raw maps/native metadata remain privileged values that hosts must not log.
No mutable global remote, trust generation, backend install or address fallback
exists. Migration pull/push requires the exact explicit HTTPS origin; advertised
addresses are not followed. Failures preserve accepted handles and backend data.

Mint 1.11.0/hpax 1.1.0 and MintWebSocket 1.0.5 are locked. HTTP requests have
connection/send/receive deadlines and header/body budgets. Transfers use bounded
binary chunk enumerables and acknowledged sinks, covered by a total deadline.
Stream actors monitor the owner, limit lifetime, message/frame/byte queues and
close sockets on errors or local close. Overflow is visible; reconcile against
operation polling. Optional host concurrency supervision rejects capacity with
no pending queue or replay. A local success is never hardware acceptance.

## Coverage limitations

The checked manifest currently has 268 differential JSON methods, 740 partial
reference mappings and 540 missing declarations out of 1,280. Interface entries
and schemas account for some mappings; these counts are not 734 distinct client
operations. Schema-derived field validation and positive fixture results do
not establish full Incus semantic behavior. `scripts/update-incus-coverage.py`
regenerates mappings and checks evidence paths, never relabeling partial as full.

Local instance/snapshot/volume copy requests are compared with official helpers;
HTTPS pull/push descriptors and binary relay EOF are independently verified.
Remaining parity includes complete cross-cluster/copy option matrices, migration
reset/reconnection semantics and complete relay-channel evidence,
full SFTP protocol helpers, dynamic console/recorded-output helpers, all-field
model/helper behavior, streaming backup variants and every currently missing
inventory entry. Newly added volume/bucket helpers remain unaccepted where
independent differential evidence is absent. Do not treat `raw_query` success
as typed support. Linux CI, installed service and real-backend results are
recorded separately in `foundation-validation.md`.

## Known pinned oracle limitations

At Incus v7.0.1 SHA `13f3992766142d5087fff2e362cd2e1a75294fe8`,
`rawConn` uses `http.ReadResponse(bufio.NewReader(conn), req)` and returns the
underlying socket, discarding prefetched protocol bytes. Official SFTP/NBD
fixtures pass when headers/data arrive separately but lose coalesced `00 ff 80`.
Opsmaru preserves these bytes as required by the approved native-stream spec;
independent raw and verified HTTPS fixtures prove that behavior. The unchanged
oracle defect is recorded, not treated as correct behavior or an approval gate.

The official console helper with nil I/O accepts its POST before returning
`A terminal must be set`; the method fixture compares the POST and separately
checks this error. Actual channel/control behavior is checked independently in
`session_test.exs`. Private-image positive comparisons use native hexadecimal
secrets; the pinned Go private-image helper double-escapes special-character
secrets. No upstream patch or real workload is used by these fixtures.
