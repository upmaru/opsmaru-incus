# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Telemetry evidence is never typed-client, completion-record or differential evidence and changes no `priv/incus/coverage.json` entry; `complete_port` stays false.

## 1. Passive optional emitter

- [ ] 1.1 Add `{:telemetry, "~> 1.3", optional: true}` and `Opsmaru.Incus.Telemetry` with compile-time no-op selection; verify client-only compilation without `:telemetry`, that loading and starting `:opsmaru_incus` creates no process, ETS table, handler or state in both builds, and that a loaded but unstarted `:telemetry` never raises into a call.
- [ ] 1.2 Document the event catalogue, measurement units, closed metadata value sets, emitting process per event, the uncovered surfaces (gateway relays, MCP tool calls, SimpleStreams and OCI origins) and the handler cost contract in the `Opsmaru.Incus.Telemetry` moduledoc; verify with a test that every documented event name is emitted somewhere and no undocumented `[:opsmaru_incus | _]` event is.

## 2. Request spans

- [ ] 2.1 Emit `request.start`/`request.stop` from the caller at `Incus.raw_query/5`, `HTTP.request/4` on an Incus handle and the `Transfer` runner, with `:counters`-backed byte counts threaded through `Transport.request/5` and `Transport.bounded/4` as an internal argument; verify exactly one stop per start for success, native error, envelope decode failure, connection failure, deadline-killed worker, cancelled context (including rejection before a worker is spawned) and late worker reply, and that each `outcome` equals the error kind the entry point returns (typed model decoding above `raw_query/5` stays outside the span).
- [ ] 2.2 Verify that `Transport.bounded/4` itself emits nothing, so `ExecRun`, `ExecOutput.collect/5`, `SimpleStreams.refresh/1` and `SimpleStreams.Download.run/4` produce only the request and channel events of the native work they contain, and that SimpleStreams and OCI origin requests and transfers emit nothing.
- [ ] 2.3 Thread `native_method` from `API.call/4`, `Operation.poll/1` and `Operation.cancel/1` through an internal entry beside `raw_query/5`, and `shape` through `Transfer`; verify reference calls report their Go declaration name, raw queries and DoHTTP report `nil`, the public `raw_query` option allowlist still rejects any other option, downloads and uploads report streamed byte totals including partial totals at a deadline, and nothing new reaches the wire.
- [ ] 2.4 Verify a POST whose response is lost reports `outcome: :uncertain` with a single request on the wire, and that a raising or slow handler changes no return value, retry count or deadline classification.
- [ ] 2.5 Verify an operations-layer tool call (`Operations` inspection, mutation and exec) emits only ordinary request and channel events with declaration names, and no tool-level event.

## 3. Channel events

- [ ] 3.1 Emit `channel.open` spans for WebSocket, raw SFTP/NBD, SFTP session, dynamic console and event-listener upgrades; verify failed upgrades emit an open stop with the returned outcome and no close event.
- [ ] 3.2 Pass `:counters` and span context to exactly one `Transport.watch_owner/2` watcher per channel (SFTP's lifetime watcher) and emit `channel.close` there; verify exactly one close for normal close, remote close, overflow, frame limit, stream limit, lifetime expiry, request-context cancellation, owner death and a `:kill` of the channel process, each with the documented `reason` and byte/message counts, and that a watcher without telemetry state (the gateway `WebSocketRelay`) emits nothing.
- [ ] 3.3 Suppress inner channel events for `SFTP`, `DynamicConsole` and `EventListener`; verify one open/close pair per host-visible channel, one `:websocket` pair per exec `Session` channel and per channel forwarded by `Migration.relay/2`.
- [ ] 3.4 Emit `event_listener.callback` from the listener; verify success, raise and timeout outcomes and that no event type or payload appears in metadata.

## 4. Operation waits

- [ ] 4.1 Emit `operation.wait` spans from `Operation.wait/2` only, so `wait_with_context/3` produces one span; verify `polls`, `native_status` and `outcome` for success, native failure, deadline, cancellation and poll error, that invalid wait options emit nothing, and that no backend `DELETE` or extra mutation is sent.

## 5. Redaction and consumer verification

- [ ] 5.1 Add a fixture test that attaches to every event across the database-free suite and fails if any metadata value contains a fixture path, query, resource or project name, socket path, origin, identity, operation ID, ETag, header, native message or body byte.
- [ ] 5.2 Extend the isolated host consumer (`test/consumer`) to attach a handler and observe one request and one channel event, and assert that the existing client-only consumer (`test/consumer/client_only`) resolves no `:telemetry` and still compiles without warnings; verify both from a pushed immutable revision with `mise run check:consumer`.
- [ ] 5.3 Run `mise run check` and `mise run check:reference`; record that this change adds no real-Incus, gateway acceptance or Macus hardware evidence.
