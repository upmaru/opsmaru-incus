# Spec Delta

## ADDED Requirements

### Requirement: Curated operations document

`Opsmaru.Incus.Operations.openapi/0` SHALL return the exported operations as a
`tama-operations/1` document with source `opsmaru_incus`.

- It SHALL be pure: the same JSON-safe map on every call for a release.
- Each operation SHALL map field for field from its descriptor: name, title,
  description, resource tag, scope, destructive flag, confirmation rule,
  integer bounds, opaque `x-opsmaru-requires`, input schema, success output
  branch as `200` and the shared error object as `default`.
- Mutations whose output carries `operation_id` and `status` SHALL declare them
  in `x-tama-identity`.
- Unavailable operations MUST NOT be listed.
- The library MUST NOT depend on tama_dex at runtime.

#### Scenario: Destructive operation mapped

- **WHEN** a host reads `incus_instance_delete` from the document
- **THEN** it has `x-tama-scopes: ["incus.delete"]`, `x-tama-destructive: true`, and `x-tama-confirmation` with field `confirm` and description "the instance name"

#### Scenario: Deferred operation

- **WHEN** a host searches the document for `incus_instance_copy`
- **THEN** no such operation is present

### Requirement: Native operations document

`Opsmaru.Incus.NativeOperations.openapi/0` SHALL return a `tama-operations/1`
document with source `opsmaru_incus_native`. It SHALL be generated
deterministically by `mix opsmaru.incus.native` into
`priv/incus/native-operations.json`, and checked byte for byte by
`check:reference`.

- Native operations SHALL be exactly the `methods.json` methods that have
  recorded evidence and no recorded exclusion.
- Each SHALL have operation ID `incus_native_<snake_method>`.
- Each input schema SHALL be derived from the method's parameters, query
  templates and body model, plus optional `project` and `etag`, and a required
  `confirm` for destructive methods.
- Each result schema SHALL be the bounded native envelope for its result kind.
- The upstream `rest-api.yaml` SHALL contribute only summaries and
  descriptions, joined by verb and normalized path. It MUST NOT add
  operations or schemas.

#### Scenario: Upstream operation without a verified method

- **WHEN** `rest-api.yaml` describes a route that no `methods.json` entry verifies
- **THEN** the native document has no operation for it

#### Scenario: Verified method without upstream text

- **WHEN** a verified method has no upstream match
- **THEN** it is exported, with the generated summary `"<VERB> <path>"` and its native facts in the description

#### Scenario: Drift

- **WHEN** `methods.json`, `models.json`, the policy or `rest-api.yaml` changes without regenerating
- **THEN** `check:reference` fails

### Requirement: Native operation policy

Native operations SHALL use the scopes `incus.native.read`,
`incus.native.write`, `incus.native.delete` and `incus.native.admin`, which
are separate from and never implied by the curated scopes.

- Methods under `/1.0/certificates` and `/1.0/cluster`, and `PUT`/`PATCH` of
  `/1.0`, SHALL require `incus.native.admin`.
- Every `DELETE` and `PUT` SHALL be destructive, and SHALL require `confirm`
  repeating its target resource.
- Overrides SHALL live only in the reviewed `priv/incus/native-policy.json`,
  each with a reason.

#### Scenario: Curated scope does not grant native access

- **WHEN** a caller holding every curated scope searches for or runs a native operation
- **THEN** it is hidden by tama-dex, and `NativeOperations.run/3` denies it with a stable permission failure

### Requirement: Native operation exclusions

`NativeOperations.unavailable/0` SHALL list every `methods.json` method not
exported, with its reason.

- Exclusion reasons are: interactive channels, binary transfers, selecting
  another backend or carrying credentials, or missing evidence.
- The generator SHALL remove the policy's denylisted body fields
  (`source.server`, `source.secret`, `source.certificate`, `source.url` and
  others) from every exported schema.
- The generator SHALL fail if any method is neither exported nor listed.

#### Scenario: Exec through the native document

- **WHEN** a host looks for `ExecInstance` in the native document
- **THEN** it is absent and listed as unavailable for an interactive channel, and the curated `incus_instance_exec` remains the way to run commands

#### Scenario: Remote image source

- **WHEN** native create input tries to set `body.source.server`
- **THEN** schema validation rejects it before host authorization or backend access

### Requirement: Native operation execution

`NativeOperations.run(name, input, host:, caller:, scopes:)` SHALL enforce the
same trust model as `Operations.run/3`, stopping at the first failure:
1. the operation is exported;
2. the caller holds its scope;
3. the input validates;
4. destructive confirmation matches its target;
5. restricted `config`/`devices` input passes the curated restricted-config
   rules;
6. the host's `binding/2` and `authorize/3` both succeed.

Only then SHALL it make exactly one `Incus.call/4`.

- Results SHALL be shaped into the native envelope within 262 144 bytes, or
  fail with `output_limit`.
- Background operations SHALL return their native operation identity without
  waiting.
- A response lost after possible acceptance SHALL be reported as uncertain,
  and MUST NOT be retried.

#### Scenario: Native delete with wrong confirmation

- **WHEN** `incus_native_delete_instance` is run with `name` `web` and `confirm` `db`
- **THEN** it fails with `confirmation_mismatch`, and no request reaches Incus

#### Scenario: Restricted native update

- **WHEN** native instance update input sets `raw.lxc` and the host has not allowed restricted input
- **THEN** it is denied before backend access

### Requirement: Pinned upstream API text

The library SHALL vendor Incus `doc/rest-api.yaml` unmodified, at the pinned
revision, as `priv/incus/rest-api.yaml`, with its SHA-256 recorded and checked
by `check:reference`. The file MUST NOT be included in the Hex package.

#### Scenario: Modified upstream file

- **WHEN** `rest-api.yaml` differs from the recorded SHA-256
- **THEN** `check:reference` fails before generation

### Requirement: Release cassette

Each `v*` release SHALL publish a tama-dex cassette named `opsmaru_incus`,
holding both operation documents' sources, as a GitHub Release asset named
`opsmaru_incus-<version>.tama-cassette`, together with its SHA-256 and a build
provenance attestation. It SHALL be built with tama_dex only as a dev/test
dependency, after the Hex publish succeeds.

#### Scenario: Consumer imports the cassette

- **WHEN** Macus imports a release cassette whose SHA-256 matches its pin
- **THEN** both sources are searchable under the `opsmaru_incus` cassette without building the index from the documents

#### Scenario: Consumer without tama_dex at runtime

- **WHEN** a client-only consumer depends on opsmaru_incus
- **THEN** it compiles without fetching tama_dex
