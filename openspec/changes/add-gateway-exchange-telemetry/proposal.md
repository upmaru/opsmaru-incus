# Proposal

## Why

A host that mounts the gateway cannot see what it relays. The gateway emits no events and writes no log, and the host's own Plug telemetry covers only part of the traffic:

- **Raw SFTP/NBD upgrades never reach it.** `Opsmaru.Incus.Gateway.CowboyHandler` serves them before the host's Plug pipeline runs.
- **WebSockets look finished at the upgrade.** The exchange really ends inside `WebSocketRelay`, which alone knows the bytes moved and why it ended (revocation, idle, lifetime, backend loss).
- **Gateway decisions are invisible.** Plug telemetry has no admission result, no native project or target selection and no `Failure` outcome (`:not_sent`, `:uncertain`, `:sent`).

Macus wants an access log of every native request made through its gateway (Macus change `add-gateway-access-log`). Central Opsmaru will need the same for its connectors. Wrapping the Plug cannot produce it, for the reasons above, so the events must come from the gateway.

The planned `add-incus-telemetry` change (draft, branch `feature/add-incus-telemetry`) covers client requests and channels and leaves gateway relays out, noting that they "need their own catalogue and redaction review" and that "a later change can reuse the emitter". This is that change.

## What Changes

- **One start/stop pair per gateway exchange.** `[:opsmaru_incus, :gateway, :exchange, :start]` and `[:opsmaru_incus, :gateway, :exchange, :stop]` are emitted for every request that reaches a gateway adapter: native HTTP, locally served discovery and trust, WebSocket and raw upgrades, and requests the gateway refuses before admission.
- **The stop is reported exactly once, at the real end.** A per-exchange observer monitors the process that owns the exchange, so a relay killed for revocation, a deadline or a lost caller still reports its duration, bytes and reason.
- **Metadata is a fixed, secret-free map built by the gateway.** It carries the protocol, method, canonical path, native project/target selection, operation ID, peer address, the SHA-256 fingerprint of any peer certificate, how the request was admitted, the HTTP status, the outcome and a closed reason. It never carries the `authorization` header, the raw query, image or operation secrets, other headers, bodies, the host's grant or `host_config`.
- **`:telemetry` is optional.** It is declared `optional: true` and emission compiles to a no-op without it, as `add-incus-telemetry` plans for the client. No observer is started when `:telemetry` is absent or no handler is attached.
- **Emission never changes behaviour.** No admission decision, relay, deadline, retry or response depends on an event or a handler.
- The library still writes no log, defines no metrics and attaches no handler. Hosts own all of that.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `incus-gateway`: adds exchange telemetry, its metadata bounds and its passivity.

## Impact

- **Dependency:** `{:telemetry, "~> 1.3", optional: true}`. `mix.lock` already resolves it through the optional Plug dependency, so every host that compiles `Gateway.Plug` has it. The client-only consumer still compiles without it.
- **Code:** a shared `Opsmaru.Incus.Telemetry` emitter (created here if `add-incus-telemetry` has not landed), a new internal `Opsmaru.Incus.Gateway.Exchange` observer, and emission points in `Gateway.Plug`, `Gateway.CowboyHandler`, `HTTPRelay`, `Local`, `WebSocketRelay` and `RawRelay`. `Failure` gains an internal closed `reason`. `Gateway.new!/1`, the `Host` behaviour, the `Request` struct, wire behaviour and error bodies are unchanged.
- **Sibling plan:** `add-incus-telemetry` states that no `[:opsmaru_incus | _]` event is emitted for a relayed exchange. That scenario must be narrowed to its own request and channel events when that change is refreshed. The two catalogues do not overlap: relays drive Mint directly and never pass through the client entry points.
- **Redaction posture:** these events carry the request path, project and peer address, which `add-incus-telemetry` excludes from client events. The difference is deliberate and argued in [design.md](design.md); it needs explicit review.
- **Documentation:** `docs/gateway.md` gains the event catalogue; `CHANGELOG.md` records the release.
- **Evidence:** fixture and isolated-consumer checks only. This change adds no real-Incus, gateway acceptance or Macus hardware evidence, and no `priv/incus/coverage.json` entry changes.
