# Incus reference and transferred fixtures

Official Incus v7.0.1 is pinned at
`13f3992766142d5087fff2e362cd2e1a75294fe8`. The 1,280 declarations in
`inventory.json` cover 86 source files and include method/model signatures,
source SHA-256 hashes and empty implementation/evidence slots. An inventory
entry does not establish support. Apache-2.0 attribution is in `priv/notices`.

`transfer.json` records source and transferred hashes for the reusable Macus
inventory generator, official-client Go oracle, native wire cases, Unix/TLS
HTTP fixtures and comparison helpers. Namespace/path adaptation is recorded
by the distinct transferred hashes. Macus Cowboy proxy, Swift socket bridge,
virtualization and hardware fixtures stay in Macus. Nothing there is modified.

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
mappings. Transferred fixture hashes describe the initial transfer; subsequent
Opsmaru adaptations are tracked in Git, not claimed identical to Macus.

`endpoint-inventory.json` is the full audit ledger: all 247 documented pairs,
293 query/access views, explicit helper/custom mappings, public server registration
hashes/differences, missing typed implementations and finite B01–B12/S01–S12
obligations. `classification_complete=true` means no unclassified source rows,
not verified behavior. Its `completion_records` are the only source of
`behavior_complete=true` rows and certified stream contracts. `endpoint-evidence.json`
is the selected 37-pair evidence ledger (thirty-one complete) with fixture-verified inspection scopes. See
[`task-3-9-backlog.md`](../../docs/task-3-9-backlog.md) for counts and exits.
The canonical endpoint test uses Go's standard AST parser and the existing YAML
parser against the unchanged pin; Go is development-only and never a sidecar.
