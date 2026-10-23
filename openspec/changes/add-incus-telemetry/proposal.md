# Proposal

## Why

Macus and central Opsmaru already run `:telemetry`-based metrics, logging and tracing through Phoenix, but `:opsmaru_incus` emits nothing. Hosts cannot see native request latency, deadline and cancellation rates, uncertain mutations, channel lifetimes, overflow or operation wait outcomes without wrapping every call site themselves. Wrapping cannot observe what happens inside the library: killed workers, polls during `Operation.wait/2`, channel closure by owner loss or lifetime expiry, or bytes moved by a stream. Standard `:telemetry` events at those points give hosts that visibility through handlers they already attach, without the library owning any metrics, logging or exporter state.

## What Changes

- Add an internal `Opsmaru.Incus.Telemetry` emitter and a documented, versioned event catalogue under the `[:opsmaru_incus, ...]` prefix covering native requests (buffered calls and streamed transfers), channels (WebSocket, raw, SFTP, dynamic console and event listener) and operation waits.
- Declare `:telemetry` as an `optional: true` dependency. Emission compiles to a no-op when the host does not provide it, so client-only consumers carry no new dependency. Loading or starting the library still creates no process, table, handler or state.
- Emit request spans from the calling process, so host trace and log context applies, and report the final outcome exactly once even when the bounded worker is killed for a deadline, cancellation or owner loss.
- Emit channel closure exactly once from the existing owner watcher using shared `:counters`, so a killed channel process still reports its lifetime, byte counts and closure reason.
- Restrict metadata to bounded enumerations, counts and correlation references. Paths, queries, names, projects, addresses, identities, credentials, operation IDs, native messages and payloads are never emitted.
- Telemetry never changes behavior: no retry, cancellation, deadline extension, replay or result change follows from emission or handler failure.
- Exclude bundled metrics definitions, reporters, Logger output, OpenTelemetry bridges, and gateway or MCP tool events (those changes can reuse this emitter later).

## Capabilities

### New Capabilities

- `incus-telemetry`: optional, passive, redacted `:telemetry` events for native requests, channels and operation waits, with exactly-once outcome reporting.

### Modified Capabilities

None. The main spec inventory is empty; the pending `incus-client` and `embedded-service` requirements stay owned by `add-embedded-incus-foundation`.

## Impact

- New optional dependency `{:telemetry, "~> 1.3", optional: true}`. Macus and central Opsmaru already lock a compatible version through Phoenix; client-only consumers compile without it.
- Touches `Transport`, `Transfer`, `Incus.raw_query/5`, `Operation.wait/2`, `WebSocket`, `RawChannel`, `SFTP`, `DynamicConsole` and `EventListener`. Public client APIs, return values, errors and wire behavior are unchanged.
- `priv/incus/coverage.json` and foundation task 3.9 are unaffected: telemetry is not client parity evidence, and an emitted event never counts as typed-client or differential evidence.
- Hosts own every handler. Handlers run synchronously in the emitting process; slow handlers delay that process but cannot extend a deadline or keep a socket or worker alive past its guard.
