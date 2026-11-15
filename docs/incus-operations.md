# Shared Incus operations

`Opsmaru.Incus.Operations.Composite` defines each agent-facing Incus operation
once: a canonical `incus_<resource>_<verb>` name, input/output JSON schemas, a required
scope, a destructive-confirmation rule and bounds. Macus and central Opsmaru
expose the same descriptors, so names and schemas are public contract from the
first consumer pin. The library defines and runs them; how a host exposes
them to agents (MCP tools, a search/execute index, a REST surface) is the
host's choice. Nothing here starts a process, endpoint, task store or
connection.

Since 0.2.0 the composite operations live in
`Opsmaru.Incus.Operations.Composite`; `Opsmaru.Incus.Operations.Native` is the
namespace for the native client operations. Shared infrastructure, including
the `Opsmaru.Incus.Operations.Host` behaviour, stays under
`Opsmaru.Incus.Operations`. The 0.1.0 entry points on `Opsmaru.Incus.Operations`
(`all/0`, `describe/1`, `run/3`, `unavailable/0`, and `scopes/0`, `fetch/1`,
`output_schema/1`) remain through 0.2.x as deprecated delegates that return
exactly what `Composite` returns, and are removed in 0.3.0.

Every operation runs synchronously through the public `Opsmaru.Incus` client.
Tool success is not client coverage: `priv/incus/coverage.json` and the
endpoint ledgers are unchanged by tools.

## Catalogue

<!-- operations-catalogue:start -->
| Operation | Scope | Confirmation (`confirm` must repeat) | Client evidence |
| --- | --- | --- | --- |
| `incus_image_alias_list` | `incus.read` | — | `GetImageAliases` |
| `incus_image_delete` | `incus.delete` | the full fingerprint | `DeleteImage`, `GetOperationWait` |
| `incus_image_get` | `incus.read` | — | `GetImage` |
| `incus_image_list` | `incus.read` | — | `GetImages` |
| `incus_instance_create` | `incus.write` | — | `CreateInstance`, `GetOperationWait` |
| `incus_instance_delete` | `incus.delete` | the instance name | `DeleteInstance`, `GetOperationWait` |
| `incus_instance_exec` | `incus.exec` | — | `ExecInstance`, `stream:S01` |
| `incus_instance_get` | `incus.read` | — | `GetInstance` |
| `incus_instance_list` | `incus.read` | — | `GetInstances` |
| `incus_instance_snapshot_create` | `incus.write` | — | `CreateInstanceSnapshot`, `GetOperationWait` |
| `incus_instance_snapshot_delete` | `incus.delete` | `<instance>/<snapshot>` | `DeleteInstanceSnapshot`, `GetOperationWait` |
| `incus_instance_snapshot_get` | `incus.read` | — | `GetInstanceSnapshot` |
| `incus_instance_snapshot_list` | `incus.read` | — | `GetInstanceSnapshots` |
| `incus_instance_snapshot_restore` | `incus.delete` | `<instance>/<snapshot>` | `UpdateInstance`, `GetOperationWait` |
| `incus_instance_state_get` | `incus.read` | — | `GetInstanceState` |
| `incus_instance_state_update` | `incus.write` | — | `UpdateInstanceState`, `GetOperationWait` |
| `incus_instance_update` | `incus.write` | — | `PatchInstance`, `GetInstance` |
| `incus_network_get` | `incus.read` | — | `GetNetwork` |
| `incus_network_list` | `incus.read` | — | `GetNetworks` |
| `incus_operation_cancel` | `incus.write` | — | `GetOperation`, `DeleteOperation` |
| `incus_operation_get` | `incus.read` | — | `GetOperation` |
| `incus_operation_list` | `incus.read` | — | `GetOperations` |
| `incus_operation_wait` | `incus.read` | — | `GetOperationWait` |
| `incus_profile_get` | `incus.read` | — | `GetProfile` |
| `incus_profile_list` | `incus.read` | — | `GetProfiles` |
| `incus_project_get` | `incus.read` | — | `GetProject` |
| `incus_project_list` | `incus.read` | — | `GetProjects` |
| `incus_server_get` | `incus.read` | — | `helper:connect` |
| `incus_storage_pool_get` | `incus.read` | — | `GetStoragePool` |
| `incus_storage_pool_list` | `incus.read` | — | `GetStoragePools` |
| `incus_storage_volume_get` | `incus.read` | — | `GetStoragePoolVolume` |
| `incus_storage_volume_list` | `incus.read` | — | `GetStoragePoolVolumes` |
<!-- operations-catalogue:end -->

The full schemas, titles, descriptions and bounds are pinned in
[test/fixtures/incus/operations-catalogue.json](../test/fixtures/incus/operations-catalogue.json);
`Composite.describe/1` returns the same data at runtime.

Not exported (`Composite.unavailable/0`): `incus_instance_copy`,
`incus_instance_rename` and `incus_instance_move`, deferred by scope
(user decision 2026-11-04), not for missing evidence. Events, console
attachment and file or image binary transfer are excluded because they need
streaming beyond a bounded result.

### Evidence gate

Each descriptor names the client requirements it uses: a native method, a
helper (`helper:connect`) or a streaming contract (`stream:S01`).
`Opsmaru.Incus.Operations.Evidence` reads `endpoint-inventory.json` and
`coverage.json` at compile time. A requirement has evidence only when every
endpoint row mapping it is behavior-complete under a completion record (a
stream contract must be certified) and its Go coverage entry, where one exists,
names an implementation and evidence files. `all/0` exports only descriptors
whose requirements all have evidence; any other descriptor is listed by
`unavailable/0` with its missing requirements.

## Scopes and confirmation

| Scope | Operations |
| --- | --- |
| `incus.read` | server, instance, snapshot, image, project, profile, network, storage and operation inspection; operation get/wait |
| `incus.write` | instance create/update/state, snapshot create, operation cancel |
| `incus.exec` | bounded guest exec |
| `incus.delete` | instance, snapshot and image deletion; snapshot restore |

Scopes are the host-verified grants; they never come from tool input. A
destructive operation also requires `confirm` to repeat the affected resource
exactly (`web`, `web/snap0` or the full 64-character image fingerprint).
Inferred consent such as `"yes"` is refused.

## Bounds

| Bound | Value |
| --- | --- |
| Input | 16 KiB for reads, 64 KiB for mutations, 1 MiB for exec |
| Tool output | 256 KiB of JSON |
| List items | 100 by default, at most 500 (`limit`) |
| Mutation and operation wait | 10 s by default, at most 60 s (`wait_seconds`) |
| Exec duration | 30 s by default, at most 300 s (`timeout_seconds`) |
| Exec argv / environment | 64 arguments of at most 4096 characters; 64 variables |
| Exec stdin | 64 KiB UTF-8 |
| Exec capture | first 64 KiB per stream, the rest counted |
| Exec stream total | 64 MiB, or half the connection's `max_stream_bytes` |

Lists keep native order and report the native total (`count`) and
`truncated`. A list that exceeds the output bound drops items from the end; a
single item that alone exceeds it fails with `output_limit`.

Every native request is bounded by the host connection's `timeout`. The
effective server-side wait is `min(wait_seconds, floor(timeout / 1000) - 1)`,
reported as `waited_seconds`; configure at least 61 s to allow the full 60 s
wait. The exec duration is likewise capped at `stream_timeout` minus the 5 s
kill grace and reported as `timeout_seconds`.

## Host binding

A host implements `Opsmaru.Incus.Operations.Host`:

```elixir
defmodule MyHost.IncusOperations do
  @behaviour Opsmaru.Incus.Operations.Host

  # The trusted backend for this caller: a discovered client, or a connection
  # and context that the operation discovers after authorization.
  @impl true
  def binding(caller, _operation), do: {:ok, MyHost.connection(), MyHost.context(caller)}

  # Validated, normalized input, including any native "project".
  @impl true
  def authorize(caller, operation, input), do: MyHost.Policy.check(caller, operation, input)

  # Optional: host-approved image servers, named in input only by remote name.
  @impl true
  def image_remote(_caller, "images"),
    do: {:ok, %{"server" => "https://images.linuxcontainers.org", "protocol" => "simplestreams"}}

  def image_remote(_caller, _name), do: {:error, :unknown_remote}

  # Optional: allow restricted config keys or devices.
  @impl true
  def allow_restricted?(_caller, _operation, _items), do: false
end

Opsmaru.Incus.Operations.Composite.run("incus_instance_list", %{"project" => "default"},
  host: MyHost.IncusOperations,
  caller: verified_caller,
  scopes: verified_scopes
)
```

`run/3` checks, in order: scope, input schema and byte bounds, confirmation,
restricted input, `binding/2`, `authorize/3`, image remote resolution and then
discovery (when the binding returned a connection and context). The native
project is selected only after authorization. A missing, raising, exiting or
malformed callback denies the call before any backend request; tool input
cannot name a socket, URL, credential, owner or host path.

Restricted create/update input, denied unless `allow_restricted?/3` returns
`true`: config keys `raw.*`, `volatile.*`, `security.privileged`,
`security.idmap.*`, `security.syscalls.*` and `linux.kernel_modules`; any
device except a `disk` with a `pool` and no host-path `source`, or a `nic`
with a `network` and no `nictype` or `parent`.

## Results

Success results are JSON objects; failures are `{"error": {"kind", "message", ...}}`
and match each tool's output schema.

- Inspection: `{"items", "count", "truncated"}` or `{"item"}`;
  `incus_instance_get` adds the native `etag`. Native data, including VM-shaped
  instances and unknown fields, passes through unchanged.
- Mutations: `{"status", "operation_id", "operation", "waited_seconds", "wait_error"}`.
  `completed` and `failed` mean the native outcome was observed; `running`
  means it was not observed within the wait (including a local wait deadline,
  which never cancels anything); `uncertain` means the request may have been
  accepted but no response was decoded. Nothing is resent automatically. A
  native rejection before acceptance is an error with `http_status`,
  `error_code` and the native `message`.
- `incus_instance_update` sends a conditional PATCH of only the given fields.
  Without `etag` it reads the current ETag first; `etag_source` says which.
- `incus_operation_cancel` reads the operation first and reports
  `already_final`, `unsupported` (`may_cancel` is false), `requested` (one
  native DELETE was accepted) or `uncertain`. Completion stays authoritative.
- `incus_instance_exec` runs one noninteractive command (no PTY, no recorded
  output). Output is returned as UTF-8, or base64 when it is not UTF-8, with
  byte counts and a `truncated` flag per stream. At the duration, or past the
  stream total, a short-lived process linked to the call sends `SIGKILL` once
  over the control channel and collection has 5 s to observe the exit
  (`timed_out` or `output_limited`). An exit not observed is `running` with
  the operation identity.

## Operation documents

Both sets of operations are published as `tama-operations/1` documents: plain
OpenAPI 3.1 data with `x-tama-*` extensions, which
[tama-dex](https://hexdocs.pm/tama_dex) indexes behind a host's `search` and
`execute` tools. The profile is defined in tama-dex's
`docs/tama-operations-profile.md`. The library does not depend on tama_dex;
the documents are data and the host owns the index.

| Source | Document | Executor | Operations |
| --- | --- | --- | --- |
| `opsmaru_incus` | `Opsmaru.Incus.Operations.Composite.openapi/0` | `Composite.run/3` | the 32 composite operations above |
| `opsmaru_incus_native` | `Opsmaru.Incus.Operations.Native.openapi/0` | `Native.run/3` | 274 native client methods |

Each builder returns the same JSON-safe map on every call for a release, with
`info.version` set to the package version. Every operation is
`POST /operations/{operationId}` (a naming convention; nothing is served over
HTTP) with an input schema, a `200` result schema and the shared error object
as `default`.

The composite document maps each descriptor field for field:

| Descriptor | Document |
| --- | --- |
| `name` | path and `operationId` |
| `title`, `description` | `summary`, `description` |
| resource in `incus_<resource>_<verb>` | `tags` |
| `scope` | `x-tama-scopes` |
| `destructive` | `x-tama-destructive` |
| `confirmation` | `x-tama-confirmation` (`field`, and the value to repeat as `description`) |
| `bounds` | `x-tama-bounds` |
| `requires` | `x-opsmaru-requires` |
| `input_schema` | request body schema |
| success branch of `output_schema` | `200` |
| shared error object | `default` |
| results with `operation_id` and `status` | `x-tama-identity` |

Operations listed by `unavailable/0` are in neither document.

### Executors and errors

`Composite.run/3` and `Native.run/3` take the same options and the same
`Opsmaru.Incus.Operations.Host` module. Both return `{:ok, result}`, which
matches the operation's `200` schema, or `{:error, error}` where `error` is
`%{"kind" => ..., "message" => ...}`. The `default` schema is the wrapped
form, `{"error": error}`, so a host executor wraps the error map:

```elixir
defmodule Macus.IncusExecutor do
  @behaviour Tama.Dex.Executor
  alias Opsmaru.Incus.Operations.{Composite, Native}

  # One adapter serves both sources; the host module and the verified scopes
  # are the same. tama-dex passes the scopes it checked and the host's caller.
  @impl true
  def execute(%Tama.Dex.Call{} = call, input) do
    options = [host: Macus.IncusHost, caller: call.context, scopes: call.scopes]

    case run(call.source).(call.operation_id, input, options) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, %{"error" => error}}
    end
  end

  defp run("opsmaru_incus"), do: &Composite.run/3
  defp run("opsmaru_incus_native"), do: &Native.run/3
end

# At start, or instead of importing the release cassette:
{:ok, _} = Tama.Dex.load(index, Composite.openapi(), cassette: "opsmaru_incus")
{:ok, _} = Tama.Dex.load(index, Native.openapi(), cassette: "opsmaru_incus")

Tama.Dex.execute(index, "opsmaru_incus", "incus_native_get_instance", %{"name" => "web"},
  scopes: verified_scopes,
  context: verified_caller,
  executors: %{
    "opsmaru_incus" => Macus.IncusExecutor,
    "opsmaru_incus_native" => Macus.IncusExecutor
  }
)
```

tama-dex checks scopes and schemas too, but the executors repeat every check
themselves, so a host that calls `run/3` directly gets the same guarantees.
`test/operations_tama_dex_test.exs` runs this arrangement against the fixture
backend, with tama_dex as a test-only dependency.

Each release also publishes one tama-dex cassette named `opsmaru_incus`
holding both sources, as a GitHub Release asset
(`opsmaru_incus-<version>.tama-cassette` with a `.sha256` file and a build
provenance attestation). It is derived data and is never inside the Hex
package. A host that imports it should pin its SHA-256 and keep that pin in
step with its locked `opsmaru_incus` version; without it, loading the two
documents builds the same index.

## Native operations

`Opsmaru.Incus.Operations.Native` exposes the native client API itself: one
operation per verified `priv/incus/methods.json` method, named
`incus_native_<snake_method>` (`DeleteInstance` is
`incus_native_delete_instance`). The document is generated by
`mix opsmaru.incus.native` into `priv/incus/native-operations.json` and read at
compile time; see [priv/incus/README.md](../priv/incus/README.md). The
methods registry decides which operations exist and `models.json` their
schemas. The upstream Incus `rest-api.yaml` contributes summaries and
descriptions only.

Prefer the composite operations. Native operations are for what the composite
catalogue does not cover, and they are deliberately harder to reach.

### Input and result

| Input field | Meaning |
| --- | --- |
| the method's parameters | path and query values, all required; `filters` is a list of `key=value` strings |
| `project` | optional native project; absent on all-projects methods |
| `etag` | sent as If-Match; optional on `PUT`, required on `PATCH` |
| `body` | the native request model; unknown fields are rejected |
| `confirm` | required on destructive operations |

The result is a bounded envelope, at most 256 KiB of JSON (larger results fail
with `output_limit` rather than being truncated):

```json
{"kind": "model", "metadata": {"name": "web"}, "etag": "..."}
{"kind": "operation", "operation_id": "<uuid>", "operation": {"id": "<uuid>"}}
```

`kind` is the method's result kind: `model`, `list`, `sync`, `names`,
`strings`, `empty_sync`, `operation` and the grouped variants. Native data,
including unknown fields, passes through unchanged. A background operation
returns its identity at once and is never waited on; follow it with the
composite `incus_operation_get` or `incus_operation_wait`. A response lost
after the request may have been accepted is the error `uncertain`, with the
operation identity when it is known. Nothing is retried.

### Scopes and confirmation

Native scopes are separate from the composite ones and never implied by them.
A caller holding every composite scope can neither find nor run a native
operation.

| Scope | Operations |
| --- | --- |
| `incus.native.read` | `GET` |
| `incus.native.write` | `POST`, `PUT`, `PATCH` |
| `incus.native.delete` | `DELETE` |
| `incus.native.admin` | everything under `/1.0/certificates` and `/1.0/cluster`, `PUT`/`PATCH` of `/1.0`, and (by policy) creating, changing, renaming or deleting projects |

Every `DELETE` and every `PUT` (a full replacement) is destructive, as are
`RebuildInstance` and `RebuildStoragePoolVolume` by policy. `confirm` must
equal the value of the operation's last path parameter, for example the
instance name. Operations without one confirm a literal: `server` for
`PUT /1.0`, `instances` for the bulk state change. A wrong value fails with
`confirmation_mismatch`.

Any `body.config` or `body.devices` passes through the composite
restricted-input rules (see [Host binding](#host-binding)), so `raw.*`,
`security.privileged`, host-path disks and the rest need the host's
`allow_restricted?/3`.

### Exclusions

`Native.unavailable/0` lists the 33 client methods that are not exported, each
with its rule and reason. The rules apply in order:

| Rule | Methods |
| --- | --- |
| `interactive_channel` | `ExecInstance`, `ConsoleInstance` (they open websockets; use `incus_instance_exec`) |
| `binary_transfer` | instance file, template, log and recorded exec output listing and deletion, whose content is a binary transfer |
| `remote_backend_or_credential` | migration between servers, image export and image secrets, certificate and cluster join tokens, cluster join and cluster certificate update, operation and image secrets, storage bucket keys and anything returning them |
| `no_evidence` | a method without recorded client evidence (none today) |

The exported schemas also drop every body field that could select another
backend or carry its credentials: `source.server`, `source.secret`,
`source.certificate`, `source.operation`, `source.secrets`, `source.protocol`
and `source.mode` on instance and volume sources, the image source `url`,
migration and backup `target` objects, and certificate tokens. Because body
objects allow no unknown fields, native input cannot name a backend: creating
an instance with `body.source.server` fails schema validation before the host
is asked anything.

The lists, the removed fields and the overrides live in
`priv/incus/native-policy.json`, each entry with its reason.

## Exposing operations

The library ships no protocol binding and no MCP tools. A host either indexes
the two documents with tama-dex and registers the executors, as above, or
builds its own surface over `Composite.all/0`, `fetch/1`, `describe/1` and
`run/3`, for example one tool per operation. If one tool fronts many
operations, pass the caller's verified scopes to `run/3`: it enforces each
operation's own scope, so access to the fronting tool does not grant every
operation. An earlier optional TamaMCP binding was removed on 2026-11-04 by
user decision, before any consumer pinned it.

## Evidence classes

| Class | Where | Status |
| --- | --- | --- |
| Fixtures | `test/operations_*_test.exs` over fake Unix and mutual HTTPS Incus | run by `mise run check` |
| Documents | `test/operations_composite_openapi_test.exs`, `test/operations_native_test.exs` and `test/operations_native_generator_test.exs` against the profile rules; the generated native document is compared byte for byte | run by `mise run check` and `mise run check:reference` |
| Release cassette | `.github/scripts/build-cassette.sh` builds it from both `openapi/0` builders and `scripts/verify-cassette.exs` imports it into a fresh index, pinned to its `.sha256` | run locally on 2026-11-15 at version 0.1.0 (two builds were byte-identical; both sources searchable); the publish workflow itself first runs on the `v0.2.0` tag |
| Isolated consumers | `test/consumer` (Macus-compatible host running an operation through its binding) and `test/consumer/client_only` (no `tama_mcp`, Plug, Cowboy or Phoenix) | run by `mise run check:consumer` at a pushed revision |
| Real Incus | explicit isolated opt-in (task 4.2) | recorded separately in [real-incus-acceptance.md](https://github.com/upmaru/opsmaru-incus/blob/main/docs/real-incus-acceptance.md) |
| Macus composition and hardware | Macus `add-elixir-server` | consumer-owned |
