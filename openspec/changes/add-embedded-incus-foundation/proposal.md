# Proposal

## Why

Macus and central Opsmaru both need the same portable native Incus client. It was first built inside the `:opsmaru` Phoenix application and made safe to embed, but embedding that application still brought Phoenix, Ecto, Postgrex, LiveView and asset dependencies into Macus. The client had a clean boundary (only Mint, MintWebSocket, Jason, cowlib, yamerl and OTP `:ssl`), its own milestone, its own gates and its own real-Incus acceptance. This change therefore delivers it as a standalone pure library, `:opsmaru_incus`, in the `upmaru/opsmaru-incus` repository, where the remaining coverage work (task 3.9) continues.

## What Changes

- Deliver the client as a pure OTP library `:opsmaru_incus` with no application callback. Loading or starting it creates no process, listener, Endpoint, Repo, state, credentials or backend contact, independent of PHX_SERVER/PORT or any deployment mode. Expose the client and its host binding/supervision helpers under `Opsmaru.Incus.*`.
- Move the host context and optional client supervisor to `Opsmaru.Incus.Context` and `Opsmaru.Incus.ClientSupervisor`. This approved namespace cleanup supersedes the extraction's name-preservation decision; consumers update aliases, struct references and child specifications when adopting the new revision. Behavior, ownership and passive startup remain unchanged; no legacy compatibility modules are supplied.
- Define explicit host-supplied connection/context contracts and the public `Opsmaru.Incus` client over Unix sockets and authenticated native HTTPS with verified server identity and client certificate/private key.
- Keep the pinned official Incus client inventory, notices and reusable reference fixtures in this repository, preserving Macus-specific transport evidence separately in Macus.
- Implement the canonical client in verified slices: discovery/codecs/errors/extensions, projects/profiles/access, instances/snapshots/state, images, networks/clusters, storage, files/backups/native upgrades, operations/events, exec/console and migration.
- Preserve native operation identity, streaming/backpressure, deadlines and uncertainty without automatic mutation replay. Missing methods/extensions remain explicit; a subset is not advertised as complete parity.
- Complete task 3.9 against a verified Incus REST endpoint/method inventory, native streaming/upgrade contracts and the public client behavior required by `add-incus-operations`. Retain all 1,280 Go declarations as a separate provenance/gap ledger; task completion does not establish literal Go declaration parity or authorize a complete-port claim.
- Begin the checked endpoint evidence inventory with 21 consumer-priority pairs, linking pinned REST provenance, public methods, existing tests and explicit behavior gaps. This selected slice leaves task 3.9 and declaration parity incomplete.
- Extend the native operation-wait evidence for both direct typed wait methods over disposable Unix and verified HTTPS fixtures: gated response bodies, running/terminal snapshots, native errors and local lifetime cleanup. Keep polling behavior unchanged and remaining secret/cluster/backend gaps explicit.
- Add the approved bounded typed conditional instance PATCH endpoint, preserving omitted/false/empty InstancePut fields, caller If-Match and synchronous success. Keep generic Go RawQuery transport comparison distinct from endpoint-specific fixture evidence and real-daemon merge acceptance.
- Verify the ten initial-tool list/get inspection contracts for projects, profiles, networks, storage pools and volumes across Unix and mutual HTTPS; record finite fixture-verified scopes separately from partial endpoint/declaration status, including typed results, errors, bounds, routing and local lifetime cleanup.
- Finish the full pinned REST endpoint inventory classification as an audit-only slice: retain every documented operation/query view, reconcile server registrations and custom-volume mappings, attach existing client/evidence links and assign every unresolved contract to a finite backlog. Classification does not certify behavior, approve exclusions or change runtime/tool exports.
- Add the approved four conditional typed PATCH methods for project, profile, image and instance snapshot. Preserve caller ETags and field presence; retain empty synchronous success for the first three and native asynchronous snapshot acceptance. Record these as bounded REST slices, independently of named Go declaration parity and daemon merge acceptance.
- Keep OCI in scope through an explicitly supplied host adapter: hosts own registry credentials, external conversion tools and temporary state; the portable library verifies native image projections and bounds adapter calls and binary handoff.
- Keep SimpleStreams in scope over an explicitly supplied verified HTTPS origin, without automatic socket discovery or HTTP downgrade. Optional delta conversion uses a bounded host adapter that owns tools, credentials and temporary state; retain the unchanged Incus v7.0.1 reference and document these security/ownership differences.
- Run database-free fixture checks with an ordinary `mix test`, plus an external Macus-compatible consumer fixture that imports a pinned revision of this repository without a sibling checkout. Installed Macus runtime packaging remains Macus-owned.
- Repair macOS cleanup fixtures by separating bounded resource observations from direct shared-budget verification, with controlled delayed-observer evidence and unchanged runtime budgets. Verify Unix/TLS WebSocket write timeouts against the actual remaining stream deadline rather than a test-observer elapsed threshold.
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
- The optional native relay is planned separately in this repository's [add-embeddable-incus-gateway](../add-embeddable-incus-gateway/proposal.md); proxy success never completes missing typed-client coverage here.
- Keep main/develop as the integration/release boundaries and publish development on feature branches. Real-backend and Macus hardware acceptance remain separate explicit gates.
