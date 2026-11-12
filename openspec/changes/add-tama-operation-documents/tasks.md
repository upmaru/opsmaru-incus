# Tasks

## 1. Curated document

- [ ] 1.1 Implement `Opsmaru.Incus.Operations.openapi/0` with the Decision 2 mapping: `jsonSchemaDialect`, `x-tama-profile`, source `opsmaru_incus` and `info.version` from the package version. Order operations by name. Keep it pure, with no new runtime dependency.
- [ ] 1.2 Test it: every exported operation appears exactly once and unavailable ones never do. Check the mappings for confirmation (`incus_instance_delete`, snapshot delete and restore, image delete), bounds, `x-opsmaru-requires`, `x-tama-identity` on all 12 mutations, and `200`/`default` equal to the success and error branches. Add the structural profile checks from Decision 9.

## 2. Native generation

- [ ] 2.1 Add `priv/incus/native-policy.json` (schema 1). It holds the reviewed exclusion lists for binary transfers and for remote-backend or credential calls, each with a reason; the body field denylist; and scope, destructive and confirmation overrides, each with a reason. Account for every `methods.json` method that is neither exported nor excluded by rules 1 or 4.
- [ ] 2.2 Implement the `mix opsmaru.incus.native` generator (Decision 3). It reads `methods.json`, `models.json`, the coverage evidence, the policy, and `rest-api.yaml` after verifying its SHA-256 (YAML read with `yamerl`). Join text by verb and normalized path, convert models to JSON Schema (failing on unknown Go types), build input and envelope schemas, and apply scopes, destructive flags, confirmations, exclusions and the denylist. Write sorted, deterministic `priv/incus/native-operations.json`. Fail if any method is neither exported nor listed as unavailable.
- [ ] 2.3 Add regeneration to `check:reference` (a byte-identical comparison and the YAML SHA-256 check), and document regeneration in `priv/incus/README.md`.
- [ ] 2.4 Test the generator with fixture inputs: an upstream-only route is never added; a verified method with no upstream match gets a generated summary; each exclusion rule; denylisted fields removed; `DELETE`/`PUT` destructive with the right confirmation target; admin paths; and an override applied with its reason.

## 3. Native module and execution

- [ ] 3.1 Implement `Opsmaru.Incus.NativeOperations` with `openapi/0` (compile-time read of the generated JSON, `@external_resource`), `unavailable/0` and `run/3` (Decision 6). Run checks the operation, scope, schema, confirmation equality, restricted config through the curated rules, then host `binding/2` and `authorize/3`. It makes one `Incus.call/4` with `project`/`etag`, shapes the envelope within the output limit, returns background operations unwaited, maps uncertain outcomes and never retries.
- [ ] 3.2 Test every native scenario in the spec delta against the HTTP fixture. Prove denied calls never reach the backend. Prove that curated scopes don't grant native access. Prove a lost response is reported uncertain and sent once.

## 4. Packaging and docs

- [ ] 4.1 List the `priv/incus` package files explicitly so that `rest-api.yaml` is not shipped and `native-operations.json` and `native-policy.json` are. Extend `check:consumer` to fail if the YAML is packaged, and to call both `openapi/0` builders from the client-only consumer.
- [ ] 4.2 Document both documents, the native scopes, the exclusions and the executors in `docs/incus-operations.md`, with a Macus-style host example. Add the 0.2.0 `CHANGELOG.md` entry.

## 5. Release cassette (after tama_dex with the `cassette` capability is on Hex)

- [ ] 5.1 Add `{:tama_dex, "~> 0.1", only: [:dev, :test], runtime: false}`, and a test that both documents pass `Tama.Dex.Profile.validate/1` and load into one in-memory index without conflicts. Replace the structural checks only where tama-dex covers them.
- [ ] 5.2 Extend `.github/workflows/publish.yml`. After `mix hex.publish`, build `opsmaru_incus-<version>.tama-cassette` with `mix tama.dex.cassette --name opsmaru_incus --version <version>` from both `openapi/0` builders, write its `.sha256`, and attest provenance with `actions/attest-build-provenance`. Then create the GitHub Release for the tag, with notes from the version's `CHANGELOG.md` section and the assets attached. Use `contents: write`, `id-token: write` and `attestations: write`, pin actions by SHA, and lint with actionlint. Releasing needs user authorization, as before.
- [ ] 5.3 Verify the workflow's cassette build locally, or in a dispatched dry run without publishing. The built cassette must import into a fresh index as the `opsmaru_incus` cassette with both sources searchable, and the `.sha256` must match.
