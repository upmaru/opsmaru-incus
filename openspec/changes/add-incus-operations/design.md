# Design

## Context

`:opsmaru_incus` is a pure library providing the native Incus client; Macus and central Opsmaru both depend on it. Opsmaru's earlier `add-compute-substrate` planned shared tools as `Opsmaru.MCP.Tools.*` inside the `:opsmaru` application, coupled to durable tasks, a target registry and connectors. With `:opsmaru` now the central service only and the first milestone being a standalone Macus, the tool contract moves here and durable tasks are deferred.

TamaMCP (`:tama_mcp`, used by Macus at 0.1.1) defines tools as modules using `TamaMCP.Tool` with scopes, task policy, schemas and a `call/2` callback, and supports synchronous tool execution. A host composes tools into its own `TamaMCP.Server` module with `tool Module, name: "..."`. Authorization, validator cache and task adapters are application-owned.

## Goals / Non-Goals

**Goals:**

- One definition of each Incus operation, usable from MCP, a future REST surface and direct Elixir calls.
- Host-supplied trust: connection, context, caller identity and authorization never come from tool input.
- Truthful synchronous results that distinguish native acceptance from observed completion.

**Non-Goals:**

- Durable MCP tasks, task stores, runners, journals or task notifications.
- Target IDs, registries, central dispatch or connectors.
- Macus runtime (Swift/VZ) tools, an MCP endpoint or HTTP server, or authentication of callers.
- Arbitrary host commands, arbitrary HTTP, or unrestricted guest execution.

## Decisions

### 1. Protocol-neutral descriptors with an optional MCP binding

Each operation is a descriptor in `Opsmaru.Incus.Operations` with an immutable canonical name (for example `incus_instance_list`), description, input/output JSON schemas, required scope, destructive flag, bounds and a run function `(client, input, opts)` that uses only public `Opsmaru.Incus` calls. `Opsmaru.Incus.Operations.all/0` lists them for hosts and documentation.

`Opsmaru.Incus.MCP.Tools.*` wraps each descriptor as a `TamaMCP.Tool` module with matching scopes and schemas, task policy that never creates tasks, and a `call/2` that resolves the host binding and invokes the descriptor. `tama_mcp` is declared `optional: true` and these modules compile only when it is present. A helper documents the canonical name for each tool module so hosts register them under those names; duplicate names fail the host's compilation as TamaMCP already enforces.

Alternative: write tools directly against TamaMCP. That would tie a future REST surface and direct callers to MCP types, and force every consumer to depend on TamaMCP.

### 2. Host binding owns trust

A host implements `Opsmaru.Incus.Operations.Host` callbacks that, for an authenticated caller from the protocol context, return the trusted `Opsmaru.Incus.Connection` and `Opsmaru.Incus.Context` to use, and authorize the operation and input. The host decides which project(s) a caller may use; operations pass native project selection from input only after host authorization. Input fields can never select a socket, URL, credential, owner or host path. Missing or failing host callbacks deny before any backend access.

Scopes follow the planned Macus/Opsmaru split: `incus.read` for inspection, `incus.write` for instance/state/image/snapshot mutation, `incus.exec` for guest exec, `incus.delete` for deletion and destructive restore. Destructive operations additionally require an explicit confirmation input that names the affected resource; inferred consent is never accepted.

### 3. Synchronous execution without durable tasks

Tools execute within the request. Inspection returns native data. Mutations submit the native request and then wait up to a bounded, caller-limited deadline for the native operation. The result reports the native operation identity and one of: completed (with final status), still running, or failed. A response lost after possible acceptance is reported as uncertain with any known operation identity; mutations are never retried automatically. Operation tools (`incus_operation_get`, `incus_operation_wait`, `incus_operation_cancel`) let callers poll or request supported cancellation; a local timeout is never reported as remote cancellation.

Durable MCP tasks are deferred. Because results already carry native operation identity, a later durable layer can wrap the same descriptors without changing their schemas.

### 4. Bounds and catalogue

Each descriptor declares input size, output size, list length and deadline bounds; results that exceed them are truncated with an explicit indicator or fail visibly. Guest exec runs only in an explicitly named instance, with bounded argv, environment, stdin, captured output and duration, and no interactive terminal. Events, console attachment, file and image binary transfer are excluded from the initial catalogue because they need streaming beyond a bounded MCP result.

Initial operations: server info; list/get instances, images, projects, profiles, networks, storage pools and volumes, and operations; instance create, update and state change; snapshot create and restore; instance, snapshot and image deletion; bounded exec; operation get, wait and cancel. Each operation records the client methods it uses and their coverage evidence. An operation whose client methods lack evidence is not exported.

### 5. Verification

Fixture tests use the existing fake Unix/HTTPS Incus endpoints: schemas, scope and confirmation denial with zero backend requests, forged connection fields, bounds and truncation, accepted/completed/uncertain mutation results and exec limits. The TamaMCP binding is tested with TamaMCP's conformance helpers and a fixture host server. The isolated consumer fixture compiles the library with and without `tama_mcp`. Real-Incus checks reuse the explicit opt-in acceptance environment. Macus composition and hardware acceptance are Macus's.

### 6. Approved scope (2026-11-04)

User decisions (2026-11-04), made before implementation:

- **Names.** Canonical names are `incus_<resource>_<verb>` in lowercase snake case (underscores only, at most 64 characters), so they pass strict client tool-name rules. Names and input/output schemas are public contract from the first consumer pin.
- **Copy/migration deferred.** Instance copy, rename and move stay out of the initial catalogue by scope, not for missing evidence (3.9 is closed and S10 is certified). `Opsmaru.Incus.Operations.unavailable/0` lists them with that reason.
- **TamaMCP.** `{:tama_mcp, "~> 0.1.1 or ~> 0.2.0", optional: true}`. The binding uses only API both lines share: `use TamaMCP.Tool, task: :disabled, scopes: [...]`, `raw_input_schema/1`, `raw_output_schema/1`, `call/2` and `TamaMCP.Response`. It declares no `annotations:` because 0.1.1 fails to compile them. Local tests and the consumer use 0.1.1, Macus's pin.
- **Curated create/update input.** Instance create accepts `name`, `type` (`container` or `virtual-machine`), an image source (`alias` or `fingerprint`, optionally a host-named `remote`), `profiles`, `config`, `devices`, `ephemeral`, `description` and `start`. The input never carries `source.server`, a URL, a secret or a certificate: a `remote` is a name the host resolves through its optional `image_remote/2` callback, and absent that callback only local images are accepted. Restricted input is denied unless the host's optional `allow_restricted?/3` callback allows it: config keys `raw.*`, `volatile.*`, `security.privileged`, `security.idmap.*`, `security.syscalls.*`, `linux.kernel_modules`, and any device other than a `disk` with a `pool` and non-path `source` (or the root disk) or a `nic` with a `network` and no `nictype`/`parent`.
- **Update is a conditional PATCH.** `incus_instance_update` sends only the present curated fields (`config`, `devices`, `profiles`, `description`, `ephemeral`) through the evidenced conditional instance PATCH. The client requires an ETag; when the caller gives none, the tool reads the instance first and uses its ETag, and reports which ETag it used. A concurrent change surfaces as the native 412.
- **Instance types.** Create accepts containers and VMs; the host may refuse VMs in `authorize/3`. Inspection passes VM-shaped native data through unchanged, and fixtures include VM samples.
- **Exec input.** Bounded `command` (argv), `environment`, `cwd`, `user`, `group` and UTF-8 `stdin`; never interactive, no PTY, no width/height, no recorded output.
- **Bounds (moderate).** Mutation wait 10 s default, 60 s maximum; exec duration 30 s default, 300 s maximum; exec capture 64 KiB per stream; stdin 64 KiB; argv 64 arguments of at most 4 KiB; environment 64 entries; list results 100 items default, 500 maximum; tool output 256 KiB.

#### Host binding

`Opsmaru.Incus.Operations.Host` callbacks, each receiving the host's own `caller` term:

- `binding(caller, operation)` returns `{:ok, %Opsmaru.Incus{}}` (an already discovered client) or `{:ok, %Connection{}, %Context{}}`, in which case the operation runs `Opsmaru.Incus.connect/2` first. Any other value, a raise or an exit denies before backend access.
- `authorize(caller, operation, input)` receives the validated, normalized input (including any `project`) and returns `:ok` or `{:error, reason}`. The host decides which projects a caller may use; the operation selects the project only after this returns `:ok`.
- Optional `image_remote(caller, name)` returns `{:ok, %{"server" => url, "protocol" => protocol}}` for host-approved image servers.
- Optional `allow_restricted?(caller, operation, items)` returns `true` to allow the listed restricted config keys/devices.

Direct callers use `Opsmaru.Incus.Operations.run(name, input, host: module, caller: term, scopes: [scope])`; the scopes are the host-verified grants, never tool input. The MCP binding reads the host module from the authorization decision's `assigns` (`:opsmaru_incus_host`), the caller from the `TamaMCP.Context` and the scopes from `context.scopes`. A missing host assign denies before backend access. Order: input schema/bounds, scope, confirmation, binding, authorize, then backend access.

#### Results

Every result is a JSON object. Inspection returns `{"items", "count", "truncated"}` for lists (items keep native order; `count` is the native total) and `{"item"}` for gets. If one item alone exceeds the output bound the call fails with `output_limit` rather than returning partial JSON.

Mutations return `{"status", "operation_id", "operation", "waited_seconds", "error"}` with status `completed` (status code 200), `failed` (native failure or cancellation observed), `running` (accepted, completion not observed within the wait) or `uncertain` (the submission may have been accepted but no response was decoded; never resent). A native rejection before acceptance is a tool error carrying the native status, code and message. Sync mutations (instance PATCH, operation DELETE) report `completed` without an operation.

The bounded wait uses the native `GetOperationWait` (record `b03_native_wait_v1`) rather than polling `Operation.wait`, whose evidence is thinner. Each native request is bounded by the host connection's `timeout`, so the effective server-side wait is `min(requested, floor(connection.timeout / 1000) - 1)` seconds (at least 0), reported as `waited_seconds`. A local deadline during the wait reports `running` with the acceptance snapshot, never cancellation.

Operation tools take a native operation UUID and rebind by ID through `GetOperation`, `GetOperationWait` and `DeleteOperation`. Cancel reads the operation first: a final operation is returned unchanged, `may_cancel: false` reports `cancellation: "unsupported"`, otherwise one `DeleteOperation` is sent and the result reports `cancellation: "requested"` with the prior snapshot; completion stays authoritative.

#### Bounded exec

Exec uses the public `Session.exec/3`, `Session.input/2`, `Session.collect/4` and `Session.signal/2` with host-side sinks. Stdin is sent before collection starts. Each sink keeps the first 64 KiB of its stream and counts the rest; output is returned as UTF-8 text or, if it is not valid UTF-8, base64, with byte counts and a `truncated` flag per stream. Total streamed output is capped at 64 MiB (`exec_output_limit`, failing visibly). When the duration expires, a short-lived process linked to the call sends `SIGKILL` once over the control channel and collection continues for up to 5 s to observe the exit; the result reports `timed_out: true`. If the exit is still not observed, the result reports `running` with the operation identity. Local channel closure never cancels the Incus operation.

#### Evidence

Each descriptor names the native client methods it uses. `Opsmaru.Incus.Operations.Evidence` reads `priv/incus/endpoint-inventory.json` and `priv/incus/coverage.json` at compile time: a method has evidence only when every endpoint row mapping it is `behavior_complete` with a completion record and its Go coverage entry, where one exists, names an implementation and evidence files. `all/0` exports only descriptors whose methods all have evidence; the others appear in `unavailable/0` with the missing methods. Tool tests never update `coverage.json`.

#### Client gaps handled in the tools

- `Opsmaru.Incus.project/2` raises on an invalid selection; tools validate `project` (1–1024 bytes, no control characters) before calling it.
- Image deletion requires a full 64-character fingerprint, and its confirmation must repeat it exactly.

## Risks / Trade-offs

- Tool contract drift between Macus and central -> single descriptors, canonical names and schema snapshots in tests.
- Long mutations exceed an MCP request -> bounded wait plus native operation identity and polling tools; durable tasks later.
- Optional dependency complexity -> compile-time guards and consumer builds with and without `tama_mcp`.
- Catalogue appears complete while client coverage is partial -> per-operation evidence links; unsupported operations not exported.

## Migration Plan

New functionality with no state. Implement on its own feature branch after the client methods it uses have evidence. Macus pins a revision containing it. Opsmaru's later central changes replace their planned `Opsmaru.MCP.Tools.*` catalogue with these descriptors.

## Open Questions

None. The naming question is resolved under "Approved scope (2026-11-04)".
