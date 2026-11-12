# Proposal

## Why

tama-dex (kritama/tama-dex#1) indexes operation catalogues so a host's MCP
server can expose only `search` and `execute`. It ingests one standard: the
Tama operations profile of OpenAPI 3.1, `tama-operations/1`. Macus
(upmaru/macus#9) already advertises only those two tools and needs
opsmaru_incus to publish its operations in that profile.

On 2026-11-12 the user asked for two things:
- opsmaru_incus should publish the right document, so it plugs into tama-dex
  without either side depending on the other's internals;
- the native Incus client API should be offered too, not just the 32 curated
  operations.

For the native API, the user chose `priv/incus/methods.json` (307 methods
verified against the pinned Go client) as the authority. The Incus-published
`doc/rest-api.yaml`, pinned and vendored, supplies descriptions only.

## What Changes

- **Curated document:** `Opsmaru.Incus.Operations.openapi/0` returns the 32
  exported operations as a `tama-operations/1` document (source
  `opsmaru_incus`).
  - Each operation's name, title, description, scope, destructive flag,
    confirmation rule, integer bounds, input schema and success/error output
    branches map field for field.
  - `requires` is kept as `x-opsmaru-requires`, and mutations declare
    `x-tama-identity: ["operation_id", "status"]`.
  - `Operations.run/3` remains the executor. Unavailable operations are not
    listed.
- **Native document:** `Opsmaru.Incus.NativeOperations.openapi/0` returns a
  second document (source `opsmaru_incus_native`). It is generated from
  `methods.json` and `models.json`:
  - Operation IDs are `incus_native_<snake_method>`.
  - The input combines path parameters, query keys, an optional `project` and a
    `body` converted from the native model.
  - Summaries, descriptions and field descriptions come from the pinned
    `rest-api.yaml`, matched by verb and normalized path.
- **Native policy:**
  - Separate scopes, never implied by the curated ones: `incus.native.read`,
    `incus.native.write`, `incus.native.delete` and `incus.native.admin`.
  - Every `DELETE` and `PUT` is destructive, with `confirm` repeating the
    target resource.
  - Excluded, with recorded reasons: interactive channels, binary transfers,
    calls that select another backend or carry credentials, and methods
    without evidence.
  - A reviewed `priv/incus/native-policy.json` holds the overrides.
- **Native execution:** `NativeOperations.run(name, input, host:, caller:,
  scopes:)` applies the same trust model as `Operations.run/3`:
  - scope, schema and confirmation checks;
  - the restricted-config rules for `config`/`devices`;
  - host `binding/2` and `authorize/3`.

  It then makes one `Incus.call/4`, with bounded output. Background operations
  return their native operation identity without waiting. Nothing is replayed.
- **Pinned upstream text:**
  - `priv/incus/rest-api.yaml` is unmodified, SHA-256 `7b4e0737…2e91f`, at
    revision `13f39927`.
  - `mix opsmaru.incus.native` regenerates
    `priv/incus/native-operations.json` deterministically, and
    `check:reference` fails on any drift.
  - The YAML is generator input only and is not shipped in the Hex package.
- **Release cassette:** each `v*` release also builds a tama-dex cassette
  (`opsmaru_incus-<version>.tama-cassette`) holding both documents' sources.
  It is built with tama_dex as a dev-only dependency, and published as a
  GitHub Release asset with its SHA-256 and build provenance attestation.
  Macus can import it at install or start instead of indexing. This part waits
  for the tama_dex release.
- **Release:** opsmaru_incus 0.2.0. The existing `describe/1` contract and
  `coverage.json` are unchanged. Native tool success never counts as client
  evidence.

## Capabilities

### Modified Capabilities

- `incus-operations`: adds the curated document, the native document and its
  policy, native execution and the pinned upstream text.

## Impact

- **Consumers:** Macus loads both documents into tama-dex and registers
  `Operations.run/3` and `NativeOperations.run/3` as executors. Its host module
  serves both, because the native executor uses the same `Operations.Host`
  callbacks.
- **No new runtime dependency:** opsmaru_incus doesn't depend on tama_dex.
  Conformance is tested structurally now, and through
  `TamaDex.Profile.validate/1` as a test-only dependency once tama_dex is
  released.
