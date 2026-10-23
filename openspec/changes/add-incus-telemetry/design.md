# Design

## Context

See [proposal.md](proposal.md). Every native HTTP exchange runs through `Transport.bounded/4`: a monitored worker performs the request while an independent guard kills it on deadline, cancellation or owner loss, and the caller classifies the outcome from the reply, the `:DOWN` message or its own timeout. Streamed bodies use `Transfer`, also on `Transport.bounded/4`. Long-lived channels are unlinked GenServers started by `WebSocket`, `RawChannel`, `SFTP`, `DynamicConsole` and `EventListener`; each calls `Transport.watch_owner/2`, which spawns a watcher monitoring both the owner and the channel and kills the channel when the owner or request context ends. `Operation.wait/2` polls the operation through ordinary requests until completion, deadline or cancellation.

Because the library kills workers and channels rather than asking them to stop, `terminate/2` and code after a blocked call are not reliable emission points. Correct events must come from processes that always observe the end: the caller for requests and the watcher for channels.

## Goals / Non-Goals

**Goals:** a small stable event catalogue that hosts attach to with standard `:telemetry` handlers; exactly one outcome event per started request, channel and wait; redaction consistent with `Inspect` and `Error`; no behavior change and no new dependency for client-only consumers.

**Non-Goals:** metrics definitions, reporters, Logger calls, OpenTelemetry context injection into Incus requests, sampling, per-frame or per-chunk events, gateway and MCP tool events, and any change to the 20 ms guard tick or connection lifecycle.

## Decisions

### 1. Optional dependency with a compiled no-op

Add `{:telemetry, "~> 1.3", optional: true}`. Elixir lists optional dependencies as `optional_applications`, so when the host provides `:telemetry` it starts before `:opsmaru_incus`, and when it does not, nothing starts. `Opsmaru.Incus.Telemetry` chooses its implementation at compile time with `Code.ensure_loaded?(:telemetry)`; the absent branch is empty functions the compiler inlines away.

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

- `method`: the HTTP verb atom (`:get`, `:post`, `:put`, `:patch`, `:delete`, `:head`).
- `native_method`: the Incus Go client declaration name (for example `"GetInstance"`) when the call came through a typed method, otherwise `nil`. Raw queries never synthesize one.
- `shape`: `:buffered`, `:download` or `:upload`.
- `transport`: `:unix` or `:https`.
- `kind`: `:websocket`, `:raw`, `:sftp`, `:console` or `:events`.
- `status`: the HTTP status integer, or `nil` when no response head arrived.
- `outcome`: `:ok`, or the `Opsmaru.Incus.Error` `kind` returned to the caller (`:native`, `:uncertain`, `:deadline`, `:canceled`, `:connection`, `:overflow`, ...). It is always the same classification the caller receives.
- `reason` for channel close: `:normal`, `:owner_down`, `:deadline`, `:canceled`, `:lifetime`, `:overflow`, `:frame_limit`, `:remote_closed`, `:channel_io` or `:killed`.
- `native_status`: the final native operation status string (`"Success"`, `"Failure"`, `"Cancelled"`) when observed, otherwise `nil`.

There is no `:exception` event. The transport converts every failure into a returned error, so failure is a `:stop` with a non-`:ok` outcome. An exception raised into the caller by argument validation happens before `:start` and emits nothing.

Byte counts are wire body bytes (request body sent and response body received), not header or framing bytes. Operation waits also produce one request span per poll; hosts correlate them through their own process context, since both are emitted in the same caller.

### 3. Requests: emit in the caller, exactly once

`Transport.bounded/4` emits `:start` in the caller before spawning the worker and `:stop` after the caller has its result, whichever of the three receive branches produced it. The worker never emits. A killed worker therefore still yields one `:stop` with `:deadline` or `:canceled`, and a late result cannot produce a second event because the caller already flushed it.

Byte counts come from a `:counters` reference created by the caller and updated by the worker as it sends and receives. Counters survive the worker's death, so a deadline after a partial download still reports the bytes moved. Possibly accepted mutations report `outcome: :uncertain`, exactly as returned.

Emitting in the caller places handlers in the host's process, so Logger metadata and OpenTelemetry context set by the host apply without the library touching either. If the caller itself dies mid-request, no `:stop` is emitted, matching `:telemetry.span/3` semantics; the guard still kills the worker.

`native_method` is threaded from `Incus.call/4` into `raw_query/5` as an internal option. It never reaches the wire.

### 4. Channels: emit closure from the watcher

`channel.open` is a span in the opening process around the upgrade, using the same outcome classification `open/3` returns. A failed upgrade emits `open.stop` with that outcome and no `close`.

After a successful upgrade the channel creates a `:counters` reference and hands it, with the start time and span context, to its `Transport.watch_owner/2` watcher. The channel increments counters as it moves bytes and messages, and records its closure reason in a counter slot just before stopping on its own. The watcher already monitors the channel; on the channel's `:DOWN` it emits exactly one `[:opsmaru_incus, :channel, :close]`. It reads the recorded reason, or classifies the death itself (`:owner_down` when it killed the channel because the owner died, `:deadline` or `:canceled` from the request context, otherwise `:killed`).

Handlers for `close` run in the watcher, not the host's process. That is unavoidable for a killed channel and is documented. Hosts correlate through `telemetry_span_context` from `open`.

`SFTP` wraps a `RawChannel`; only the outer `:sftp` channel emits, and the inner raw channel's events are suppressed so that one host-visible channel produces one open/close pair. `DynamicConsole` follows the same rule for its control and data channels.

### 5. Event listener callbacks

`EventListener` already runs each callback in an isolated, monitored worker with a deadline. It emits one `[:opsmaru_incus, :event_listener, :callback]` per callback with its duration and `outcome` (`:ok`, `:callback_failed` or `:callback_timeout`), emitted from the listener process after it observes the worker's result or death. Event types and payloads are not included.

### 6. Operation waits

`Operation.wait/2` emits a span around the whole wait. `polls` counts completed poll requests, `native_status` is the final status if observed, and `outcome` matches the returned value (`:ok`, `:operation_failed`, `:deadline`, `:canceled` or a poll error kind). A local timeout leaves the backend operation untouched, as today, and the event never implies backend cancellation.

### 7. Redaction

Metadata never contains request paths or queries, instance, image, project, member or other resource names, socket paths, origins or addresses, certificates or credentials, host identities, request contexts, operation IDs or URLs, ETags, native error messages, headers or bodies. Bounded atoms, HTTP status integers, Go declaration names, closure reasons and counts are the only values. This matches the existing posture of `Error`, `Connection` and `Operation` `Inspect` output.

Resource names and operation IDs are deliberately excluded even though hosts may find them useful. Including them would make the library responsible for tenant-data exposure in every host's metrics backend. Hosts that need them already hold them at the call site and can add them to their own process context before calling.

## Risks / Trade-offs

- **Synchronous handlers.** A slow handler on `request.start` delays the caller and consumes part of an absolute `RequestContext` deadline. Mitigation: document that handlers must be cheap. The library does not bound handler time, because doing so would mean spawning per event.
- **Watcher-context handlers.** `channel.close` handlers lack host Logger and trace context. Mitigation: span-context correlation, documented.
- **Event churn per poll.** A long `Operation.wait/2` with a short poll interval emits many request spans. They are useful for diagnosing poll load; hosts can filter by `native_method: "GetOperation"`.
- **Catalogue stability.** Event names and metadata keys become a public contract. Additions are compatible; renames or removals require a changelog entry and a new change.

## Open Questions

- Should hosts be able to opt in to a templated route (for example `/1.0/instances/{name}`) for raw queries where `native_method` is `nil`? Deferred until a host asks; it needs a verified template table built from the endpoint inventory.
- Should `project` be emitted when it is host-selected configuration rather than request input? Currently excluded under the redaction rule.
