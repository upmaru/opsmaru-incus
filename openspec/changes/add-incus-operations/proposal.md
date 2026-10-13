# Proposal

## Why

Agents operate Incus through MCP both at a standalone Macus (`/mcp` on its gateway) and, later, through central Opsmaru. The tool contract (names, input/output schemas, scopes, confirmation rules and how each tool calls the client) must be identical in both places. Defining the Incus operations once in `:opsmaru_incus`, beside the client they wrap, gives Macus a ready catalogue for its first standalone milestone and lets central Opsmaru reuse the same definitions later without depending on Macus or Macus depending on central.

## What Changes

- Add protocol-neutral Incus operation descriptors under `Opsmaru.Incus.Operations`: canonical name, description, input/output JSON schemas, required scope, destructive-confirmation rule, bounds and a run function that executes through the existing `Opsmaru.Incus` client.
- Add a host contract: the host supplies the trusted connection and context for an authenticated caller and authorizes the operation. Operations never accept URLs, sockets, credentials or owner identity from tool input.
- Add an optional TamaMCP binding (`Opsmaru.Incus.MCP.Tools.*`) that exposes each descriptor as a `TamaMCP.Tool` module for the host's own `TamaMCP.Server`. `tama_mcp` is an optional dependency; client-only consumers compile without it.
- Initial catalogue: inspection (server, instances, images, projects, profiles, networks, storage, operations); instance create/update/state; snapshot create/restore; image and instance/snapshot deletion with explicit confirmation; bounded guest exec; operation status/wait/cancel.
- Tools execute synchronously. Mutations return the native Incus operation identity and whether completion was observed within the tool's bounded wait; callers poll the operation tools for later state. No durable MCP task store, runner or journal is introduced, and no task handles are advertised.
- No target selection or registry concepts. Schemas carry no `target_id`; a later central host can add target resolution around the same descriptors.

## Capabilities

### New Capabilities

- `incus-operations`: shared Incus operation descriptors, host binding, scope and confirmation enforcement, bounded synchronous execution and the optional TamaMCP binding.

### Modified Capabilities

None.

## Impact

- Macus `add-elixir-server` composes these tools with its Macus-owned runtime tools at one `/mcp`, supplying its bearer-verified caller, local connection/context and authorization. Central Opsmaru adopts the same descriptors in its later changes; its tool catalogue planning moves here.
- Operations use only client calls with recorded verification evidence. Operations needing client areas still open in foundation task 3.9 (for example migration/copy) are excluded until that evidence exists; tool success never closes client coverage.
- Durable tasks, target registration and connectors are later work. This change creates no persistence and starts no processes.
- Fixture, consumer, real-Incus and Macus hardware evidence remain separate gates.
