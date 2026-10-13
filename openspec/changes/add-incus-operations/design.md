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

A host implements `Opsmaru.Incus.Operations.Host` callbacks that, for an authenticated caller from the protocol context, return the trusted `Opsmaru.Incus.Connection` and `Opsmaru.Context` to use, and authorize the operation and input. The host decides which project(s) a caller may use; operations pass native project selection from input only after host authorization. Input fields can never select a socket, URL, credential, owner or host path. Missing or failing host callbacks deny before any backend access.

Scopes follow the planned Macus/Opsmaru split: `incus.read` for inspection, `incus.write` for instance/state/image/snapshot mutation, `incus.exec` for guest exec, `incus.delete` for deletion and destructive restore. Destructive operations additionally require an explicit confirmation input that names the affected resource; inferred consent is never accepted.

### 3. Synchronous execution without durable tasks

Tools execute within the request. Inspection returns native data. Mutations submit the native request and then wait up to a bounded, caller-limited deadline for the native operation. The result reports the native operation identity and one of: completed (with final status), still running, or failed. A response lost after possible acceptance is reported as uncertain with any known operation identity; mutations are never retried automatically. Operation tools (`incus_operation_get`, `incus_operation_wait`, `incus_operation_cancel`) let callers poll or request supported cancellation; a local timeout is never reported as remote cancellation.

Durable MCP tasks are deferred. Because results already carry native operation identity, a later durable layer can wrap the same descriptors without changing their schemas.

### 4. Bounds and catalogue

Each descriptor declares input size, output size, list length and deadline bounds; results that exceed them are truncated with an explicit indicator or fail visibly. Guest exec runs only in an explicitly named instance, with bounded argv, environment, stdin, captured output and duration, and no interactive terminal. Events, console attachment, file and image binary transfer are excluded from the initial catalogue because they need streaming beyond a bounded MCP result.

Initial operations: server info; list/get instances, images, projects, profiles, networks, storage pools and volumes, and operations; instance create, update and state change; snapshot create and restore; instance, snapshot and image deletion; bounded exec; operation get, wait and cancel. Each operation records the client methods it uses and their coverage evidence. An operation whose client methods lack evidence is not exported.

### 5. Verification

Fixture tests use the existing fake Unix/HTTPS Incus endpoints: schemas, scope and confirmation denial with zero backend requests, forged connection fields, bounds and truncation, accepted/completed/uncertain mutation results and exec limits. The TamaMCP binding is tested with TamaMCP's conformance helpers and a fixture host server. The isolated consumer fixture compiles the library with and without `tama_mcp`. Real-Incus checks reuse the explicit opt-in acceptance environment. Macus composition and hardware acceptance are Macus's.

## Risks / Trade-offs

- Tool contract drift between Macus and central -> single descriptors, canonical names and schema snapshots in tests.
- Long mutations exceed an MCP request -> bounded wait plus native operation identity and polling tools; durable tasks later.
- Optional dependency complexity -> compile-time guards and consumer builds with and without `tama_mcp`.
- Catalogue appears complete while client coverage is partial -> per-operation evidence links; unsupported operations not exported.

## Migration Plan

New functionality with no state. Implement on its own feature branch after the client methods it uses have evidence. Macus pins a revision containing it. Opsmaru's later central changes replace their planned `Opsmaru.MCP.Tools.*` catalogue with these descriptors.

## Open Questions

- Canonical tool name prefix and exact naming scheme; resolve before the first consumer pin, since names become part of the public contract.
