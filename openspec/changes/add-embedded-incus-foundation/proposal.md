# Proposal

## Why

Macus needs a real embeddable Opsmaru dependency and portable Incus client before central-service work. This independently implementable change establishes the library boundary and client behavior without waiting for MCP tools, task persistence, OIDC, registration or outbound connectors.

## What Changes

- Retain the existing single Phoenix application `:opsmaru` and make its library startup/configuration safe for Macus embedding, with no Opsmaru endpoint, repository, listener or runtime state creation by default.
- Define explicit host-supplied connection/context contracts and the public `Opsmaru.Incus` client over Unix sockets and authenticated native HTTPS with verified server identity and client certificate/private key.
- Transfer pinned official Incus client inventory, notices and reusable reference fixtures into Opsmaru, preserving Macus-specific transport evidence separately.
- Implement the canonical client in verified slices: discovery/codecs/errors/extensions, projects/profiles/access, instances/snapshots/state, images, networks/clusters, storage, files/backups/native upgrades, operations/events, exec/console and migration.
- Preserve native operation identity, streaming/backpressure, deadlines and uncertainty without automatic mutation replay. Missing methods/extensions remain explicit; a subset is not advertised as complete parity.
- Add a database-free library test profile and an external Macus-compatible consumer fixture that imports a pinned dependency without a sibling checkout or extra Opsmaru process. Source fixtures use the pinned Elixir toolchain; installed Macus runtime packaging remains Macus-owned.
- Keep central Phoenix/SQL/OIDC/MCP/task/registry/connector behavior in later changes. This stage neither starts nor validates those services and does not implement macus connect.

## Capabilities

### New Capabilities

- `embedded-service`: passive embedded startup, host configuration, readiness and independent runtime ownership.
- `incus-client`: portable native API/streaming contracts, coverage provenance and consumer verification.

### Modified Capabilities

None in the empty main inventory. These two capabilities and their client/setup implementation tasks are extracted from pending add-compute-substrate; that later change consumes this foundation rather than reimplementing it.

## Impact

- The scaffold already starts only telemetry when embedded; no portable client exists yet. Its generated test alias and test configuration currently expect PostgreSQL/standalone mode, so a separate no-database library check is needed.
- Macus add-elixir-server may pin the implemented foundation revision and proceed with local gateway/runtime/native proxy and typed-client integration independently of central features. Shared MCP tools/local task runners are a later compute-substrate milestone, not a gate on library/client acceptance.
- Implementation adds connection/client modules, fixtures, API/coverage docs and isolated consumer checks in Opsmaru. Swift/VZ and Macus sockets/proxy/launchd remain Macus-owned. Do not migrate another chat's active source or claim hardware acceptance from fixtures.
- Keep main/develop as the integration/release boundaries and publish development on feature branches. This request creates a complete proposal only; implementation and real-backend acceptance remain subsequent actions.
