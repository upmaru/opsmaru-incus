# Design

## Context

See [proposal.md](proposal.md). A gateway exchange can enter through two adapters and end in four places:

| Entry | Path | Process that owns the exchange until it ends |
| --- | --- | --- |
| `Gateway.Plug` | refused before or at admission (`HTTPRelay.fail/2`) | the Plug request process |
| `Gateway.Plug` | `Local.serve/4` (discovery, trust) | the Plug request process |
| `Gateway.Plug` | `HTTPRelay.relay/4` | the Plug request process |
| `Gateway.Plug` | `WebSocket.upgrade/4` | the `WebSocketRelay` GenServer, after the upgrade commits |
| `Gateway.CowboyHandler` | `RawRelay.start/4` | the `RawRelay` actor, after `handoff/1` |

These processes are killed rather than asked to stop. `Lease` kills the owner after its interruption grace, `HTTPRelay.abort/1` kills the Cowboy connection and exits, the WebSocket watchdog and the raw watcher kill the relay at the idle or lifetime deadline, and Cowboy kills the request process when the caller disconnects. Code after the relay call and `terminate/2` therefore do not run reliably. `add-incus-telemetry` reached the same conclusion for client channels and emits their closure from a watcher.

## Goals / Non-Goals

**Goals:** one event pair per exchange with a truthful end; metadata sufficient for a host access log; no secret in any event; no behaviour change; no cost when nothing listens.

**Non-Goals:** a log file, log format or Logger call in this library; metrics definitions or reporters; per-frame or per-chunk events; events for host callbacks (`ready?`, `authorize`, `valid?`); events for `/runtime`, `/mcp` or any non-native route a host serves beside the gateway; exposing the host's grant; OpenTelemetry context propagation to the backend.

## Decisions

### 1. Telemetry events, not a host callback

The alternative is an optional `Host` callback such as `observe/3`. It needs no dependency and is scoped to one gateway. Telemetry is chosen because:

- hosts already attach `:telemetry` handlers for Phoenix and can derive metrics and logs from one event;
- the `Host` behaviour stays a pure authorization contract, with no callback whose failure mode has to be specified beside `authorize/2`;
- `add-incus-telemetry` already plans the emitter, dependency and catalogue conventions.

A host that runs several gateways distinguishes them by the `host` metadata value (the gateway's host module).

### 2. Optional dependency with a compiled no-op

As in `add-incus-telemetry` decision 1: `{:telemetry, "~> 1.3", optional: true}`, an `Opsmaru.Incus.Telemetry` module that selects its implementation with `Code.ensure_loaded?(:telemetry)`, and emission wrapped so that a loaded but unstarted `:telemetry` cannot raise into a request. Whichever change lands first creates the module; the other extends it.

### 3. Events

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:opsmaru_incus, :gateway, :exchange, :start]` | `system_time`, `monotonic_time` | `telemetry_span_context`, `host`, `protocol`, `method`, `peer_address`, `peer_port`, `peer_fingerprint` |
| `[:opsmaru_incus, :gateway, :exchange, :stop]` | `duration`, `request_bytes`, `response_bytes` | start metadata, `path`, `project`, `target`, `all_projects`, `operation`, `admitted_as`, `status`, `outcome`, `reason` |

- `host`: the gateway's host module, or `nil` when the gateway could not be resolved.
- `protocol`: `:http`, `:websocket` or `:raw`.
- `method`: the HTTP method as received when it is `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE` or `OPTIONS`, otherwise `nil`.
- `peer_address`, `peer_port`: from the server adapter, as passed to `Policy.request/1`.
- `peer_fingerprint`: lowercase hexadecimal SHA-256 of the peer certificate DER, or `nil`. It names the certificate the caller presented, not a trusted identity.
- `path`: the original encoded path when `Policy.route/1` accepted it (canonical and at most 8192 bytes), otherwise `nil`.
- `project`, `target`, `all_projects`, `operation`: the parsed `Request` fields, `nil`/`false` when the request was refused before parsing.
- `admitted_as`: `:caller`, `:anonymous`, `:operation_peer`, `:image_peer`, or `nil` when the request was not admitted.
- `status`: the HTTP status sent to the caller (101 for a completed upgrade), or `nil` when no response head was sent.
- `outcome`: `:ok` when the exchange completed as relayed or served, whatever the native status; otherwise the `Failure` outcome (`:not_sent`, `:uncertain`, `:sent`).
- `reason`: `nil` when `outcome` is `:ok`, otherwise one of `:invalid_request`, `:not_configured`, `:capacity`, `:not_ready`, `:unauthorized`, `:unsupported`, `:revoked`, `:admission`, `:idle`, `:lifetime`, `:limit`, `:backend`, `:caller_closed`, `:killed`.
- `request_bytes`, `response_bytes`: body bytes read from the caller and written to the caller. For WebSockets they are frame payload bytes; for raw upgrades, tunnelled bytes. Header and framing bytes are not counted. Request bytes count when read; response bytes count once written (a completed raw write, a WebSocket batch the adapter acknowledged, or the unacknowledged batch carrying the backend's close frame once handed to the adapter), never while still queued or never received by the adapter.

`Failure` gains an internal `reason` field set where each failure is constructed, so the closed set is assigned at the source and never derived from message text. `Failure.encode/1` and the wire body are unchanged. `Failure.new/4` takes the reason as a required `reason:` option beside the optional `operation:`, so no existing positional `operation` argument can be read as a reason, and an unknown reason raises.

Existing failures map to reasons as follows:

| Failure | `reason` |
| --- | --- |
| unresolved gateway (503), Cowboy handler without fallback (404), body already parsed (500) | `:not_configured` |
| admission at capacity (503) | `:capacity` |
| host not ready, admission unavailable, identity unavailable (503) | `:not_ready` |
| host denial, image-secret misuse, certificate policy denied or incomplete (403) | `:unauthorized` |
| protocol upgrade not implemented, raw upgrade on the Plug, WebSocket adapter unavailable or not HTTP/1.1 (501), certificate action not supported (405) | `:unsupported` |
| invalid or ambiguous path, selection, authorization, framing, body or handshake, unknown route (400/404) | `:invalid_request` |
| path or query too long (414), headers too large (431), body, response or identity over its limit (413/502) | `:limit` |
| request body not received in time (408) | `:idle` |
| grant expired or revoked during the exchange | `:revoked` |
| admission stopped during the exchange | `:admission` |
| backend response idle or lifetime deadline (504) | `:idle` / `:lifetime`, whichever fired |
| backend unavailable, negotiation failed, invalid or failed response (502) | `:backend` |

A completed WebSocket close handshake from either side, or both halves of a raw tunnel closing, is `outcome: :ok`; the socket teardown after a close frame is not reported as a backend or caller failure. A backend close frame the adapter never received does not complete the handshake.

There is no `:exception` event: every gateway failure is a returned `Failure` or a killed owner, and both end in `:stop`.

### 4. An exchange observer emits the stop

`Opsmaru.Incus.Gateway.Exchange.start/1` is called by the adapter as soon as it has the method, upgrade headers and peer, before `Policy.request/1`. It emits `:start` in the adapter process, so the host's Logger metadata and trace context apply, then spawns an unlinked observer that monitors the owner. The exchange handle holds one `:atomics` array for the facts any process may record: the two byte counts (added), the status, the first interruption reason, the sent outcome and the admission kind. The parsed request is sent to the observer once by the owner.

- Facts are recorded as they become known: `Exchange.request/2` after parsing, `Exchange.admitted/2` after admission, byte counts as bodies and frames move, the status when a response head is sent, and `Exchange.sent/2` once request bytes may have reached the backend or, for certificate create, update and delete, before the host's callback runs.
- The owner calls `Exchange.finish/2` with `:ended` or a `Failure`. `:ended` reports `outcome: :ok`, or the recorded interruption if there is one. Whoever interrupts an exchange records the reason with `Exchange.interrupt/2` before the kill or stop that follows: the relay itself, its WebSocket watchdog or raw watcher at a deadline, and the `Lease` (whose interruption function may take the reason) at revocation or admission loss. The first recorded reason wins.
- The observer is spawned before `:start` handlers run, so an owner killed inside one still reports its stop; an owner that dies before `:start` is emitted reports nothing.
- The observer emits `:stop` once, on `finish` or on the owner's `:DOWN`, whichever comes first. An owner that died without recording anything reports `outcome` from whether request bytes may have reached the backend (the relay's existing `sent_outcome`) and `reason: :killed`, or `:caller_closed` when the adapter observed the caller's socket close.
- `Exchange.transfer/2` moves the monitor when ownership moves: from the Plug process to `WebSocketRelay` once the upgrade is committed and the adapter accepted it, and from the Cowboy handler to `RawRelay` after a successful `handoff`. The relay may record reasons from the start, but reports the end only after it adopts the exchange. A failed upgrade finishes in the adapter process and is never transferred. In the Plug path the handle travels in `conn.private`, so `HTTPRelay.fail/2` finishes with its `Failure`, and a request served to completion is finished by `Gateway.Plug`.

Handlers for `:stop` therefore run in the observer, not in the relay. A slow handler cannot delay a relay, hold a backend socket open or consume an exchange deadline. Hosts correlate the pair through `telemetry_span_context`.

`Lease` is not reused as the observer. It is the revocation guard, it is killed by `Lease.stop/1` in the relay's `after` block, and anonymous exchanges and pre-admission refusals have none.

### 5. No cost when nothing listens

When `:telemetry` is not compiled in, `Exchange.start/1` returns an inert handle and every recording function is a no-op. When it is compiled in, `start/1` checks `:telemetry.list_handlers([:opsmaru_incus, :gateway, :exchange])` and returns the inert handle if it is empty. A handler attached mid-exchange sees only later exchanges. No process, table or handler exists because the library is loaded.

### 6. Metadata bounds and why they differ from client events

`add-incus-telemetry` excludes paths, project names and addresses from client events, because the calling host already holds them and the library should not put tenant data into every metrics backend. Gateway events include them, for three reasons:

- the gateway is the only place that knows them for raw upgrades, WebSocket ends and refusals, so a host cannot add them itself;
- the host's listener and Plug telemetry already see the same path and peer for the HTTP subset, so this is not a new exposure to the host;
- an access log without the path and caller is not one.

What stays excluded is everything that is a credential or unbounded:

- the `authorization` header and every other request or response header;
- the raw query string. It carries operation and image secrets (`secret=`) and unbounded filters. Only the parsed `project`, `target` and `all-projects` selections are emitted;
- `Request.image` in full, including the secret and fingerprint;
- request and response bodies and WebSocket frames;
- the host's grant and `host_config`. Handlers are global to the VM, so a host-owned term must not be published to every attached handler. A host that needs a principal derives it from `peer_fingerprint` and `admitted_as`, or from its own state;
- native error messages and `Failure` messages. `reason` is the closed equivalent.

Every string value is bounded: `path` by the 8192-byte route limit, `project`, `target` and `operation` by the 65536-byte query limit and the path limit that `Policy` already enforces.

### 7. Documentation

`docs/gateway.md` gains an "Exchange telemetry" section with the catalogue, the emitting process for each event, the excluded values and the rule that handlers must not log `path` to a destination less private than the host's own request log. The `Opsmaru.Incus.Telemetry` moduledoc lists the events.

## Risks / Trade-offs

- **Global handlers.** Any code in the host VM can attach to the prefix and read paths and peer addresses. Mitigation: nothing secret is emitted, and the documentation states what is.
- **Handler detachment.** `:telemetry` detaches a handler that raises, after which a host's log silently stops. Mitigation: documented; hosts that treat the log as a record must rescue in the handler. The library does not re-attach.
- **One process per observed exchange.** Mitigation: it is spawned only when a handler is attached, it holds no socket, and `Policy.callback/2` already spawns a process per host callback on the same path.
- **Pre-admission volume.** Unauthenticated floods produce one event pair per request, outside the admission cap. Mitigation: events are emitted after the TLS handshake and cost less than the refusal response; hosts bound their own log.
- **Reason classification drift.** A new `Failure` without a `reason` would report `nil`. Mitigation: `Failure.new` requires the reason, and a test asserts every documented reason is produced and no other.
- **Sibling ordering.** If `add-incus-telemetry` lands first, its "Gateway relay" scenario contradicts this change until narrowed. Mitigation: recorded in the proposal and in task 4.3.

## Open Questions

- Should a host be able to supply a bounded principal label for the exchange (for example through an optional `Host` callback that maps a grant to a short string), for hosts whose callers are not identified by a certificate? Macus does not need it. Deferred until central Opsmaru does.
- Should `path` be replaced or accompanied by a route template (`/1.0/instances/{name}`) for low-cardinality metrics? `add-incus-telemetry` has the same open question; both would use one template table built from the endpoint inventory.
