# Proposal

## Why

`Transport.request/5` opens one passive Mint connection per request and closes it afterwards. Over a Unix socket that costs almost nothing. Over verified HTTPS, every call pays a full TCP and mutual-TLS handshake: client certificate and key files read, the CA bundle decoded, the server chain or pinned fingerprint verified. Central Opsmaru talks to registered direct-HTTPS targets, and `Operation.wait/2` turns each wait into a series of short GET polls, so handshakes can dominate latency and backend CPU. Keeping idle connections open between requests addresses that cost without changing native wire behavior, as long as reuse never carries a mutation over a socket whose state is unknown and never lets one set of credentials serve another.

## What Changes

- Add an optional, host-started `Opsmaru.Incus.ConnectionPool` built on NimblePool. The host adds it to its own supervision tree with bounded sizes. Loading or starting `:opsmaru_incus` still starts nothing.
- Add an explicit `pool:` option to `Connection.unix!/2` and `Connection.https!/2`. Connections without it behave exactly as today. Construction stays passive and performs no I/O.
- Key pools by the full connection binding: transport, address, server-trust material, client certificate identity and `require_authenticated`. Rotating credential or trust files yields a new binding, so a connection opened under old credentials is never handed to a request under new ones.
- Reuse pooled connections only for buffered GET and HEAD requests. Every other method takes a fresh connection, which can be returned to the pool afterwards for later reads. A mutation is therefore never written to a socket the server may already have closed, and failure classification (`:connection` versus `:uncertain`) stays exactly as it is today.
- Never queue. When a binding has no idle connection, the request opens a fresh connection outside the pool. When the pool is at its binding limit, the request runs unpooled. Pool processes never perform network I/O or TLS handshakes.
- Keep streamed transfers, WebSocket, raw, SFTP and NBD channels, SimpleStreams and OCI on fresh connections. Upgrades take over their socket and are never pooled.
- Record Finch as the rejected alternative.

## Capabilities

### New Capabilities

- `incus-connection-pool`: optional, host-started, binding-keyed reuse of idle native HTTP/1.1 connections for buffered reads, with unchanged failure semantics and no queueing.

### Modified Capabilities

None. The main spec inventory is empty. The foundation change's passive per-request transport stays the default, and its pending requirements stay owned by `add-embedded-incus-foundation`.

## Impact

- New dependency `{:nimble_pool, "~> 1.1"}`. It has no dependencies of its own and starts no application processes. Whether it is declared `optional: true` is decided in the design.
- Touches `Connection` (the new option and binding digest), `Transport.request/5` (checkout, reuse validation and check-in) and a new `Opsmaru.Incus.ConnectionPool` with its per-binding pool module. Public client functions, return values, errors and wire bytes are unchanged.
- Macus, which uses a private Unix socket, gains little and need not adopt it. Central Opsmaru is the intended consumer for HTTPS targets.
- If `add-incus-telemetry` lands, request metadata can gain a closed `connection` field (`:fresh`, `:reused` or `:unpooled`). That change is not modified here.
- `priv/incus/coverage.json` and foundation task 3.9 are unaffected. Pooling is transport behavior, not typed-client evidence.
