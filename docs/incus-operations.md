# Shared Incus operations

`Opsmaru.Incus.Operations` defines each agent-facing Incus operation once: a
canonical `incus_<resource>_<verb>` name, input/output JSON schemas, a required
scope, a destructive-confirmation rule and bounds. Macus and central Opsmaru
expose the same descriptors, so names and schemas are public contract from the
first consumer pin. The library defines and runs them; how a host exposes
them to agents (MCP tools, a search/execute index, a REST surface) is the
host's choice. Nothing here starts a process, endpoint, task store or
connection.

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
`Operations.describe/1` returns the same data at runtime.

Not exported (`Operations.unavailable/0`): `incus_instance_copy`,
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

Opsmaru.Incus.Operations.run("incus_instance_list", %{"project" => "default"},
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

## Exposing operations

The library ships no protocol binding. A host builds its own over `all/0`,
`fetch/1`, `describe/1` and `run/3`, for example one tool per operation, or a
`search` tool over `describe/1` plus an `execute` tool that calls `run/3`.
If one tool fronts many operations, pass the caller's verified scopes to
`run/3`: it enforces each operation's own scope, so access to the fronting
tool does not grant every operation. An earlier optional TamaMCP binding was
removed on 2026-11-04 by user decision, before any consumer pinned it.

## Evidence classes

| Class | Where | Status |
| --- | --- | --- |
| Fixtures | `test/operations_*_test.exs` over fake Unix and mutual HTTPS Incus | run by `mise run check` |
| Isolated consumers | `test/consumer` (Macus-compatible host running an operation through its binding) and `test/consumer/client_only` (no `tama_mcp`, Plug, Cowboy or Phoenix) | run by `mise run check:consumer` at a pushed revision |
| Real Incus | explicit isolated opt-in (task 4.2) | recorded separately in [real-incus-acceptance.md](real-incus-acceptance.md) |
| Macus composition and hardware | Macus `add-elixir-server` | consumer-owned |
