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
