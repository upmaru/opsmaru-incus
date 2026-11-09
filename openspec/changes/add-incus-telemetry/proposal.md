# Proposal

## Why

Macus and central Opsmaru already run `:telemetry`-based metrics, logging and tracing through Phoenix (the isolated host consumer in `test/consumer` locks `telemetry`, `telemetry_metrics` and `telemetry_poller`), but `:opsmaru_incus` emits nothing. Hosts cannot see native request latency, deadline and cancellation rates, uncertain mutations, channel lifetimes, overflow or operation wait outcomes without wrapping every call site themselves. Wrapping cannot observe what happens inside the library: killed workers, polls during `Operation.wait/2`, channel closure by owner loss or lifetime expiry, or bytes moved by a stream. Standard `:telemetry` events at those points give hosts that visibility through handlers they already attach, without the library owning any metrics, logging or exporter state.

## What Changes

- Add an internal `Opsmaru.Incus.Telemetry` emitter and a documented, versioned event catalogue under the `[:opsmaru_incus, ...]` prefix covering native Incus requests (buffered calls and streamed transfers), channels (WebSocket, raw SFTP/NBD, SFTP sessions, dynamic consoles and event listeners), event listener callbacks and operation waits.
- Declare `:telemetry` as an `optional: true` dependency, following the existing optional Plug/Cowboy pattern. Emission compiles to a no-op when the host does not provide it, so client-only consumers carry no new dependency. Loading or starting the library still creates no process, table, handler or state.
- Emit request spans from the calling process at the native request entry points (`Incus.raw_query/5`, `HTTP.request/4` on an Incus client and `Transfer`), not inside `Transport.bounded/4`, which now also bounds composite work such as exec collection and SimpleStreams downloads. Report the final outcome exactly once, as the caller receives it, even when the bounded worker is killed for a deadline, cancellation or owner loss.
- Emit channel closure exactly once from the existing `Transport.watch_owner/2` watcher using shared `:counters`, so a killed channel process still reports its lifetime, byte counts and closure reason.
- Restrict metadata to bounded enumerations, counts and correlation references. Paths, queries, names, projects, addresses, identities, credentials, operation IDs, native messages and payloads are never emitted.
- Telemetry never changes behavior: no retry, cancellation, deadline extension, replay or result change follows from emission or handler failure.
- Exclude bundled metrics definitions, reporters, Logger output and OpenTelemetry bridges.

### Scope of surfaces added since the original plan

- **Operations layer and MCP tool execution: covered through the client, no new events.** Shared operations call `Incus.call/4` and `Session`, so their native requests and exec channels emit ordinary request and channel events with the Go declaration name. Tool-level events (descriptor, confirmation, result shape) are out: tool exposure is host-owned and hosts already observe tool calls at their MCP boundary.
- **Native gateway relays (HTTP, WebSocket, raw upgrade, cross-server migration, revocation and lifecycle loops): out.** Relays drive Mint directly and are mounted in the host's own Plug/Cowboy pipeline, whose telemetry already sees each exchange; relay-internal events touch grant and identity handling and need their own catalogue and redaction review. None of this change's events fire for relayed traffic, so nothing is counted twice. A later change can reuse the emitter.
- **Client-side `Migration` negotiation and relay: covered through the client.** Its native requests and the WebSocket channels it forwards emit ordinary events; there is no migration-specific event.
- **Async SimpleStreams (catalogue refresh, origin downloads, cache and delta adapters): out.** Its traffic targets a host-approved image origin, not the Incus backend, and its adapters run host code; it would need an origin target dimension. The native requests that copy a SimpleStreams image into Incus are covered.
- **SFTP: in,** as one `:sftp` channel per session over its inner raw channel. **OCI: out,** for the same reasons as SimpleStreams: registry traffic and conversion run through the host adapter and origin HTTP handle.

## Capabilities

### New Capabilities

- `incus-telemetry`: optional, passive, redacted `:telemetry` events for native Incus requests, channels, event listener callbacks and operation waits, with exactly-once outcome reporting.

### Modified Capabilities

None. `embedded-service` (passive library loading), `incus-client` and `incus-operations` keep their requirements; this change adds observation only and relies on, rather than changes, passive loading and native error classification. The pending `incus-gateway` capability (change `add-embeddable-incus-gateway`) is not modified.

## Impact

- New optional dependency `{:telemetry, "~> 1.3", optional: true}`. `mix.lock` already resolves `telemetry` 1.4.2 through the optional Plug dependency; Macus and central Opsmaru lock a compatible version through Phoenix. The client-only consumer (`test/consumer/client_only`, no Plug, Cowboy or Phoenix) compiles without it.
- Touches `Transport` (internal byte counters and watcher telemetry state), `Incus.raw_query/5`, `API.call/4`, `HTTP`, `Transfer`, `Operation.wait/2`, `WebSocket`, `RawChannel`, `SFTP`, `DynamicConsole` and `EventListener`. Public client APIs, accepted options, return values, errors and wire behavior are unchanged.
- `priv/incus/coverage.json` is unaffected: telemetry is not client parity evidence, and an emitted event never counts as typed-client, completion-record or differential evidence. `complete_port` stays false.
- Hosts own every handler. Handlers run synchronously in the emitting process; slow handlers delay that process but cannot extend a deadline or keep a socket or worker alive past its guard.
- Siblings: if `add-incus-connection-pool` lands, request metadata can gain its proposed closed `connection` field; if `add-event-driven-cancellation` lands, the watcher that emits channel closure becomes event-driven. This change depends on neither and modifies neither.
