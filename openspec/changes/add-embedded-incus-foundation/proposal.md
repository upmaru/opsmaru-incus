# Proposal

## Why

Macus and central Opsmaru both need the same portable native Incus client. It was first built inside the `:opsmaru` Phoenix application and made safe to embed, but embedding that application still brought Phoenix, Ecto, Postgrex, LiveView and asset dependencies into Macus. The client had a clean boundary (only Mint, MintWebSocket, Jason, cowlib, yamerl and OTP `:ssl`), its own milestone, its own gates and its own real-Incus acceptance. This change therefore delivers it as a standalone pure library, `:opsmaru_incus`, in the `upmaru/opsmaru-incus` repository, where the remaining coverage work (task 3.9) continues.

## What Changes

- Deliver the client as a pure OTP library `:opsmaru_incus` with no application callback. Loading or starting it creates no process, listener, Endpoint, Repo, state, credentials or backend contact, independent of PHX_SERVER/PORT or any deployment mode. Module names (`Opsmaru.Incus.*`, `Opsmaru.Context`, `Opsmaru.ClientSupervisor`) are unchanged, so consumer call sites do not change.
- Define explicit host-supplied connection/context contracts and the public `Opsmaru.Incus` client over Unix sockets and authenticated native HTTPS with verified server identity and client certificate/private key.
- Keep the pinned official Incus client inventory, notices and reusable reference fixtures in this repository, preserving Macus-specific transport evidence separately in Macus.
- Implement the canonical client in verified slices: discovery/codecs/errors/extensions, projects/profiles/access, instances/snapshots/state, images, networks/clusters, storage, files/backups/native upgrades, operations/events, exec/console and migration.
- Preserve native operation identity, streaming/backpressure, deadlines and uncertainty without automatic mutation replay. Missing methods/extensions remain explicit; a subset is not advertised as complete parity.
- Complete task 3.9 against a verified Incus REST endpoint/method inventory, native streaming/upgrade contracts and the public client behavior required by `add-incus-operations`. Retain all 1,280 Go declarations as a separate provenance/gap ledger; task completion does not establish literal Go declaration parity or authorize a complete-port claim.
- Keep OCI in scope through an explicitly supplied host adapter: hosts own registry credentials, external conversion tools and temporary state; the portable library verifies native image projections and bounds adapter calls and binary handoff.
- Keep SimpleStreams in scope over an explicitly supplied verified HTTPS origin, without automatic socket discovery or HTTP downgrade. Optional delta conversion uses a bounded host adapter that owns tools, credentials and temporary state; retain the unchanged Incus v7.0.1 reference and document these security/ownership differences.
- Run database-free fixture checks with an ordinary `mix test`, plus an external Macus-compatible consumer fixture that imports a pinned revision of this repository without a sibling checkout. Installed Macus runtime packaging remains Macus-owned.
- Keep MCP tools, durable tasks, central registry/SQL/OIDC and connectors in `upmaru/opsmaru`, and Swift/VZ, the public gateway and packaging in `upmaru/macus`. This change neither starts nor validates those services.

## Capabilities

### New Capabilities

- `embedded-service`: passive library loading, explicit host context/readiness and independent runtime ownership.
- `incus-client`: portable native API/streaming contracts, coverage provenance and consumer verification.

### Modified Capabilities

None. This repository's main spec inventory is empty.

## Impact

- Tasks 1.1–4.3 (except 3.9) were completed and verified in `upmaru/opsmaru` on `feature/phoenix-bootstrap-and-remote-access` up to `a00805d`. That code, its tests and this change were extracted with history on 2026-10-13; `test/library/` became `test/`. The earlier evidence remains valid and is recorded in `docs/foundation-validation.md`.
- Task 3.9 (migration/copy and remaining reference entries) continues on this repository's feature branches against `priv/incus/coverage.json`.
- Consumers pin immutable revisions of this repository. Opsmaru removes its in-app copy and depends on `:opsmaru_incus` when its later changes need the client; Macus `add-elixir-server` depends on `:opsmaru_incus` instead of `:opsmaru`. Those adoptions are tracked in the consumer repositories.
- The optional native relay proposed in Opsmaru's [add-embeddable-incus-gateway](https://github.com/upmaru/opsmaru/blob/feature/phoenix-bootstrap-and-remote-access/openspec/changes/add-embeddable-incus-gateway/proposal.md) remains planned there; proxy success never completes missing typed-client coverage here.
- Keep main/develop as the integration/release boundaries and publish development on feature branches. Real-backend and Macus hardware acceptance remain separate explicit gates.
