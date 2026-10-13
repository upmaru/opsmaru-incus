# Incus reference attribution

The generated declarations in `priv/incus/inventory.json` derive from the
official [lxc/incus](https://github.com/lxc/incus) source at commit
`13f3992766142d5087fff2e362cd2e1a75294fe8` (v7.0.1).
Incus is licensed under Apache-2.0; its unmodified `COPYING` is included here
as `incus-APACHE-2.0.txt`. Upstream has no separate NOTICE file at this revision.
The original source and contributor history remain available at that commit.

Macus transforms declarations into an inventory with source paths, line
numbers, signatures, source hashes, build constraints and evidence slots.
These additions are Macus verification data. No upstream implementation is
installed as a runtime sidecar, and this inventory does not establish parity.


The SimpleStreams catalog projections in
`lib/opsmaru/incus/simple_streams/catalog.ex` are adapted from pinned
`shared/simplestreams/{products,simplestreams,sort}.go` and architecture data in
`shared/osarch/architectures.go`, under the same Apache-2.0 license. The native
fixture driver in `test/reference/simplestreams` imports unchanged v7.0.1 code;
it exercises a private TLS fixture only and does not run image conversion or
local socket discovery. Opsmaru's explicit HTTPS/host-delta boundary differences
are recorded in the foundation OpenSpec design and task 3.9 closure ledger.


`priv/incus/constants.json` contains all 188 exported API constant values from
the same unchanged reference. The generated fixture-only driver in
`test/reference/constants` accesses official exports directly;
`scripts/check-incus-constants.py` regenerates/verifies those declarations and
values. Constant names/values are model data, not implementations or activation
of authentication, scheduling, storage or other named features.

`lib/opsmaru/incus/file_headers.ex` and `projections.ex` adapt the same pinned
`shared/api/{headers,event,server}.go` helpers under Apache-2.0. Fixture-only
drivers in `test/reference/{fileheaders,projections}` import unchanged exports;
they have no backend or host-command access. Native map iteration order is
unspecified, so event context pair order is normalized for comparison while
preserving every key/value pair. Null event metadata is rejected explicitly
rather than propagating a native nil-pointer panic; no SDK code is patched.

`lib/opsmaru/incus/metadata.ex` adapts pinned `shared/api/metadata.go` under the
same Apache-2.0 license. Its fixture-only `test/reference/metadatakeys` driver
uses the unchanged native GetKeys helper. Native string quoting preserves the
helper's explicit caller-visible errors; Inspect remains redacted.


OCI origin helpers adapt pinned client/oci.go connection metadata and HTTP
conveniences. The unchanged drivers in test/reference/{origininfo,httpclient}
now include ConnectOCI; independent tests keep verified origin/credential
binding and non-replayable mutation behavior explicit. No registry authentication
or installed conversion acceptance follows from this helper evidence.

`lib/opsmaru/incus/url.ex` adapts the pinned `shared/api/url.go` builder under
the same Apache-2.0 license. `test/reference/urlbuilder` calls unchanged native
exports and rendering; it performs no network or filesystem operation. The
portable value is immutable and bounded, and its inspection is redacted. Explicit
URL rendering does not verify or authorize the described origin.

`lib/opsmaru/incus/status_error.ex` adapts pinned `shared/api/error.go` under
the same Apache-2.0 license. Its status-text table reproduces Go `net/http`
StatusText values (BSD-3-Clause, Copyright The Go Authors) from the pinned
toolchain. The fixture-only `test/reference/statuserror` driver calls unchanged
native helpers and performs no network or filesystem operation.

`NativeConfig.from_yaml/3` (via `Opsmaru.Incus.NativeYaml`) adapts pinned
`shared/api/config.go` and `devices.go` UnmarshalYAML behavior for a strict
subset, reproducing go-yaml v4 (go.yaml.in/yaml/v4, Apache-2.0 and MIT) scalar
resolution and merge precedence. Tokens come from yamerl (BSD-2-Clause) via
yaml_elixir (MIT). The fixture-only `test/reference/nativeyaml` driver calls the
unchanged native types and performs no network or filesystem operation.
`lib/opsmaru/incus/server_yaml.ex` adapts pinned `shared/api/server.go`
`ServerFiltered.MarshalYAML` and reproduces go-yaml v4 (go.yaml.in/yaml/v4,
Apache-2.0 and MIT) string styling, key ordering and layout for its subset. The
fixture-only `test/reference/serveryaml` driver calls the unchanged native types
and performs no network or filesystem operation.

`Response.decode_native/2` in `lib/opsmaru/incus/response.ex` projects the pinned
`shared/api/response.go` types under the same Apache-2.0 license, using the
checked native schemas and explicit bounded JSON rules. The fixture-only
`test/reference/responsemodels` driver unmarshals/marshals unchanged native
Response, ResponseRaw and ResponseType values and extracts their float64 bits;
it uses only stdin/stdout and performs no network or filesystem operation.
Raw JSON spelling/whitespace, duplicate merging and YAML are not ported;
documented parser and budget rejections remain visible as partial evidence.

The bounded `lib/opsmaru/incus/sftp.ex` helper lifecycle adapts pinned
`client/{incus_instances,incus_storage_volumes}.go` (Apache-2.0).
`lib/opsmaru/incus/sftp/packet.ex` reproduces the supported v3 packet forms from
the pinned pkg/sftp v1.13.10 `client.go`/`packet.go` (BSD-2-Clause,
Copyright (c) 2013, Dave Cheney). Its complete license is included as
`pkg-sftp-BSD-2-Clause.txt`. The fixture-only `test/reference/sftphelpers` driver
imports both unchanged libraries, uses stdin/stdout and explicitly supplied
private Unix/TLS fixtures, and performs no local file operation. The runtime
has no Go sidecar, SSH discovery, host command or local file implementation.
The approved subset and remaining acceptance gates are recorded in the design
and closure ledger.
