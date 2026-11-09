# Design

## Context

See [proposal.md](proposal.md). Native buffered requests go through `Transport.request/5`, which runs the exchange under `Transport.bounded/4`: a monitored worker performs the request while an independent guard kills it on deadline, cancellation or owner loss, and the caller classifies the outcome from the reply, the `:DOWN` message or its own timeout. A worker that dies or times out on a method other than GET or HEAD is reported as `:uncertain`. `Incus.raw_query/5` then decodes the response and turns HTTP and envelope failures into the error the caller receives; `API.call/4`, which serves `Incus.call/4` for reference methods, goes through it. `HTTP.request/4` is the raw DoHTTP slice over the same `Transport.request/5`. Streamed bodies use `Transfer`, which calls `Transport.bounded/4` directly.

`Transport.bounded/4` is no longer only a request wrapper. `ExecRun`, `ExecOutput.collect/5`, `SimpleStreams.refresh/1` and `SimpleStreams.Download.run/4` use it to bound composite work that itself issues requests or drains channels.

Long-lived channels are unlinked GenServers started by `WebSocket` and `RawChannel` (SFTP and NBD upgrades), and by `SFTP`, `DynamicConsole` and `EventListener`, which wrap one or more of them. Each calls `Transport.watch_owner/2` in `init/1`, which spawns a watcher monitoring both the owner and the channel and kills the channel when the owner or request context ends. `SFTP` starts two watchers when the host passes a request context: one on its private lifetime context and one on the host's. The optional gateway's `WebSocketRelay` also calls `Transport.watch_owner/2`, without a request context, for its relay process. `Operation.wait/2` (and `wait_with_context/3`, which delegates to it) polls the operation through `Incus.raw_query/5` until completion, deadline or cancellation.

Because the library kills workers and channels rather than asking them to stop, `terminate/2` and code after a blocked call are not reliable emission points. Correct events must come from processes that always observe the end: the caller for requests and waits, and the watcher for channels.

## Goals / Non-Goals

**Goals:** a small stable event catalogue that hosts attach to with standard `:telemetry` handlers; exactly one outcome event per started request, channel, callback and wait; redaction consistent with `Inspect` and `Redaction`; no behavior change and no new dependency for client-only consumers.

**Non-Goals:** metrics definitions, reporters, Logger calls, OpenTelemetry context injection into Incus requests, sampling, per-frame or per-chunk events, gateway relay, MCP tool, SimpleStreams origin and OCI events (see the proposal's scope list), and any change to the 20 ms guard tick, connection lifecycle or connection reuse (owned by the sibling `add-event-driven-cancellation` and `add-incus-connection-pool` plans).

## Decisions

### 1. Optional dependency with a compiled no-op

Add `{:telemetry, "~> 1.3", optional: true}` beside the optional `:plug` and `:cowboy`. Elixir lists optional dependencies as `optional_applications`, so when the host provides `:telemetry` it starts before `:opsmaru_incus`, and when it does not, nothing starts. `Opsmaru.Incus.Telemetry` chooses its implementation at compile time with `Code.ensure_loaded?(:telemetry)`, as the gateway modules already do for Plug and Cowboy; the absent branch is empty functions the compiler inlines away.

Emission is wrapped so that a missing handler table (`:telemetry` loaded but not started) is swallowed rather than raised into a request. `:telemetry` already catches handler exceptions and detaches the failing handler; the library adds no retry or re-attachment.

Alternative: a required dependency. That is harmless for Phoenix hosts but adds a dependency and a started application to client-only consumers, against the passive-library rule.

### 2. Event catalogue

All events use the `[:opsmaru_incus | rest]` prefix and the `:telemetry.span/3` measurement conventions (`system_time` and `monotonic_time` on start, `duration` in native time units on stop). Every event's metadata includes `telemetry_span_context`, a fresh reference used only to correlate start and stop.

| Event | Measurements | Metadata (beyond span context) |
| --- | --- | --- |
| `[:opsmaru_incus, :request, :start]` | `system_time`, `monotonic_time` | `method`, `native_method`, `shape`, `transport` |
| `[:opsmaru_incus, :request, :stop]` | `duration`, `request_bytes`, `response_bytes` | start metadata, `status`, `outcome` |
| `[:opsmaru_incus, :channel, :open, :start]` | `system_time`, `monotonic_time` | `kind`, `transport` |
| `[:opsmaru_incus, :channel, :open, :stop]` | `duration` | `kind`, `transport`, `status`, `outcome` |
| `[:opsmaru_incus, :channel, :close]` | `duration`, `bytes_in`, `bytes_out`, `messages_in`, `messages_out` | `kind`, `transport`, `reason` |
| `[:opsmaru_incus, :event_listener, :callback]` | `duration` | `outcome` |
| `[:opsmaru_incus, :operation, :wait, :start]` | `system_time`, `monotonic_time` | `native_method` |
| `[:opsmaru_incus, :operation, :wait, :stop]` | `duration`, `polls` | `native_method`, `native_status`, `outcome` |

Field values are closed sets:

- `method`: the native HTTP verb string as sent (`"GET"`, `"HEAD"`, `"POST"`, `"PUT"`, `"PATCH"`, `"DELETE"`, and `"OPTIONS"` for `HTTP.request/4`).
- `native_method`: the Incus Go client declaration name (for example `"GetInstance"`) when the call came through a typed method, otherwise `nil`. Raw queries and DoHTTP requests never synthesize one.
- `shape`: `:buffered` or `:streamed`. Direction is visible from the byte measurements.
- `transport`: `:unix` or `:https`.
- `kind`: `:websocket`, `:raw` (SFTP and NBD upgrades), `:sftp`, `:console` or `:events`.
- `status`: the HTTP status integer, or `nil` when no response head arrived.
- `outcome`: `:ok`, or the `Opsmaru.Incus.Error` `kind` returned by the emitting entry point (`:native`, `:uncertain`, `:deadline`, `:canceled`, `:connection`, `:overflow`, ...). It is always the classification that entry point returns; error kinds are compile-time atoms, so the set is bounded. For requests, typed model decoding that `API.call/4` and hand-written typed modules apply after `raw_query/5` returns is outside the span: a native success whose model then fails to decode reports `:ok` here and the decode error to the caller.
- `reason` for channel close: `:normal`, `:owner_down`, `:deadline`, `:canceled`, `:lifetime`, `:overflow`, `:frame_limit`, `:stream_limit`, `:remote_closed`, `:channel_io` or `:killed`. `:lifetime` distinguishes the channel's own `stream_timeout` expiry, which readers receive as `:deadline` today, from a request-context deadline.
- `native_status`: the final native operation status string (`"Success"`, `"Failure"`, `"Cancelled"`) when observed, otherwise `nil`.

There is no `:exception` event. The transport converts every failure into a returned error, so failure is a `:stop` with a non-`:ok` outcome. Argument, option, path, authorization and body validation that fails before the request reaches the transport emits nothing.

Byte counts are wire body bytes (request body sent and response body received), not header or framing bytes. Operation waits also produce one request span per poll; hosts correlate them through their own process context, since both are emitted in the same caller.

### 3. Requests: emit at the entry point, in the caller, exactly once

`:start` is emitted in the caller immediately before `Transport.request/5` or, for streams, `Transport.bounded/4` is invoked from one of three entry points: `Incus.raw_query/5`, `HTTP.request/4` on an `%Incus{}` handle, and `Transfer`'s shared runner. `:stop` is emitted in the same caller after the entry point has its final classification, including `raw_query/5`'s conversion of HTTP status, envelope and decode failures. Neither the worker nor the guard ever emits. A killed worker therefore still yields one `:stop` with `:deadline`, `:canceled` or `:uncertain`, and a late result cannot produce a second event because the caller already flushed it.

`Transport.bounded/4` itself does not emit. It also bounds composite work (`ExecRun`, `ExecOutput.collect/5`, SimpleStreams refresh and download), and emitting there would produce spans that are not requests and nest real ones. A request rejected by `RequestContext.check/1` before a worker is spawned is still a started request at the entry point and emits one start/stop pair with the returned `:canceled` or `:deadline`.

Byte counts come from a `:counters` reference created by the caller and passed through an internal argument of `Transport.request/5` and the `Transfer` runner to the worker, which updates it as it sends and receives. Counters survive the worker's death, so a deadline after a partial download still reports the bytes moved. Possibly accepted mutations report `outcome: :uncertain`, exactly as returned.

Emitting in the caller places handlers in the host's process, so Logger metadata and OpenTelemetry context set by the host apply without the library touching either. If the caller itself dies mid-request, no `:stop` is emitted, matching `:telemetry.span/3` semantics; the guard still kills the worker.

`native_method` reaches `raw_query/5` from `API.call/4` through an internal `@doc false` entry beside it. The public `raw_query` option allowlist (`:body`, `:etag`) is unchanged, so callers cannot set or spoof the name, and it never reaches the wire. Hand-written typed paths that call `raw_query` directly (for example `Operation.poll/1` and `Operation.cancel/1`, which report `"GetOperation"` and `"DeleteOperation"`) pass their declaration name through the same entry where they implement exactly one reference method; others report `nil`.

SimpleStreams and OCI handles reach `HTTP.request/4` and `Transfer.download_origin_events/3` against an image origin, and `SimpleStreams` fetches its catalogue with `Transport.request/5` directly. None of those emit (proposal scope).

### 4. Channels: emit closure from the watcher

`channel.open` is a span in the opening process around the upgrade, using the same outcome classification `open` returns. A failed upgrade emits `open.stop` with that outcome and no `close`.

After a successful upgrade the channel creates a `:counters` reference and hands it, with the start time and span context, to its `Transport.watch_owner/2` watcher through a new optional argument. The channel increments counters as it moves bytes and messages, and records its closure reason in a counter slot just before stopping on its own. The watcher already monitors the channel; on the channel's `:DOWN` it emits exactly one `[:opsmaru_incus, :channel, :close]`. It reads the recorded reason, or classifies the death itself (`:owner_down` when it killed the channel because the owner died, `:deadline` or `:canceled` from the request context, otherwise `:killed`). A watcher started without telemetry state, such as the gateway's `WebSocketRelay` watcher, emits nothing.

When a channel starts more than one watcher, exactly one carries telemetry state. For `SFTP` that is the lifetime watcher it always starts; the host-context watcher only kills.

Handlers for `close` run in the watcher, not the host's process. That is unavoidable for a killed channel and is documented. Hosts correlate through `telemetry_span_context` from `open`.

Composite channels emit one open/close pair for the host-visible channel only. `SFTP` wraps a `RawChannel`, `DynamicConsole` wraps control and data WebSockets, and `EventListener` wraps one events WebSocket; each opens its inner channels with telemetry suppressed. Raw SFTP and NBD channels opened directly through `Incus` emit as `:raw`. An exec `Session` is a struct, not a channel process, so each of its native WebSockets emits as `:websocket`, as do the channels `Migration.relay/2` forwards.

### 5. Event listener callbacks

`EventListener` already runs each callback sequentially in an isolated, monitored worker with a deadline. It emits one `[:opsmaru_incus, :event_listener, :callback]` per callback with its duration and `outcome` (`:ok`, `:callback_failed` or `:callback_timeout`), emitted from the listener process after it observes the worker's result or death. Event types and payloads are not included.

### 6. Operation waits

`Operation.wait/2` emits a span around the whole wait after its option validation succeeds; `wait_with_context/3` delegates to it and emits nothing of its own. `polls` counts completed poll requests, `native_status` is the final status if observed, and `outcome` matches the returned value (`:ok`, `:operation_failed`, `:deadline`, `:canceled` or a poll error kind). `native_method` is `nil` for a handle without a known originating declaration. A local timeout leaves the backend operation untouched, as today, and the event never implies backend cancellation. Server-side waits through `GetOperationWait` (used by the operations layer) are ordinary request spans.

### 7. Redaction

Metadata never contains request paths or queries, instance, image, project, member or other resource names, socket paths, origins or addresses, certificates or credentials, host identities, request contexts, operation IDs or URLs, ETags, native error messages, headers or bodies. Bounded strings and atoms, HTTP status integers, Go declaration names, closure reasons and counts are the only values. This matches the existing posture of `Error`, `Connection` and `Operation` `Inspect` output and of `Redaction.status/2` for channel crash reports.

Resource names and operation IDs are deliberately excluded even though hosts may find them useful. Including them would make the library responsible for tenant-data exposure in every host's metrics backend. Hosts that need them already hold them at the call site and can add them to their own process context before calling.

## Risks / Trade-offs

- **Synchronous handlers.** A slow handler on `request.start` delays the caller and consumes part of an absolute `RequestContext` deadline. Mitigation: document that handlers must be cheap. The library does not bound handler time, because doing so would mean spawning per event.
- **Watcher-context handlers.** `channel.close` handlers lack host Logger and trace context. Mitigation: span-context correlation, documented.
- **Event churn per poll.** A long `Operation.wait/2` with a short poll interval (default 50 ms) emits many request spans. They are useful for diagnosing poll load; hosts can filter by `native_method: "GetOperation"`.
- **Gateway blind spot.** Relayed traffic emits nothing from this library. Mitigation: documented; hosts observe it through their own Plug/Cowboy telemetry until a gateway change adds relay events.
- **Sibling plans.** `add-event-driven-cancellation` rewrites the guard and watcher loops and may remove SFTP's lifetime context; telemetry state then rides on whichever single watcher remains. `add-incus-connection-pool` would add a closed `connection` metadata value. Either can land first without changing this catalogue's existing keys.
- **Catalogue stability.** Event names and metadata keys become a public contract. Additions are compatible; renames or removals require a changelog entry and a new change.

## Open Questions

- Should hosts be able to opt in to a templated route (for example `/1.0/instances/{name}`) for raw queries where `native_method` is `nil`? Deferred until a host asks; it needs a verified template table built from the endpoint inventory.
- Should `project` be emitted when it is host-selected configuration rather than request input? Currently excluded under the redaction rule.
