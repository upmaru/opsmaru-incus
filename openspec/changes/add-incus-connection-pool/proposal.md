# Proposal

## Why

`Transport.request/5` opens one passive Mint connection per request and closes it afterwards. Over a Unix socket that costs almost nothing. Over verified HTTPS, every call pays a full TCP and mutual-TLS handshake: the CA bundle read and decoded by `Connection.ca_certificates/1`, the client certificate and key loaded by `:ssl`, and the server chain or pinned fingerprint verified. Central Opsmaru talks to registered direct-HTTPS targets. `Operation.wait/2` turns each wait into a series of short GET polls (50 ms by default), and every shared-operations tool call whose host binding returns a connection runs `Incus.connect/2` (`GET /1.0`) before its own reads, so handshakes can dominate latency and backend CPU. Keeping idle connections open between requests addresses that cost without changing native wire behavior, as long as reuse never carries a mutation over a socket whose state is unknown and never lets one set of credentials serve another.

## What Changes

- Add an optional, host-started `Opsmaru.Incus.ConnectionPool` with bounded binding count, slots, idle timeout and connection age. The host adds it to its own supervision tree. Loading or starting `:opsmaru_incus` starts neither a pool nor a NimblePool application supervisor.
- Add an explicit `pool:` option to `Connection.unix!/2` and `Connection.https!/2`. Connections without it behave exactly as today. Construction stays passive and performs no I/O, and `with_context/2`, `project/2` and `member/2` keep the option.
- Key pools by the full connection binding: `owner`, transport, address, `require_authenticated` and, for HTTPS, the bytes of the client certificate, key and optional CA bundle plus any pinned fingerprint. Rotating credential or trust files yields a new binding, so a connection opened under old credentials is never handed to a request under new ones.
- Pool only `Transport.request/5`, the buffered path behind `Incus.raw_query`, the typed `Incus.call` descriptors built on it, `Operation.poll/1` and `wait/2`, `HTTP.request/4` and SimpleStreams catalog fetches. Within it, reuse idle connections only for GET and HEAD. Every other method takes a fresh connection, which can be returned to the pool afterwards for later reads. A mutation is therefore never written to a socket the server may already have closed, and failure classification (`:connection`, `:response_closed` and the other read kinds, `:uncertain` for mutations) stays exactly as it is today.
- Reject saturated checkouts without queuing for a slot. Bound admission and acquisition by the request's remaining deadline. A miss uses a fresh connection, and the request worker performs the handshake, probe, send and receive.
- Keep every caller of `Transport.open/2` on fresh connections: streamed transfers (`Transfer`, SimpleStreams downloads), exec, WebSocket, raw, SFTP and NBD channels, event listeners, dynamic consoles and all gateway relays. Upgrades take over their socket and are never pooled.
- Declare NimblePool `optional: true, runtime: false` and use synchronous slots. Client-only consumers compile without NimblePool.
- Record Finch as the rejected alternative.

### Scope against newer surfaces

- **Gateway backend connections: out.** `HTTPRelay`, `WebSocketRelay` and `RawRelay` open their backend through `Transport.open/2`, and `docs/gateway.md` documents one new backend connection per exchange, never pooled, retried or redirected. Relays stream in active-once mode, forward caller-chosen methods, and close the backend socket when a lease expiry or revocation interrupts the exchange. A `pool:` option on the gateway's fixed `Connection` is ignored by relays.
- **Shared operations reads: in, without code changes.** `Opsmaru.Incus.Operations` reaches Incus only through `Incus.connect/2` and `Incus.call/4`. When the host's `Operations.Host.binding/2` returns a pooled connection, discovery, inspection and `GetOperation`/`GetOperationWait` reads reuse sockets, and mutations open fresh ones. Operations exec sessions use channels and stay unpooled.
- **Operation documents (PR #69).** Both proposed executors, `Operations.Composite.run/3` and `Operations.Native.run/3`, inherit this behavior from the host binding. Document generation and cassette import are independent of connection pooling.
- **SimpleStreams catalog: in; downloads: out.** Catalog and index GETs already go through `Transport.request/5` on the explicit HTTPS connection and follow its `pool:` like any buffered read. Image file downloads stream through `Transport.bounded/4` and `Transport.open/2` and stay fresh.
- **OCI: only the passive HTTP handle.** `OCI.http_request/4` uses `HTTP.request/4` and follows the connection's `pool:` for GET and HEAD. Registry fetches and conversion belong to the host OCI adapter and are untouched.

## Capabilities

### New Capabilities

- `incus-connection-pool`: optional, host-started, binding-keyed reuse of idle native HTTP/1.1 connections for buffered reads, with unchanged failure semantics and no queueing.

### Modified Capabilities

None. The existing embedded-service, client and operations capabilities permit this transport option. The `incus-gateway` capability requires a fresh backend connection per exchange.

## Impact

- New dependency `{:nimble_pool, "~> 1.1", optional: true, runtime: false}`. `ConnectionPool` compiles when NimblePool is available, and requesting `pool:` without it raises at construction. The full consumer supplies NimblePool with its application startup disabled.
- Touches `Connection` (the new option, binding digest and the certificate and key bytes a pooled handshake uses), `Transport.request/5` and `do_request/5` (checkout, reuse validation and check-in) and a new `Opsmaru.Incus.ConnectionPool` with its per-binding pool module. `Transport.open/2` keeps today's options for unpooled connections, and its other callers, public client functions, return values, errors and wire bytes are unchanged.
- `docs/incus-client.md` gains a pool section. Its statements that clients own no pool and that `Incus.disconnect/1` is passive stay true, because the pool is host-owned.
- Macus, which uses a private Unix socket relayed into its guest, gains little and need not adopt it. Idle pooled sockets would hold relay resources there, so adoption needs its own evidence. Central Opsmaru is the intended consumer for HTTPS targets.
- If `add-incus-telemetry` (capability `incus-telemetry`) lands, request metadata can gain a closed `connection` field (`:fresh`, `:reused` or `:unpooled`). That change is not modified here.
- If `add-event-driven-cancellation` (capability `incus-cancellation`) lands, request guards kill workers on events instead of 20 ms ticks. Pool cleanup depends only on the worker being killed, not on how.
- `priv/incus/coverage.json` and its completion records are unaffected. Pooling is transport behavior, not typed-client evidence.

## Rollout

Measure the existing transport against an explicitly approved isolated Incus project before implementing the pool. Compare Unix, verified HTTPS with full handshakes, and verified HTTPS with observed TLS 1.3 resumption when supported. Record latency, handshake counts and Incus CPU. Use the measured benefit and error rates to decide whether to proceed. Start with verified HTTPS buffered reads, then extend the fixtures to Unix and the remaining buffered call sites.
