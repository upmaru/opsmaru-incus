# Public portable Incus library

The library is usable without application startup, SQL, Macus, Swift or a
central service. Fixture-tested slices are listed below. This is **not a
complete Incus client port**: `priv/incus/coverage.json` records every pinned
reference declaration and keeps missing coverage visible (`complete_port=false`).

Task 3.9 now closes on verified REST endpoint/method, streaming/upgrade and
consumer-required client behavior, independently of Go declaration parity.
That behavioral inventory is still incomplete; neither task completion nor a
successful MCP tool would establish complete declaration coverage.

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
| `FileHeaders.parse/1` | Pure bounded native header defaults, signed ownership/overflow and base-zero permission-mode semantics; first duplicate wins |
| `NativeConfig.from_yaml/3` | Strict-subset ConfigMap/DevicesMap YAML (`NativeYaml`): every accepted document equals the pinned go-yaml v4 result, everything else is rejected. Supports one document of block/flow mappings with string keys, go-yaml scalar resolution, anchors on scalars and block mappings, aliases and `<<` merges; rejects tags, directives, extra documents, other sequences, null/non-string keys, flow-collection anchors, date-like plain scalars and more than 100 aliases. Decoding runs in a bounded worker (2 s, heap cap) |
| `StatusError.new/2`, `error/1`, `status/1`, `match/2`, `check/2` | Pure bounded native status/message value with the pinned Go zero value and `net/http` status text; takes a preformatted message (no Go `fmt` verbs) and matches only a direct `%StatusError{}` (no `errors.As` unwrapping) |
| `Projections.filtered_server/1`, `logging_event/1` | Pure typed native server filter and logging/network-ACL/lifecycle/operation event records; bounded inputs, no log output; originals remain lossless |
| `Projections.filtered_server_yaml/1` | Byte-exact native `ServerFiltered.MarshalYAML` output (go-yaml v4 `yaml.Marshal`) for single-line printable strings and ASCII keys; other input is rejected rather than approximated |
| `Operation.add_handler/3`, `remove_handler/3`, `Migration.add_handler/3` | Native operation event handlers on an explicit, backend/identity-bound `EventListener`; final operations return no target or their native error; the caller owns listener lifetime |
| `Metadata.keys/3` | Pure bounded native configuration-key lookup with typed defaults, last-map-wins merge and native entity/group diagnostics; aliased string-key maps are validated |
| `URL.new/0`, `scheme/2`, `host/2`, `path/2`, `project/2`, `target/2`, `with_query/3`, `fragment/2`, `render/1` | Passive immutable bounded native URL values; escaped replacement path, appended duplicate queries and explicit rendering; never a verified connection |
| `Model.writable/1`, `active?/1`, `etag_values/1`, `ModelURL.resource/2`, `parent_snapshot_name/1`, `Status.string/1`, `final?/1`, `from_string/1` | 23 writable projections, nine native resource URL helpers, five ETag input tuples and pinned status semantics; original model remains lossless |
| `Images.import/4`, `download/4`, `copy/4` | Bounded unified/multipart binary handoff; `download(..., secret: token)` matches native private exports; pull/push and host-staged relay copies retain native operations |
| `ImageInstances.create/5`, `rebuild/6` | Local images or one approved verified HTTPS source; native alias/fingerprint/private token preparation; accepted target handle without replay |
| `Files.read/4`, `create/5`, `backup_import/3`, `backup_download/4` | Binary files, separate directory metadata, native UID/GID/mode parsing and backup headers |
| `Files.volume_read/6`, `volume_create/7`, `volume_delete/5`, volume/bucket backup helpers, `backup_stream/4` | Twelve native file/archive helpers have differential byte/header/query evidence; full option/platform/backend coverage remains separate |
| `Streams.metrics/2`, `network_acl_log/3`, `instance_logfile/4`, `instance_console_log/3`, `instance_template_file/4`, `create_instance_template_file/4`, `instance_debug_memory/4` | Native binary/text handoff to an acknowledged host sink or bounded source; no collector or implicit file writes |
| `Incus.sftp/2`, `nbd/3`, `volume_sftp/4`, `volume_nbd/5` | Native raw 101 byte channels; consumers supply their SFTP/NBD implementation |
| `Incus.file_sftp/2`, `volume_file_sftp/4` | Approved bounded SFTP v3 subset: initialize a creator-owned session over the existing raw upgrade; volume extension, host identity/readiness and verified transport still apply |
| `SFTP.extensions/1`, `open/3`, `read_at/4`, `write_at/4`, `close_file/2`, `close/1` | One request at a time; explicit file modes, native opaque handles and byte/status fidelity; other operations reject and possibly dispatched mutations are never replayed |
| `RawChannel.recv/2`, `send_data/2`, `shutdown_write/1`, `close/1` | Bounded binary duplex and native half-close |
| `Operation.raw/4`, `from_response/2`, `poll/1`, `wait/2`, `cancel/1`, `websocket/2` | Bound native handles and raw operation ETags; authoritative completion and supported cancellation |
| `Events.subscribe/2`, `next/2`, `send/2`, `close/1` | Native events through an owner-monitored bounded WebSocket queue; sending acknowledges the local write, not backend processing |
| `EventListener.open/2`, `add_handler/3`, `remove_handler/2`, `active?/1`, `send_event/2`, `wait/2`, `disconnect/1` | Explicit owner-bound callback listener; bounded capacity, sequential isolated callback workers, failure/lifetime cleanup and repeatable terminal result; local wait timeout does not disconnect or cancel work |
| `Response.metadata_as_map/1`, `metadata_as_string_slice/1`, `metadata_as_operation/1`, `metadata_as_model/2` | Explicit native typed metadata extraction, including initialized-empty map/slice behavior for null, defaults and float64 metadata semantics; original response remains lossless |
| `Tokens.certificate/1`, `cluster/1`, `encode/1` | Pure conversion of existing operation metadata and exact ordered JSON/base64 token formatting; tokens/addresses are privileged data, never provisioning or automatic connection targets |
| `SimpleStreams.new!/3`, `refresh/1`, `images/1`, `image/2`, `aliases/1`, `alias/3`, `alias_architectures/3`, `files/2`, `image_file/4`, `unsupported/2` | Explicit verified HTTPS, host-supplied architecture and immutable catalog; pinned projections and checksummed binary sinks; optional bounded host delta adapter; installed conversion and full protocol parity remain open |
| `OCI.new!/4`, `resolve/3`, `image/2`, `image_file/4`, `unsupported/2` | Explicit host-owned OCI adapter; passive construction, bounded immutable cache, pinned alias/image/unsupported projections and acknowledged binary output; no bundled host runner or installed conversion acceptance |
| `OCI.connection_info/1`, `http_client/1`, `http_request/4` | Native passive CA-configured metadata and bounded raw HTTP on an explicit verified HTTPS origin; no adapter/config origin inference, redirects or mutation replay |
| `Session.exec/3`, `console/3`, `input/2`, `output/3`, `control/2`, `resize/3`, `signal/2`, `exit_status/1`, `close/1` | Native operation channels and control messages; local closure does not cancel Incus |
| `Session.collect/4` | Creator-owned live noninteractive stdout/stderr sinks, aggregate output bounds, absolute collection deadline and authoritative operation/exit result; closes local channels without cancellation |
| `DynamicConsole.open/4`, `attach/1`, `detach/2`, `control/2`, `resize/3`, `close/1` | One accepted console operation/control connection, repeated owner-bound data attachments; bounded capacity/lifetime and no POST replay |
| `Copy.instance/4`, `snapshot/5`, `volume/6`, `move_volume/5` | Native writable configuration and explicit migration preparation; volume moves use one backend with destination `name`/`project`; accepted handles |
| `Migration.negotiate/5`, `relay/2`, `target/1`, `wait_target/2`, `cancel_target/1` | Explicit requests/origin and both accepted handles; bounded relay; explicit target completion/cancellation with source identity retained |

Copy options follow the pinned native argument types: instances accept `live`,
`instance_only`, `refresh`, `refresh_exclude_older` and `allow_inconsistent`;
snapshots accept `live`; volumes accept `volume_only`, `refresh` and
`refresh_exclude_older`. All three accept `name`, `mode` and the host-approved
origin. Unsupported option keys, duplicate keys and malformed option lists fail before I/O.
Migration negotiation accepts only unique `mode`/`approved_origin` options;
relay accepts only one `timeout`, and rejected relay options retain accepted handles.

Pure URL example (rendering exposes the value explicitly; Inspect is redacted):

```elixir
alias Opsmaru.Incus.URL
{:ok, url} = URL.path(URL.new(), ["1.0", "instances", "name/part"])
{:ok, url} = URL.project(url, "host-project")
{:ok, "/1.0/instances/name%2Fpart?project=host-project"} = URL.render(url)
```

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
disconnect and alias-architecture helpers remain uncovered. SimpleStreams now has a separate verified partial catalog/full-file slice below.

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

Remote WebSocket close frames emit `{channel.ref, :eof}` once to their owner while
queued tail frames remain available through `recv/2`. Dynamic consoles forward
this as `{:dynamic_console, console.pid, {channel.ref, :eof, console.operation}}`.
Control EOF promptly closes the local console and its data attachments. Data
EOF remains drainable until detach; neither case cancels the accepted backend
operation.

A transport loss without a WebSocket close frame terminates with
`:channel_io`, rather than implying clean EOF or successful event/migration
completion. All writes, including pong and close frames, use the lesser of the
connection timeout and remaining stream lifetime. Local cleanup still neither
cancels nor replays an accepted backend operation.

Dynamic-console wire comparisons use no project/member: the pinned operation
WebSocket helper omits those parameters. Explicit selection is independently
checked on every Opsmaru request under the approved connection contract, as
with direct backups. Actual cluster forwarding remains a real-backend gate.

Image relay copies use host-owned staging sinks and rewindable enumerable source
factories. A split export requires both rootfs sink and source, including an
empty rootfs part. A missing, invalid or failed rootfs source returns
`:missing_relay_adapter` before the target upload; it never substitutes a
metadata-only image. Staging remains host-owned and is not deleted on failure.

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

The checked manifest currently has 268 differential JSON methods, 1134 partial
reference mappings and 146 missing declarations out of 1,280. Native Incus
method evidence is scoped to that implementation; OCI and SimpleStreams each
have 20 partial concrete method mappings and none missing; full protocol/option
coverage is still partial. Interface entries
and schemas account for some mappings; these counts are not distinct client
operations. Schema-derived field validation and positive fixture results do
not establish full Incus semantic behavior. `scripts/update-incus-coverage.py`
regenerates mappings and checks evidence paths, never relabeling partial as full.

Local instance/snapshot/volume copy and move requests, and remote HTTPS pull/push
copy preparation, are compared with official helpers. Copy request bodies now
compare complete objects, including native zero/omitted fields, rather than
checking only supplied fields. The default/empty-name and active/inactive option
matrix compares all 32 instance, two snapshot and eight volume boolean combinations
in pull/push modes, locally and across separate HTTPS fixtures. Same-origin cluster
tests cover colocated and different members, internal-copy extensions, absent
targets, source-server fallback and different projects. These are fixture
comparisons, not a deployed cluster acceptance claim. Instance copy retains every writable DTO
field, including restore/disk-only. An omitted/empty volume destination name
remains empty as in the pinned helper; instance/snapshot defaults retain their
native source/parent name. Bidirectional binary/text relay across control/data
channels, EOF, silent deadlines and native upgrade rejections are independently
verified. Peer-observable fixtures also verify every opened socket closes after
a later channel upgrade fails and after relay caller loss, with accepted handles
retained and no mutation replay or cancellation. Copy option preflight includes the pinned target-side check for
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


SimpleStreams is a verified partial slice, constructed without contacting a backend:

```elixir
stream = Opsmaru.Incus.SimpleStreams.new!(https_connection, context,
  architecture: "aarch64")
{:ok, catalog} = Opsmaru.Incus.SimpleStreams.refresh(stream)
{:ok, image} = Opsmaru.Incus.SimpleStreams.alias(catalog, "ubuntu/24.04/arm64", "container")
{:ok, result} = Opsmaru.Incus.SimpleStreams.image_file(catalog, image.data["target"],
  %{metadata: metadata_sink, rootfs: rootfs_sink})
```

Supply a connection without project/member or Incus-authenticated-header selection.
The host supplies architecture explicitly; pin-equivalent platform selection uses
the oracle's native architecture (including its Darwin x86_64 fallback). Catalog
requests share one deadline and aggregate response byte limit; `queue_limit`
bounds image/alias expansion. Sinks acknowledge binary chunks with `:ok`. Parts
are verified against SHA-256 and size at completion; a failure can leave partial
host output, which the host must discard or reconcile. There is no automatic retry,
HTTP downgrade, redirect following, `/dev/incus/sock` discovery or file creation.
Without an optional host delta adapter/base, downloads use full files. Conversion failure never falls back or replays delivered bytes.
The four HTTP/connection/disconnect conveniences and complete cache/error variants
remain open. These fixture results do not establish installed converter or
real-backend acceptance.


Image-based create/rebuild retains the source connection's project. An explicitly
conflicting `source.project` fails before source token creation or target POST.
The unchanged v7.0.1 helper does not infer this field; oracle comparisons use its
explicit request field while an independent test records that reference omission.
Opsmaru preserves the host-selected project rather than silently choosing another
project's alias. Complete typed request projections include native default fields.

CA trust files are read within authorized TLS setup with a 1 MiB/256-certificate
bound and passed to OTP as DER roots. No host trust filename is registered for
periodic shared-cache refresh; removing a file fails subsequent use locally rather
than crashing other TLS connections. Construction stays passive, and peer identity,
validity, configured pin and client certificate/private-key authentication checks
remain enabled.


Optional delta conversion is explicitly supplied by the host:

```elixir
stream = Opsmaru.Incus.SimpleStreams.new!(https_connection, context,
  architecture: "aarch64",
  delta_adapter: MyHost.DeltaConverter,
  delta_config: private_converter_ref)
{:ok, catalog} = Opsmaru.Incus.SimpleStreams.refresh(stream)
{:ok, files} = Opsmaru.Incus.SimpleStreams.image_file(catalog, fingerprint,
  %{rootfs: rootfs_sink},
  delta_base: %{fingerprint: old_fingerprint, source: host_owned_base_ref})
```

`MyHost.DeltaConverter` implements `SimpleStreams.DeltaAdapter`. Its `convert/3`
receives a unique `call_id`, absolute `deadline`, verified connection/context,
opaque host base source and native delta/rootfs manifests. Call
`request.download_delta.(delta_sink)` synchronously once to receive checksum-
verified delta bytes, then emit converted rootfs chunks through the acknowledged
emitter. Root output must match the native size and SHA-256. Repeated/reentrant
or foreign calls and failed acknowledgements reject further output. Delta plus
converted-output bytes share the remaining aggregate stream budget. Resources
are host-owned; `cleanup/3` receives the call identity and completion/failure/
deadline/owner-loss outcome under a bounded cleanup budget. No xdelta command,
conversion files or base-image lookup is supplied by Opsmaru. Installed actual
conversion, process/file cleanup and platform acceptance remain unverified.


Sink raises/throws/exits are caught by the delta emitter and latch rejection,
including when a converter catches failures itself. Adapter callbacks share a
per-call scope with nested library transport workers; no worker begins callback
work before registration. Cleanup waits for those workers to terminate, including
nested delta sinks, rather than racing their kill signals. The scope bounds tracked
workers by `connection.queue_limit`. If host callback termination is delayed beyond
the caller's deadline plus cleanup allowance, the caller receives a privileged
`adapter_cleanup` result with `call_id` and `cleanup_pending: true`; the independent
controller retains the scope and defers cleanup until work actually stops. Such a
result is not successful cleanup or installed-adapter acceptance.


Remaining origin conveniences now include `SimpleStreams.http_client/1`,
`http_request/4` and `disconnect/1`, plus `OCI.disconnect/1` and
`alias_architectures/4`. SimpleStreams HTTP accepts relative origin paths and
preserves the explicit query without adding project/member parameters; its
raw response retains binary bytes, status, duplicate headers, ETags and binding.
Absolute URLs, traversal, malformed/control queries and fragments reject before
I/O. Requests retain existing deadlines/byte limits, do not follow redirects
and never replay mutations. Disconnect is the pinned no-op: immutable catalogs
and host conversion work are unaffected, and no pool is owned by these values.

OCI alias architecture keys use the host-supplied local architecture, which
can differ from the inspected image architecture. The result returns a new
immutable cache and native alias models; invalid local configuration and the
pinned VM-type rejection occur before adapter work. No platform CLI is invoked.
OCI HTTP/connection-info and SimpleStreams connection-info remain missing;
these additional differential fixtures do not establish full protocol parity.


Image pull/push failures preserve an inner `:uncertain` as the top-level kind;
malformed accepted push-token metadata is uncertain and never triggers export.
Privileged error state retains `source` or `target` acceptance and the original
`error`, including its raw response, binding and any later native operation URL.
The primary URL prefers the inner operation when known, otherwise the earlier
accepted handle. Reconcile each handle on its originating client; a lost response
may leave another accepted operation unknown. No token, copy or export is replayed.


`Constants.names/0` and `fetch/1` expose all 188 pinned API constants by native
string name, including exact status/response/instance/lifecycle values. They are
pure model data: returning an authentication or feature enum does not implement
or activate that feature. The generated native oracle and checked data can be
reproduced with `python3 scripts/check-incus-constants.py --write`, or verified
without edits by omitting `--write`.

`SimpleStreams.connection_info/1` returns the canonical explicit HTTPS origin
and native protocol/default fields without a request or credential-file read.
Certificate PEM is empty because a CA/fingerprint reference is not a supplied
server PEM; the native CA-configured getter has the same result. TLS verification
still uses the connection's explicit trust and client-key references when needed.

`RequestContext.new!(timeout: milliseconds)` creates an explicit local lifetime
with a finite absolute deadline and owner PID (optionally supplied with `owner:`).
It starts no worker or socket. `cancel/1` is idempotent; the first terminal reason
remains observable with `status/1`. Bind it immutably with
`Incus.with_context(client, request_context)`, `Connection.with_context/2`, or
`Incus.connect(connection, host_context, request_context: request_context)`.
Host identity/readiness and connection credentials remain independently bound.

Unlike the pinned Go helper's shared receiver mutation, binding returns a new
Elixir value: the original client and other connections retain their contexts.
Cancellation before dispatch returns canceled with no I/O; interrupted dispatched
mutations remain uncertain. Absolute deadlines and owner loss stop blocked
requests, acknowledged sinks and owned raw/WebSocket/listener/console resources.
Context checks occur at entry and independent guards observe cancellation within
20 ms when scheduled. Local closure never sends backend DELETE or replays work.

`Operation.get/1` reads the retained snapshot; `refresh/1` fetches a new native
snapshot and preserves errors/ETags/identity. `wait_with_context/3` limits local
waiting, including long poll sleeps, and retains the last native snapshot after
cancellation. The original handle remains available for reconciliation. This
implements the approved no-backend-cancellation exception to native WaitContext.

Host OCI/delta calls inherit the context deadline and run per-call cleanup after
tracked workers stop on local cancellation. Cleanup receives canceled as its
outcome; delayed termination retains the existing visible cleanup-pending gate.
Installed adapters must still enforce their separate external-resource contract.
`Incus.disconnect/1` is passive: immutable clients own no pool; close separately
owned channels/listeners or cancel their explicit request context when desired.
These slices do not complete remaining handlers, SFTP, copy/protocol matrices
or all model/JSON/YAML helpers in task 3.9.


`Response.decode_native(type, json)` explicitly projects `"Response"`,
`"ResponseRaw"` or `"ResponseType"` JSON into a native `Model`. It materializes
native zero defaults, drops unknown fields and accepts arbitrary response-type
strings; the wire envelope decoder retains its stricter sync/async/error
contract. `Model.decode/2` continues retaining absent/null/unknown fields.
Response metadata preserves parsed JSON integer precision; ResponseRaw metadata
uses native float64 values. Comparison is of parsed RawMessage data and exact
float64 bits, with no guarantee of Go's raw JSON number/whitespace spelling.

Input and projected output are limited to 1 MiB and nesting to 64 levels.
Duplicate object keys, ambiguous case aliases and non-ASCII envelope keys
reject. ResponseRaw also rejects negative zero with an integer mantissa,
including exponent forms, whose sign the JSON parser discards; decimal signed
zero is preserved. Failures return a redacted `:invalid_response_model` error.
This pure helper performs no I/O, does not create an accepted operation and
does not establish YAML or complete Response type parity.


The native names `GetInstanceFileSFTP` (`%{"name" => instance}`) and
`GetStoragePoolVolumeFileSFTP` (`%{"pool" => pool, "type" => type, "name" => name}`)
also dispatch through `Incus.call/4` with no options. They return `SFTP` sessions,
distinct from the raw connections returned by `sftp/2` and `volume_sftp/4`.
Only the creating process can invoke session operations. Both sessions and
`SFTP.Handle` values redact native bytes on inspection; explicit handle fields
are privileged data for the host.

```elixir
{:ok, sftp} = Incus.file_sftp(client, "instance")
{:ok, file} = SFTP.open(sftp, "/known-size-file", :read)
{:ok, bytes} = SFTP.read_at(sftp, file, 0, 1024)
:ok = SFTP.close_file(sftp, file)
:ok = SFTP.close(sftp)
```

Supported modes are `:read`, `:write`, `:read_write`, `:append` (existing file),
and `:create` (read/write plus create/truncate). Read/write calls accept positive
sizes up to 128 KiB and nonnegative signed-int64 offsets. Reads accept one full
requested DATA response or EOF; short/empty DATA rejects rather than generating
more requests. Paths are valid UTF-8, NUL-free and at most 4096 bytes. Each
outgoing packet must fit both `max_request_bytes` and `max_chunk_bytes`, so a
128-KiB write requires room for its native framing as well. Reply packets are
limited to 132096 bytes and `max_response_bytes`; raw stream/queue/chunk limits
still apply. Extensions are limited to 64 pairs (1024-byte names/4096-byte data),
and live nonempty handle values to 256 bytes, with at most
`min(queue_limit, 128)` handles.

Every request has an absolute local deadline. Closing, protocol failure, caller
loss, cancellation, remote EOF or local stream expiry releases the local channel;
stream expiry does not cancel a shared host context or another session. Failed
file-close attempts invalidate the handle as natively. SFTP status errors retain
wire code/message/language; known codes are not replaced by Go filesystem errors.
Unanswered or malformed replies to potentially dispatched mutations return
`:uncertain` with the native request ID when known. Privileged error response data
retains the connection, verified host identity and session reference even after
the process ends. Reconcile backend file state
before any further mutation; the helper never replays, unlinks a file or sends
Incus cancellation. `unsupported/2` returns `:unsupported_sftp_operation` for
other protocol operations. This remains a fixture-verified subset, not complete
SFTP, directory/stat/attribute/extension-operation or installed-backend acceptance.

## Live noninteractive exec output

`Session.collect/4` consumes a creator-owned `Session.exec/3` session with
`wait-for-websocket=true`, no interactive terminal and no recorded output.
The caller sends stdin before collecting, then supplies both stdout/stderr
binary sinks returning `:ok`; collection sends the native stdin write barrier.

```elixir
{:ok, session} = Session.exec(client, instance, %{
  "command" => argv, "wait-for-websocket" => true, "interactive" => false
})
:ok = Session.input(session, stdin_bytes)
{:ok, result} = Session.collect(session, stdout_sink, stderr_sink,
  timeout: 10_000, max_output_bytes: 1_048_576)
# result.operation, result.exit_status, result.stdout_bytes, result.stderr_bytes
```

Collection pulls both channels concurrently with one outstanding read each and
serial acknowledged sinks. Output payload bytes share one limit (default
`max_stream_bytes`); each received frame must also fit `max_chunk_bytes`.
Excess output fails rather than truncating or buffering. Sinks run in a bounded
worker, so they must explicitly send results to their host rather than depend on
the creator's process dictionary. Do not assume ordering between stdout/stderr.

The collection timeout defaults to `stream_timeout` and cannot exceed it. One
absolute deadline includes callbacks and the authoritative operation wait;
existing channel lifetime, request/idle-read timeout, frame and queue limits
still apply. The timeout starts at collection, not command submission or stdin
delivery. Use an explicit host request context to bound that entire sequence.
Output EOF/empty text barriers precede final operation polling; success includes
the native exit status (including nonzero exits). Other text frames reject.

Every started collection closes its local channels, including on limits,
sink rejection/exception, deadline, cancellation or owner loss, without Incus
cancellation or replay. Errors retain accepted operation identity and bound
response data for reconciliation; delivered sink side effects remain host-owned.
Invalid options, foreign creators and unsupported sessions reject before channel
IO and leave the session to its creator. Recorded-file output, interactive IO,
full Go argument orchestration and tool policy remain outside this subset.
