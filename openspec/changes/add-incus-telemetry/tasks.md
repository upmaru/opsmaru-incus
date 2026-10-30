# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Telemetry evidence never closes foundation task 3.9 or any `priv/incus/coverage.json` entry.

## 1. Passive optional emitter

- [ ] 1.1 Add `{:telemetry, "~> 1.3", optional: true}` and `Opsmaru.Incus.Telemetry` with compile-time no-op selection; verify client-only compilation without `:telemetry`, that loading and starting `:opsmaru_incus` creates no process, ETS table, handler or state in both builds, and that a loaded but unstarted `:telemetry` never raises into a call.
- [ ] 1.2 Document the event catalogue, measurement units, closed metadata value sets, emitting process per event and the handler cost contract in the `Opsmaru.Incus.Telemetry` moduledoc; verify with a test that every documented event name is emitted somewhere and no undocumented `[:opsmaru_incus | _]` event is.

## 2. Request spans

- [ ] 2.1 Emit `request.start`/`request.stop` from the caller in `Transport.bounded/4` with `:counters`-backed byte counts; verify exactly one stop per start for success, native error, connection failure, deadline-killed worker, cancelled context and late worker reply, and that each `outcome` equals the returned error kind.
- [ ] 2.2 Thread `native_method` and `shape` through `Incus.call/4`, `raw_query/5` and `Transfer`; verify typed calls report their Go declaration name, raw queries report `nil`, downloads and uploads report streamed byte totals including partial totals at a deadline, and no option reaches the wire.
- [ ] 2.3 Verify a POST whose response is lost reports `outcome: :uncertain` with a single request on the wire, and that a raising or slow handler changes no return value, retry count or deadline classification.

## 3. Channel events

- [ ] 3.1 Emit `channel.open` spans for WebSocket, raw, SFTP, console and event-listener upgrades; verify failed upgrades emit an open stop with the returned outcome and no close event.
- [ ] 3.2 Pass `:counters` and span context to the `Transport.watch_owner/2` watcher and emit `channel.close` there; verify exactly one close for normal close, remote close, overflow, lifetime expiry, request-context cancellation, owner death and a `:kill` of the channel process, each with the documented `reason` and byte/message counts.
- [ ] 3.3 Suppress inner channel events for `SFTP` and `DynamicConsole`; verify one open/close pair per host-visible channel.
- [ ] 3.4 Emit `event_listener.callback` from the listener; verify success, raise and timeout outcomes and that no event type or payload appears in metadata.

## 4. Operation waits

- [ ] 4.1 Emit `operation.wait` spans from `Operation.wait/2` and `wait_with_context/3`; verify `polls`, `native_status` and `outcome` for success, native failure, deadline, cancellation and poll error, and that no backend `DELETE` or extra mutation is sent.

## 5. Redaction and consumer verification

- [ ] 5.1 Add a fixture test that attaches to every event across the database-free suite and fails if any metadata value contains a fixture path, query, resource or project name, socket path, origin, identity, operation ID, ETag, header, native message or body byte.
- [ ] 5.2 Extend the isolated consumer check to attach a handler in a Macus-compatible host and to build a second consumer without `:telemetry`; verify both from a pushed immutable revision with `mise run check:consumer`.
- [ ] 5.3 Run `mise run check` and `mise run check:reference`; record that this change adds no real-Incus or Macus hardware evidence.
