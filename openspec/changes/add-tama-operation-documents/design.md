# Design

## Context

- **The profile:** `tama-operations/1` is defined in kritama/tama-dex
  `docs/tama-operations-profile.md`.
  - The document carries `x-tama-profile` and `x-tama-source`.
  - Each operation is `POST /operations/{operationId}`, with a required JSON
    object request schema, a `200` result schema, an optional `default` error
    schema, and `x-tama-scopes` (every listed scope is required).
  - Operation fields: `x-tama-destructive`, optional `x-tama-confirmation
    {field, description}` (field must be a required top-level string),
    optional integer `x-tama-bounds` and optional `x-tama-identity`.
  - Other `x-<prefix>-*` keys are kept as opaque metadata.
  - tama-dex adds no deadline around executors, and marks every error
    `dispatched: true|false`.
- **Composite catalogue (0.1.0):** 32 exported operations.
  - Scopes are `incus.read` (22), `incus.write` (5), `incus.exec` (1) and
    `incus.delete` (4).
  - Confirmation fields are already required string `confirm` properties, for
    example "the instance name" or "`<instance>/<snapshot>`".
  - Every bounds value is an integer.
  - Output schemas are `oneOf` a success object and the shared `error` object.
  - The 12 mutation outputs carry `operation`, `operation_id`, `status`,
    `wait_error` and `waited_seconds`.
- **Native client registry:** `priv/incus/methods.json` has 307 JSON methods
  verified by invoking each unchanged official typed method (156 GET, 60 POST,
  36 DELETE, 30 PUT, 25 PATCH).
  - Each entry has `name`, `verb`, `path`, `params` (snake-case argument
    names), `query` templates, `body` model, `result` kind (`sync`, `list`,
    `model`, `operation`, `names`, `empty_sync` and others), a required API
    `extension` and field `guards`.
  - `models.json` has 232 native models as Go field types, with no
    descriptions.
  - `Opsmaru.Incus.call(client, name, arguments, body: ..., etag: ...)`
    executes a method by name.
- **Upstream text:** Incus publishes `doc/rest-api.yaml`, Swagger 2.0, at the
  pinned revision `13f3992766142d5087fff2e362cd2e1a75294fe8`.
  - 291 operations on 153 paths, all with `operationId` and summary, and 220
    definitions, with no security information.
  - It is generated from code comments and is unverified. It is vendored
    unmodified as `priv/incus/rest-api.yaml` (SHA-256
    `7b4e07375da92f30e7eadf766f1bbdf40bf9968ee305a16be1afe5998e72e91f`, matching
    the Go module cache copy).

## Goals

- Two producer documents that pass `tama-operations/1` validation, built as
  pure data with no dependency on tama_dex.
- The native API reachable through tama-dex search, but never as the default,
  and never with weaker trust than the composite operations.
- Native coverage that follows verified client methods exactly: the upstream
  YAML adds words, never operations or schemas.

## Non-goals

- Changing the `describe/1` data, composite operation names or schemas, or
  `coverage.json`. Only their module moves (Decision 1).
- Interactive exec or console, file and image transfer, migration, copy or
  cluster join through the native document.
- Waiting on native background operations. Callers use the composite
  `incus_operation_wait`/`get` tools, or `incus_native_get_operation`.

## Decisions

### 1. Two documents, two sources, two executors

| Source | Builder | Executor |
|---|---|---|
| `opsmaru_incus` | `Opsmaru.Incus.Operations.Composite.openapi/0` | `Operations.Composite.run/3` |
| `opsmaru_incus_native` | `Opsmaru.Incus.Operations.Native.openapi/0` | `Operations.Native.run/3` |

- Both builders are pure, returning the same JSON-safe map on every call, with
  `info.version` set to the package version.
- The native document is read at compile time from the generated
  `priv/incus/native-operations.json` (`@external_resource`), so no YAML is
  parsed at runtime or compile time in consumers.
- Separate sources let a host register different executors and grant native
  scopes independently. Source IDs stay `opsmaru_incus` and
  `opsmaru_incus_native`.
- **Module layout (user request, 2026-11-12):**

  | Module | Holds |
  |---|---|
  | `Opsmaru.Incus.Operations.Composite` | `all/0`, `describe/1`, `run/3`, `unavailable/0`, `openapi/0` for the composite operations |
  | `Opsmaru.Incus.Operations.Composite.*` | their implementations, moved from `Operations.Exec`, `Inspection`, `Instances`, `Mutation` and `OperationTools` |
  | `Opsmaru.Incus.Operations.Native` | `openapi/0`, `unavailable/0`, `run/3` for the native operations |
  | `Opsmaru.Incus.Operations.*` | shared infrastructure used by both: `Host`, `Descriptor`, `Schema`, `Fragments`, `Result`, `Evidence` |

  - `Opsmaru.Incus.Operations` keeps the 0.1.0 functions `all/0`,
    `describe/1`, `run/3` and `unavailable/0` as `@deprecated` delegates to
    `Composite` through 0.2.x, so 0.1.0 callers such as Macus keep compiling
    with a warning. They are removed in 0.3.0. It gains no `openapi/0`.
  - The operations catalogue test and the consumer fixtures move to
    `Composite`, and a test proves each deprecated delegate returns exactly
    what `Composite` returns.

### 2. Composite mapping

| Descriptor | Profile |
|---|---|
| `name` | path `/operations/{name}`, `operationId` |
| `title` | `summary` |
| `description` | `description` |
| resource in `incus_<resource>_<verb>` | `tags: [resource]` |
| `scope` | `x-tama-scopes: [scope]` |
| `destructive` | `x-tama-destructive` |
| `confirmation` `{field, value}` | `x-tama-confirmation {field, description: value}` |
| `bounds` | `x-tama-bounds` |
| `requires` | `x-opsmaru-requires` |
| `input_schema` | `requestBody` `application/json` schema |
| success branch of `output_schema` | `responses.200` |
| shared error object | `responses.default` |
| outputs with `operation_id` and `status` | `x-tama-identity: ["operation_id", "status"]` |

`jsonSchemaDialect` is the OAS 3.1 base dialect. Unavailable operations are
not listed.

### 3. Native generation

`mix opsmaru.incus.native` writes `priv/incus/native-operations.json`
deterministically, with sorted keys and operations ordered by `operationId`.
`check:reference` regenerates it to a temporary file and compares byte for
byte, and checks the `rest-api.yaml` SHA-256. The generator reads
`methods.json`, `models.json`, the evidence used by the coverage ledger,
`rest-api.yaml` and `priv/incus/native-policy.json`.

- **Inclusion:** a method is included only if it has recorded evidence and no
  exclusion applies (Decision 5). Upstream operations without a verified
  method are never added.
- **Identity:** `operationId` is `incus_native_` plus the method name in snake
  case (`DeleteInstance` → `incus_native_delete_instance`). Tags are `native`
  plus the first path segment after `/1.0` (`instances`, `storage-pools`,
  ...).
- **Text:** methods are joined to upstream operations on verb plus the path
  with every `{...}` placeholder normalized. When matched, the upstream summary
  and description are used. Otherwise the summary is `"<VERB> <path>"`. The
  description always ends with the native facts: method name, route, required
  API extension, result kind and field guards. Upstream definition and
  property descriptions are attached to body fields with matching model and
  field names.
- **Input schema:** an object with `additionalProperties: false`, containing:
  - each `params` entry as a required string, or an integer or boolean where
    `arg_types` says so;
  - optional `project` (the composite project pattern);
  - optional `etag` (a header-safe string) for methods that take one;
  - `body`, required when the method has a body model, converted from
    `models.json`;
  - `confirm` (required string) for destructive methods.
- **Model conversion:**
  - structs become objects, with embedded structs flattened;
  - `string`, `bool`, integer kinds, `float64`, `[]T`, `map[string]string`,
    `map[string]T` and `time.Time` (date-time string) map to their JSON Schema
    equivalents;
  - `ConfigMap` and `DevicesMap` become maps of strings or of string maps;
  - pointers allow `null`;
  - unknown types fail the generator.
  - Body objects allow no unknown properties, so the field denylist (Decision
    5) is enforceable.
- **Result schema:** `200` is a bounded native envelope `{kind, metadata?,
  etag?, operation_id?, operation?}`:
  - `metadata` uses the model schema for `model`, `list` and `sync`, a
    string array for `names` and `strings`, and is absent for `empty_sync`;
  - `operation` results return immediately with `operation_id` and the native
    operation object, and declare `x-tama-identity: ["operation_id"]`.
  - `default` is the shared composite error object.

### 4. Native scopes, destructive flags and confirmation

- **Scopes** are separate from the composite ones and never implied by them:
  - `incus.native.admin`: every method under `/1.0/certificates` and
    `/1.0/cluster`, plus `PUT`/`PATCH` of `/1.0`;
  - otherwise `incus.native.read` for `GET`, `incus.native.delete` for
    `DELETE`, and `incus.native.write` for `POST`, `PUT` and `PATCH`.
- **Destructive:** every `DELETE` and every `PUT` (full replacement) is
  destructive. `confirm` must repeat the value of the method's last path
  parameter, or the literal `server` for methods without one. The generator
  writes that rule into `x-tama-confirmation.description`, for example
  "the exact value of `name`".
- **Overrides:** `native-policy.json` can override a scope, the destructive
  flag or the confirmation target for named methods. Every override carries a
  reason and is reviewed like a lock.

### 5. Native exclusions

`Operations.Native.unavailable/0` lists every method that isn't exported, with
its reason. The rules are applied in order:

1. **Interactive channel:** operations whose result opens websockets
   (`ExecInstance`, `ConsoleInstance`).
2. **Binary transfer:** non-JSON request or response bodies, such as instance
   and template files, image and backup export, console and exec output logs.
3. **Remote backend or credential:** calls whose purpose requires selecting
   another server or carrying a secret, such as migration and copy sources,
   image download by URL or remote, cluster join and member tokens, and
   certificate add with tokens. Beyond excluding these, the generator removes
   denylisted body fields from the remaining schemas (`source.server`,
   `source.secret`, `source.certificate`, `source.operation`,
   `source.websockets`, `source.url` and others listed in the policy). Native
   input therefore cannot select a backend, as the composite rules require.
4. **No evidence:** methods without recorded evidence.

Rules 2 and 3 come from reviewed lists in `native-policy.json`. The generator
fails if any method in `methods.json` is neither exported nor listed.

### 6. Native execution

`Operations.Native.run(name, input, host:, caller:, scopes:)` runs in the
caller's process and mirrors `Operations.Composite.run/3`. Each step stops at its first
failure:

1. The operation is exported, otherwise `unknown_operation`.
2. The caller holds its scope, otherwise `permission_denied`.
3. The input validates against the input schema, otherwise `invalid_input`.
4. For destructive methods, `confirm` equals the target value, otherwise
   `confirmation_mismatch`.
5. Restricted-config rules: any `body.config` or `body.devices` (instances,
   profiles, projects) goes through the composite restricted-config check
   (`raw.*`, `security.privileged`, host-path disks and the rest), with
   `allow_restricted?/3`.
6. The host's `binding/2` and then `authorize(caller, operation_id, input)`.
7. One `Incus.call(client, method, params, body:, etag:)`, with the optional
   `project` applied the composite way.
8. Shaping: the result goes into the envelope, limited to `max_output_bytes`
   (262 144). Larger results fail with `output_limit` rather than being
   truncated.
9. Lost responses after a request may have been accepted are reported as
   `uncertain`, with any known operation identity, as in the composite
   mutations. Nothing is retried.

Errors use the composite error object, so the `default` schema holds.

### 7. Packaging and evidence

- **Package contents:** ships `native-operations.json` and
  `native-policy.json`. `rest-api.yaml` is excluded, because it is generator
  input only: the package `files` list names `priv/incus` entries explicitly,
  and `check:consumer` fails if the YAML is packaged.
- **Coverage:** `coverage.json` is unchanged. Exporting a native method is a
  projection of existing evidence, and success through `Operations.Native` is
  never recorded as client evidence.

### 8. Release cassette

Each opsmaru_incus release also publishes a **cassette**: a tama-dex index file
in the format defined by tama-dex's `cassette` capability. It is one cassette
named `opsmaru_incus`, holding both sources (`opsmaru_incus` and
`opsmaru_incus_native`). In a host's tama-dex index the cassette name is the
namespace, so agents address these operations as
`(opsmaru_incus, <operation_id>)` and other cassettes may reuse the names. Macus can import it at
install or `macus start` without indexing.

- **Build:** the `v*` tag workflow builds the cassette after the Hex publish
  succeeds, with `mix tama.dex.cassette --name opsmaru_incus --version
  <version>`, from
  `Opsmaru.Incus.Operations.Composite.openapi/0` and
  `Opsmaru.Incus.Operations.Native.openapi/0`.
  - `tama_dex` is a dev/test-only dependency (`runtime: false`), so consumers
    never fetch it.
  - The asset is named `opsmaru_incus-<version>.tama-cassette`, with a
    `.sha256` file beside it.
- **Publish:** a GitHub Release for the tag carries the cassette, its SHA-256
  and a build provenance attestation (`actions/attest-build-provenance`). The
  notes come from the version's `CHANGELOG.md` section.
  - The job needs `contents: write`, `id-token: write` and
    `attestations: write`. All actions are pinned by commit SHA.
- **Why a GitHub Release asset, not the Hex package (user decision,
  2026-11-12):** Hex stays the only route for the package itself. The
  cassette is derived data, built from the documents the package already
  ships, and is published beside the package rather than inside it. Client-only
  consumers therefore never carry it. A host that bundles it pins its own
  SHA-256 and keeps that pin in step with its locked `opsmaru_incus` version.
  Shipping it inside the package under `priv/` was considered and not chosen.
- **Trust:** the cassette embeds the canonical documents and their digests, so
  an importer can verify it and fall back to the documents if its tama-dex
  index schema differs.
  - Consumers should pin the cassette's SHA-256, as Macus pins appliance
    images, rather than trust the URL alone.
  - The Hex package still carries the documents' sources, so a consumer
    without the cassette builds the same index from `openapi/0`.
- **Blocking:** this task can run only after tama_dex, with the `cassette`
  capability, is released on Hex.

### 9. Conformance with tama-dex

Until tama_dex is released, tests check the documents structurally against the
profile rules:
- path equals `operationId`, and IDs are unique and match the pattern;
- required fields and limits hold;
- confirmation fields are required strings;
- identity names are declared output properties;
- every schema compiles with the library's JSON Schema validator.

Once tama_dex is on Hex, a test-only dependency runs
`Tama.Dex.Profile.validate/1` on both documents.

## Risks

- **Upstream text drift or mismatch:** the text is pinned and hash-checked,
  and unmatched methods get generated summaries. Search quality degrades
  gracefully; correctness doesn't depend on the text.
- **Native API breadth:** separate native scopes, a destructive flag with
  confirmation on every `DELETE`/`PUT`, backend-selecting fields removed, host
  `authorize/3` on every call, and reviewed exclusions. Hosts that don't grant
  `incus.native.*` see none of it.
- **Model conversion gaps:** the generator fails on unknown Go types, and the
  regenerated JSON is reviewed in every `check:reference`.
