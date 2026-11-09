# Proposal

## Why

Macus needs a native Incus gateway mounted in its existing Elixir server without another endpoint or a controller for every backend method. Placing reusable gateway mechanics in the `:opsmaru_incus` library, beside the client transport they build on, plus an independent acceptance harness here, lets us verify portable behavior on Linux and macOS before Macus installation or hardware integration. This change was proposed in `upmaru/opsmaru` and moved here on 2026-10-13, when `:opsmaru` became the central service only and Macus stopped depending on it. It was refreshed on 2026-11-05 after `add-embedded-incus-foundation` and `add-incus-operations` were archived.

## What Changes

- Add an optional `Opsmaru.Incus.Gateway` library component with a mountable Plug for native HTTP/streaming and WebSockets plus a Cowboy protocol-switch companion for raw SFTP/NBD upgrades on the host's existing listener.
- Keep reusable modules under `lib/opsmaru/incus/gateway/`. Plug and Cowboy are optional dependencies of `:opsmaru_incus`; gateway modules compile only when the host provides them, so client-only consumers carry no web stack. Loading or configuring the library starts no endpoint, listener, credentials, runtime state or backend connection.
- Define an explicit host policy/configuration contract for verified callers, readiness, fixed backend connections, gateway identity/trust mediation, revocation and bounded resources. Macus retains its endpoint, policy, trust state, private sockets, Swift bridge, VM and packaging ownership.
- Preserve canonical `/`, `/1.0` and `/1.0/*` routes, native bytes/queries/headers/errors/ETags and operation identities, with authorization before backend access across every protocol. Never replay potentially accepted mutations or substitute WebSocket framing for raw upgrades.
- Support cross-server `incus copy`/`incus move` through the gateway at pinned Go client parity in all three transfer modes (relay, pull and push): the gateway advertises its host-approved public address and certificate instead of the guest's, and admits operation-secret WebSockets from another Incus server only through an explicit host policy decision (user decision 2026-11-05).
- Add database-free protocol fixtures, an isolated immutable consumer and unmodified pinned Incus CLI/client conformance tests. Run gateway tests against explicitly opted-in isolated real Incus in this repository, recording each evidence class separately from installed Macus/hardware acceptance.
- Deliver in independently reviewable slices on their own feature branches (see tasks.md), each mergeable into develop without claiming later slices.
- Exclude central REST/MCP, OIDC/OAuth, registry/connectors, application task persistence, scheduling, provisioning, installers and modifications to Macus source. The shared Incus operations stay protocol-neutral; exposing them at `/mcp` remains host-owned.

## Capabilities

### New Capabilities

- `incus-gateway`: passive host mounting, policy-bound native relay, protocol upgrades, cross-server migration negotiation and independent conformance/real-backend acceptance.

### Modified Capabilities

None. `embedded-service`, `incus-client` and `incus-operations` keep their requirements; the gateway's optional dependencies preserve the client-only build those specs require.

## Impact

- The consumer-locked baseline (Macus) is Phoenix 1.8.15, Plug 1.20.3, Plug.Cowboy 2.9.0, Cowboy 2.19.0, Cowlib 2.21.0, Ranch 2.3.0, Mint 1.11.0 and MintWebSocket 1.0.5. This library declares ranges; `plug` is currently test-only and `cowboy` is absent. Plug.Cowboy supports WebSocket upgrades only; full raw upgrade handling requires Cowboy integration, not a `forward` line alone.
- Macus's router has an empty JSON API scope; `Macus.Proxy` and `Macus.Auth` are boundary stubs. Its fixture-only Cowboy takeover (its task 1.5) proves coalesced-byte/half-close mechanics, not a production gateway. Reusable fixture transfer needs provenance/notices; no Macus source moves in this change. Macus tasks 5.1–5.7 and 6.11 consume these mechanics.
- The typed client is complete for its foundation scope (task 3.9 closed against the endpoint inventory; task 4.3 passed on real Incus). Reuse its transport, TLS trust and framing primitives where suitable, but its typed calls and buffered HTTP facade are not a transparent incoming streaming proxy.
- Gateway evidence never changes `priv/incus/coverage.json` or the endpoint inventory: a proxied request succeeding is not typed-client evidence.
- This explicitly refines previous proxy ownership: portable relay mechanics are shared, while the public endpoint, trusted host policy and Apple-specific bridge remain Macus-owned. Macus adoption and reconciliation of its plans are separate consumer work.
- Do not merge, tag, archive or activate services without explicit authorization.
