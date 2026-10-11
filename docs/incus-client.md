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
| `Discovery.connection_info/1`, `clustered?/1`, `agent?/1`, `require_authenticated/2` | Authorized passive discovery helpers and immutable native authenticated requirement; advertised addresses remain metadata |
| `Incus.project/2`, `member/2` | Immutable native project/target selection |
| `Incus.has_extension?/2`, `require_extension/2` | Explicit discovered extension checks |
| `Incus.call/4`, `methods/0` | Native method names, native string-key argument map, `body:` and `etag:`; missing names fail explicitly |
| `Incus.raw_query/3`, `/4`, `/5` | Low-level native JSON envelope; no typed-parity claim |
| `NativeConfig.from_json/3` | Explicit ConfigMap/DevicesMap JSON coercion and existing-key merge, with byte/type bounds; no YAML parser |
| `Model.decode/2`, `encode/1` | Pinned native field schemas, preserving null/unknown fields without atom creation |
| `Model.writable/1`, `active?/1`, `etag_values/1`, `ModelURL.resource/2`, `parent_snapshot_name/1`, `Status.string/1`, `final?/1`, `from_string/1` | 23 writable projections, nine native resource URL helpers, five ETag input tuples and pinned status semantics; original model remains lossless |
| `Images.import/4`, `download/4`, `copy/4` | Bounded unified/multipart binary handoff; `download(..., secret: token)` matches native private exports; pull/push and host-staged relay copies retain native operations |
| `ImageInstances.create/5`, `rebuild/6` | Local images or one approved verified HTTPS source; native alias/fingerprint/private token preparation; accepted target handle without replay |
| `Files.read/4`, `create/5`, `backup_import/3`, `backup_download/4` | Binary files, separate directory metadata, native UID/GID/octal mode and backup headers |
| `Files.volume_read/6`, `volume_create/7`, `volume_delete/5`, volume/bucket backup helpers, `backup_stream/4` | Twelve native file/archive helpers have differential byte/header/query evidence; full option/platform/backend coverage remains separate |
| `Streams.metrics/2`, `network_acl_log/3`, `instance_logfile/4`, `instance_console_log/3`, `instance_template_file/4`, `create_instance_template_file/4`, `instance_debug_memory/4` | Native binary/text handoff to an acknowledged host sink or bounded source; no collector or implicit file writes |
| `Incus.sftp/2`, `nbd/3`, `volume_sftp/4`, `volume_nbd/5` | Native raw 101 byte channels; consumers supply their SFTP/NBD implementation |
| `RawChannel.recv/2`, `send_data/2`, `shutdown_write/1`, `close/1` | Bounded binary duplex and native half-close |
| `Operation.raw/4`, `from_response/2`, `poll/1`, `wait/2`, `cancel/1`, `websocket/2` | Bound native handles and raw operation ETags; authoritative completion and supported cancellation |
| `Events.subscribe/2`, `next/2`, `send/2`, `close/1` | Native events through an owner-monitored bounded WebSocket queue; sending acknowledges the local write, not backend processing |
| `EventListener.open/2`, `add_handler/3`, `remove_handler/2`, `active?/1`, `send_event/2`, `wait/2`, `disconnect/1` | Explicit owner-bound callback listener; bounded capacity, sequential isolated callback workers, failure/lifetime cleanup and repeatable terminal result; local wait timeout does not disconnect or cancel work |
| `Response.metadata_as_map/1`, `metadata_as_string_slice/1`, `metadata_as_operation/1`, `metadata_as_model/2` | Explicit native typed metadata extraction, including initialized-empty map/slice behavior for null, defaults and float64 metadata semantics; original response remains lossless |
| `Tokens.certificate/1`, `cluster/1`, `encode/1` | Pure conversion of existing operation metadata and exact ordered JSON/base64 token formatting; tokens/addresses are privileged data, never provisioning or automatic connection targets |
| `OCI.new!/4`, `resolve/3`, `image/2`, `image_file/3`, `unsupported/2` | Explicit host-owned OCI adapter; passive construction, bounded immutable cache, pinned alias/image/unsupported projections and acknowledged binary output; no bundled host runner or installed conversion acceptance |
| `Session.exec/3`, `console/3`, `input/2`, `output/3`, `control/2`, `resize/3`, `signal/2`, `exit_status/1`, `close/1` | Native operation channels and control messages; local closure does not cancel Incus |
| `DynamicConsole.open/4`, `attach/1`, `detach/2`, `control/2`, `resize/3`, `close/1` | One accepted console operation/control connection, repeated owner-bound data attachments; bounded capacity/lifetime and no POST replay |
| `Copy.instance/4`, `snapshot/5`, `volume/6`, `move_volume/5` | Native writable configuration and explicit migration preparation; volume moves use one backend with destination `name`/`project`; accepted handles |
| `Migration.negotiate/5`, `relay/2`, `target/1`, `wait_target/2`, `cancel_target/1` | Explicit requests/origin and both accepted handles; bounded relay; explicit target completion/cancellation with source identity retained |

Copy options follow the pinned native argument types: instances accept `live`,
`instance_only`, `refresh`, `refresh_exclude_older` and `allow_inconsistent`;
snapshots accept `live`; volumes accept `volume_only`, `refresh` and
`refresh_exclude_older`. All three accept `name`, `mode` and the host-approved
origin. Unsupported option keys and malformed option lists fail before I/O.

Example conditional mutation and reconciliation:

```elixir
{:ok, profile} = Opsmaru.Incus.call(client, "GetProfile", %{"name" => "default"})
{:ok, writable} = Opsmaru.Incus.Model.writable(profile.metadata)
{:ok, updated} = Opsmaru.Incus.call(client, "UpdateProfile", %{"name" => "default"},
  body: writable, etag: profile.etag)

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

OCI construction is also passive. Supply a module implementing
`Opsmaru.Incus.OCI.Adapter` and an opaque host-owned configuration reference:

```elixir
oci = Opsmaru.Incus.OCI.new!(connection, context, MyHost.OCIAdapter, private_adapter_ref)
{:ok, %{alias: alias_model, image: image_model}, oci} =
  Opsmaru.Incus.OCI.resolve(oci, "library/alpine:latest@sha256:approved_digest", "container")
{:ok, cached} = Opsmaru.Incus.OCI.image(oci, alias_model.data["target"])
{:ok, sizes} = Opsmaru.Incus.OCI.image_file(oci, image_model.data["fingerprint"], %{
  metadata: metadata_sink, rootfs: rootfs_sink
})
```

`MyHost.OCIAdapter` is a host implementation, not a provided Opsmaru module.
The adapter receives the connection/context, normalized alias, unique call
identity and absolute monotonic deadline. It owns verified registry TLS,
credentials, subprocesses and conversion files. Inspection JSON is capped at
the lesser of 1 MiB and `max_response_bytes`; cached images are capped at the
lesser of 128 and `queue_limit`. `resolve` returns a new immutable client cache.
The output emitter accepts `:metadata`/`:rootfs` chunks under `max_chunk_bytes`
and a combined `max_stream_bytes` budget, synchronously acknowledging each sink.
Both output sinks are currently required. Rejections stay sticky; a foreign
worker cannot emit output. Inspection uses `timeout`, conversion uses
`stream_timeout`, including time inside sinks. Cleanup adds at most
`min(timeout, 1_000)` milliseconds, kills stalled local callbacks and preserves
the primary result in a cleanup failure's privileged `response` field. Host
cleanup must independently stop/release all external resources by call identity
even if the local callback was killed mid-creation. Calls are never replayed.

The OCI oracle uses the unchanged pinned client with a fixture-only skopeo
stdout stub for alias/image projections and unsupported helper errors; it does
not run real skopeo, unpack an image, use root or contact a registry. Conversion
contents, actual registry TLS/authentication and external process/file cleanup
require separate installed-host-adapter acceptance. OCI connection-info/HTTP/
disconnect and alias-architecture helpers and SimpleStreams remain uncovered.

HTTPS uses peer trust, hostname and certificate validity checks. Hosts select
CA and client certificate/private-key files, or an exact SHA-256 server pin.
A pin without a CA allows only matching self-signed/unknown-CA peers; combined
CA plus pin requires both. Keys are read only by an authorized connection.
Inspect and process status redact payloads, endpoints, identities and secrets;
raw maps/native metadata remain privileged values that hosts must not log.
No mutable global remote, trust generation, backend install or address fallback
exists. Migration pull/push requires the exact explicit HTTPS origin; advertised
addresses are not followed. Failures preserve accepted handles and backend data.

Connections optionally accept `require_authenticated: true`, the native
`X-Incus-authenticated: true` requirement on HTTP, transfers and upgrades.
This asks Incus to require backend authentication; it does not verify the
host's caller identity. The default is false and the flag remains local to
the explicit connection. Host readiness and authorization still precede I/O.

Image-based create/rebuild requires `approved_origin:` for a remote source,
before generating a private-image token. A subsequent target failure retains
the token operation response for reconciliation. Only local images and native
Incus HTTPS sources are covered; OCI/SimpleStreams image sources remain missing.

Mint 1.11.0/hpax 1.1.0 and MintWebSocket 1.0.5 are locked. HTTP requests have
connection/send/receive deadlines and header/body budgets. Transfers use bounded
binary chunk enumerables and acknowledged sinks, covered by a total deadline.
Stream actors monitor the owner, limit lifetime, message/frame/byte queues and
close sockets on errors or local close. Overflow is visible; reconcile against
operation polling. Optional host concurrency supervision rejects capacity with
no pending queue or replay. A local success is never hardware acceptance.

Private image exports preserve the pinned `setQueryParam` double form encoding
for unusual token characters. Ordinary token values are unaffected. The client
uses only its explicit connection, with no `/dev/incus/sock` fallback. Image
sinks/options and upgrade path/options are validated before I/O. Storage SFTP
and read-only/writable NBD have dedicated unchanged typed-method comparisons
over Unix and HTTPS; coalesced bytes use independent preservation fixtures.

`NativeConfig.from_json/3` is an explicit native normalization step. Model
validation still expects string-valued known config/device fields and preserves
unknown/null fields; normalizing a separate value does not mutate the model.
JSON numbers follow Go float64 precision and shortest formatting. At positive
2^63, the pinned Go conversion differs on ARM64 versus AMD64; this helper
matches the native result on those platforms. YAML and other architecture
acceptance remain outside this verified JSON slice.

Dynamic console example, after the host authorizes native console access:

```elixir
{:ok, console} = Opsmaru.Incus.DynamicConsole.open(client, "instance", %{},
  max_attachments: 2)
{:ok, data} = Opsmaru.Incus.DynamicConsole.attach(console)
Opsmaru.Incus.WebSocket.send_frame(data, {:binary, host_input})
Opsmaru.Incus.WebSocket.recv(data, 1_000)
Opsmaru.Incus.DynamicConsole.resize(console, 80, 24)
Opsmaru.Incus.DynamicConsole.detach(console, data)
Opsmaru.Incus.DynamicConsole.close(console)
# console.operation remains available for native completion/reconciliation.
```

Recognized child-channel failures are forwarded to the creating host as
`{:dynamic_console, console.pid, {channel.ref, :error, error}}`. The error keeps
the exact cause and accepted operation response for reconciliation, even when
the host was not waiting in `WebSocket.recv/2`. Unknown references are ignored;
control-channel termination releases remaining local attachments and data
failure does not automatically cancel the backend operation.

Remote WebSocket closure emits `{channel.ref, :eof}` once to its owner while
queued tail frames remain available through `recv/2`. Dynamic consoles forward
this as `{:dynamic_console, console.pid, {channel.ref, :eof, console.operation}}`.
Control EOF promptly closes the local console and its data attachments. Data
EOF remains drainable until detach; neither case cancels the accepted backend
operation.

Dynamic-console wire comparisons use no project/member: the pinned operation
WebSocket helper omits those parameters. Explicit selection is independently
checked on every Opsmaru request under the approved connection contract, as
with direct backups. Actual cluster forwarding remains a real-backend gate.

## Coverage limitations

`Opsmaru.Incus.Preseed.apply(client, native_config, timeout: 30_000)` explicitly
applies native server, pools, default-project networks, projects, other networks,
volumes, profiles, certificates, cluster configuration and cluster groups in
the pinned helper's order. It preserves ETags, config/device merges, project
defaults and group nil-versus-empty membership semantics. Calls are bounded to
128 records and one total deadline. JSON input uses native typed defaults and
config coercion; ambiguous field-case aliases are rejected before I/O.

The success result's `changes` contains native successful mutation responses.
On failure, `error.response.completed` retains that bounded result and
`error.response.failure` retains the latest native failure or accepted response;
the native error code, HTTP status and operation URL remain available. A result
budget failure can occur after acceptance and retains that response for host
reconciliation. No rollback, mutation replay, trust generation or startup hook
is provided. Like the pinned helper, a network/profile/volume/group read error
leads to one create attempt; a create failure stops the call. Cluster completion
uses bounded native polling, separately from the compared configuration wire
sequence. YAML and actual server/cluster acceptance remain separate.

`NetworkModels.normalise/1` explicitly applies the eight pinned network
normalizers to a supported `Model`: ACL rules, address sets, forward ports/puts/
posts, and load-balancer backends/ports/puts. It uses typed JSON defaults and
native omission rules, trims exactly Go's Unicode whitespace, and canonicalizes
IP addresses only where the upstream helper does. Input/output are bounded to
1 MiB. This explicit typed projection discards unknown fields; ordinary
`Model.decode/2` remains lossless and mutations do not normalize implicitly.

`HTTP.client/1` provides a portable immutable handle for the native HTTP helper
slice without starting a pool or process. `HTTP.request/4` takes a supported
HTTP verb, relative native API path, and binary `body`/validated `headers` options.
It returns a raw `HTTP.Response` containing status, ordered duplicate headers,
separate trailers, binary body and originating connection/identity. `header/2`
uses the first value like Go Header.Get. Request/response capture uses the
connection's finite byte limits and request deadline; larger native transfers
use the streaming APIs above. HTTP response receipt does not establish native
operation completion. 3xx/305 responses are returned without redirect or replay.
The official differential uses an explicitly non-replayable request, matching
the foundation's mandatory no-mutation-replay contract. Arbitrary URL clients,
mutable shared pools and OIDC adapters are not provided by this native slice.

`WebSocket.open(client, path, headers: [{"x-custom", "host-value"}])` provides
the direct native DoWebsocket slice over the same bound Unix/verified HTTPS
transport. Header names/values/counts are bounded and protocol/authentication
headers remain transport-owned. `WebSocket.upgrade_response(channel)` returns
the native 101 status, ordered headers and originating connection/identity
while the local channel is alive. Its body is nil; coalesced bytes belong to
the queued WebSocket frames. Existing owner/lifetime/frame/queue bounds and
close/error/EOF semantics apply. This does not expose an arbitrary dialer or
an OIDC adapter.

The checked manifest currently has 268 differential JSON methods, 870 partial
reference mappings and 410 missing declarations out of 1,280. Native Incus
method evidence is scoped to that implementation; same-named OCI/SimpleStreams
methods remain missing. Interface entries
and schemas account for some mappings; these counts are not distinct client
operations. Schema-derived field validation and positive fixture results do
not establish full Incus semantic behavior. `scripts/update-incus-coverage.py`
regenerates mappings and checks evidence paths, never relabeling partial as full.

Local instance/snapshot/volume copy and move requests, and remote HTTPS pull/push
copy preparation, are compared with official helpers. Copy request bodies now
compare complete objects, including native zero/omitted fields, rather than
checking only supplied fields. The default/empty-name and enabled/inactive
option matrix covers live, instance-only, volume-only, refresh, exclude-older
and allow-inconsistent combinations. Instance copy retains every writable DTO
field, including restore/disk-only. An omitted/empty volume destination name
remains empty as in the pinned helper; instance/snapshot defaults retain their
native source/parent name. Bidirectional binary/text relay across control/data
channels, EOF, silent deadlines and native upgrade rejections are independently
verified. Copy option preflight includes the pinned target-side check for
`instance_allow_inconsistent_copy`; its misleading upstream error text says
source, but the actual `CopyInstance` receiver checks the target. Dependent
instance migration devices use the native capitalized `Devices` key. Internal
volume copy source location falls back to the discovered server name; local
snapshot copies send the native empty type rather than the remote parent type.
Remaining parity includes complete cross-cluster/copy option matrices, migration
negotiation and complete relay-channel failure/cleanup evidence,
full SFTP protocol helpers, complete dynamic console callback/IO and recorded-output helpers, all-field
remaining model/helper behavior, complete streaming backup option/platform coverage
and every currently missing inventory entry. Do not treat `raw_query` success
as typed support. Linux CI, installed service and real-backend results are
recorded separately in `foundation-validation.md`.

The callback listener has at most `min(queue_limit, 128)` handlers and one callback
worker at a time. Each worker is limited by the connection timeout and remaining
stream lifetime; workers die with their listener. A callback exception or timeout
terminates that local subscription with a redacted error. Native event data is
passed explicitly as a `Model`, not logged. These fixtures cover Unix listener
lifecycle; the underlying WebSocket HTTPS transport has separate fixtures.
Operation/remote-operation handler orchestration remains unimplemented.

Typed metadata extraction uses a 1 MiB projection budget. Generic native Go
`any` values have float64 numeric semantics; use the original response/model
when exact received JSON integers or unknown fields matter. Token helpers retain
native address strings as data; they do not approve or follow those addresses.
Remaining model/YAML/helper parity is still incomplete.

The pinned `shared/ws/proxy.go` closes both peers when either forwarder finishes;
it does not reconnect automatically. Opsmaru follows this local channel lifetime
and keeps native operation identities available for host reconciliation. Neither
stream EOF nor successful forwarding proves backend copy/migration completion.

Direct backup POST comparisons use no selected member: the pinned Go helpers
append project but omit target. Opsmaru retains the explicit member parameter
under the approved connection contract, checked independently by a wire fixture.
Actual backend forwarding remains a real-Incus acceptance item.

`Model.etag_values/1` returns the native inputs, including bucket key secrets;
these are privileged raw values, not a replacement for the server ETag header.
Writable projections preserve present nulls/absence; native Go zero-value JSON
materialization and remaining custom JSON/YAML helpers are still partial.

## Known pinned oracle limitations

The pinned event-based `operation.WaitContext` calls `Cancel()` when its local
context expires (`client/operations.go`). The approved operation contract requires
local timeout/disconnection to retain remote work. Opsmaru's bounded polling wait
does not issue a DELETE; its operation fixtures independently verify this required
behavior. Future context/event wait helpers must retain that boundary rather than
copying the oracle's cancellation side effect.

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
