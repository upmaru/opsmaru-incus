# Incus reference and transferred fixtures

Official Incus v7.0.1 is pinned at
`13f3992766142d5087fff2e362cd2e1a75294fe8`. The 1,280 declarations in
`inventory.json` cover 86 source files and include method/model signatures,
source SHA-256 hashes and empty implementation/evidence slots. An inventory
entry does not establish support. Apache-2.0 attribution is in `priv/notices`.

`transfer.json` records source and transferred hashes for the reusable Macus
inventory generator, official-client Go oracle, native wire cases, Unix/TLS
HTTP fixtures and comparison helpers. Namespace/path adaptation is recorded
by the distinct transferred hashes; a later local amendment is recorded by
adding `amended_sha256` and a one-sentence `amendment` to the entry, so the
current bytes always equal `amended_sha256` when present, otherwise
`transferred_sha256`, and history is never rewritten. `test/transfer_record_test.exs`
checks every entry against the shipped bytes. Macus Cowboy proxy, Swift socket
bridge, virtualization and hardware fixtures stay in Macus. Nothing there is
modified.

Regenerate from a clean checkout at the exact pin (Go is verifier-only):

```sh
mise exec -- mix opsmaru.incus.inventory --source .integration/incus-reference
mise exec -- mix opsmaru.incus.inventory --source .integration/incus-reference --output /tmp/incus-repeat.json
cmp priv/incus/inventory.json /tmp/incus-repeat.json
GO111MODULE=off GOTOOLCHAIN=local mise exec -- go test ./scripts
```

`Opsmaru.Incus.Inventory.diff/2` exposes added, removed and altered declarations.
Source hash changes also need review, even when declarations are unchanged.
All affected methods/models require renewed evidence before a support claim.
The oracle is built under `test/reference` from its pinned Go module/Go sum.
It is never packaged as a sidecar. Coverage and acceptance remain separate.

Regenerate native JSON field schemas (hashes are checked against the inventory):

```sh
GO111MODULE=off GOTOOLCHAIN=local mise exec -- go run ./scripts/incus-model-schema .integration/incus-reference priv/incus/inventory.json > /tmp/incus-models.json
cmp priv/incus/models.json /tmp/incus-models.json
python3 scripts/update-incus-coverage.py
```

`methods.json` is a curated native request registry, verified by invoking each
unchanged official typed method. The coverage manifest accounts for all 1,280
entries, including missing declarations and partial interface/model/helper
mappings. Transferred fixture hashes describe the initial transfer and are
never rewritten; subsequent Opsmaru adaptations are recorded by deliberately
updating an entry's `amended_sha256` and `amendment`, not claimed identical to
Macus. `test/transfer_record_test.exs` enforces that every destination matches
its current digest, so a Hex-package consumer can verify the record without
Git history.

`endpoint-inventory.json` is the full audit ledger: all 247 documented pairs,
293 query/access views, explicit helper/custom mappings, public server registration
hashes/differences, missing typed implementations and finite B01–B12/S01–S12
obligations. `classification_complete=true` means no unclassified source rows,
not verified behavior. Its `completion_records` are the only source of
`behavior_complete=true` rows and certified stream contracts. `endpoint-evidence.json`
is the selected 247-pair evidence ledger (all 247 complete) with fixture-verified inspection scopes. See
[`task-3-9-backlog.md`](../../docs/task-3-9-backlog.md) for counts and exits.
The canonical endpoint test uses Go's standard AST parser and the existing YAML
parser against the unchanged pin; Go is development-only and never a sidecar.

## Upstream REST API description

`rest-api.yaml` is the unmodified Swagger 2.0 description that Incus publishes
as `doc/rest-api.yaml` at the pinned revision
`13f3992766142d5087fff2e362cd2e1a75294fe8` (SHA-256
`7b4e07375da92f30e7eadf766f1bbdf40bf9968ee305a16be1afe5998e72e91f`). It is
generated from code comments and is not verified against the client. It is
used only as descriptive text (summaries, descriptions and field descriptions)
for the native operations document, joined to verified `methods.json` entries
by verb and path. It never decides which methods exist or what their schemas
are. Re-download and compare at the pin:

```sh
curl -sfL https://raw.githubusercontent.com/lxc/incus/13f3992766142d5087fff2e362cd2e1a75294fe8/doc/rest-api.yaml | shasum -a 256
```

The file is generator input only and is not shipped in the Hex package.

## Native operations document

`native-operations.json` is generated; never edit it by hand. It holds the
`tama-operations/1` document for the native client methods (source
`opsmaru_incus_native`) and the list of methods that are not exported, each
with its reason. `Opsmaru.Incus.Operations.Native` reads it at compile time.

The generator reads `methods.json` (which operations exist), `models.json`
(their schemas), the evidence behind the coverage ledger, `native-policy.json`
and `rest-api.yaml` (summaries and descriptions only). It fails when the
`rest-api.yaml` SHA-256 differs from the one recorded in the policy, on an
unknown Go type, or when a method is neither exported nor listed as
unavailable.

`native-policy.json` is reviewed like a lock. It records the upstream file's
revision and SHA-256, the binary-transfer and remote-backend or credential
exclusions, the body fields removed from every exported schema, and the scope,
destructive and confirmation overrides. Every entry carries a reason.

Regenerate after changing any of those inputs, then review the diff:

```sh
mise exec -- mix opsmaru.incus.native
```

`mise run check:reference` runs `mix opsmaru.incus.native --check`, which
verifies the SHA-256, regenerates in memory and fails unless the file is byte
for byte identical.
