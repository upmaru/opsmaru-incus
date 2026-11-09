# Design

## Context

See [proposal.md](proposal.md). `Transport.request/5` runs `do_request/5` inside a `Transport.bounded/4` worker. `bounded/4` first rejects a cancelled or expired `RequestContext`, registers the worker in the caller's `WorkScope` when one is bound, and spawns an independent guard that kills the worker on deadline, cancellation or owner loss. The worker opens a passive HTTP/1.1 Mint connection (`Transport.open/2`), sends one request, reads the full response in `receive_response/5` under the 64 KiB header budget and `max_response_bytes`, and closes the socket in an `after` clause.

`Transport.open/2` sets `timeout`, `send_timeout` and `send_timeout_close: true` from the request's remaining deadline when it connects. A connect failure is reported as `:connection`, because no request bytes could have left. After a connection opened, `failed/2` and `Incus.raw_query` report a failure of a non-GET/HEAD request as `:uncertain`. GET and HEAD keep their local kind: `:deadline` for a Mint receive timeout, `:response_closed` when the transport closed before any parsed response event, and otherwise `:response`, `:response_limit`, `:invalid_response`, `:request` or `:canceled`.

`Connection.https!/2` takes `tls:` references to an optional CA bundle, a client certificate, a private key and an optional SHA-256 server fingerprint (at least one of CA and fingerprint). `Connection.tls_options/1` decodes the CA bundle on every connect through `ca_certificates/1`, deliberately avoiding OTP's shared trust-file cache, passes the certificate and key as `certfile`/`keyfile` paths to `:ssl`, verifies the hostname from the origin and, with a fingerprint, adds `ServerTrust.verify/3` as `verify_fun`. Connections carry no pool, and `Opsmaru.Incus.disconnect/1` is a no-op.

Only three callers use `Transport.request/5`: `Incus.raw_query/5` (and through it typed descriptors, `Incus.connect/2`, `Operation.poll/1` and `wait/2`, and the shared operations layer), `HTTP.request/4` (including `OCI.http_request/4`) and SimpleStreams catalog fetches. Everything else, including streamed transfers, SimpleStreams downloads, exec, channels, event listeners and the gateway relays, calls `Transport.open/2` or `Transport.bounded/4` directly.

## Goals / Non-Goals

**Goals:** fewer HTTPS handshakes for reads, discovery and operation polls; a pool the host starts, sizes and stops; strict separation of owners, credentials and trust; unchanged wire behavior and failure classification; no queueing and no new failure modes for callers that do not opt in.

**Non-Goals:** HTTP/2 or multiplexing, request retries, pooling of streams, channels, upgrades or gateway relays, reuse for mutations, shared pools across hosts or nodes, health checking of Incus servers, automatic pool creation on dependency load, and changes to `Context` authorization or readiness.

## Decisions

### 1. Host-started component on NimblePool

`Opsmaru.Incus.ConnectionPool` is a child spec the host adds to its own tree, following `ClientSupervisor`:

```elixir
{Opsmaru.Incus.ConnectionPool,
 name: MyHost.IncusPool, max_bindings: 64, size: 4, idle_timeout: 15_000}
```

It starts a supervisor containing a `Registry` and a `DynamicSupervisor` for per-binding NimblePool instances, plus a small manager that admits and stops bindings. Every limit is a validated bounded integer. Nothing starts until the host starts it, and stopping it closes only pooled local sockets. It never cancels or contacts Incus work.

Each binding's NimblePool is `lazy: true`, with `worker_idle_timeout` equal to `idle_timeout`. `handle_ping/2` removes connections idle past `idle_timeout`. NimblePool 1.1 documents that `handle_ping/2` cannot terminate an empty lazy pool, so the manager stops a binding's pool once it has had no workers and no checkouts for `idle_timeout`. `max_bindings` bounds total pool processes.

### 2. The binding key

A pool's key is a SHA-256 digest of the connection `owner`, the transport, the normalized address (socket path, or scheme, host and port), `require_authenticated`, and for HTTPS the bytes of the client certificate, the private key and the CA bundle when present, together with any pinned fingerprint. This follows `EventListener.backend_binding/1`, which already treats owner, transport, address and TLS as the backend binding, but digests file contents instead of paths, because paths can be rotated in place. Including `owner` keeps socket sharing inside the boundary `Context.authorize/2` enforces, even when two owners use identical credentials.

`:ssl` may serve `certfile`/`keyfile` from its own PEM cache, so a handshake could present older bytes than the digest describes. For pooled connections, the worker reads the certificate and key once per request, digests them, and passes the same decoded bytes to the handshake as `cert`/`key`, as `tls_options/1` already does for the CA bundle. The binding therefore always matches the identity presented. Unpooled connections keep today's options byte for byte. Rotated material produces a new key without host action, and old bindings idle out.

Project, member, request context, timeouts, budgets and `Context` identity are not in the key. They do not affect the TLS session or the socket. They are applied per request exactly as today, and `Context.authorize/2`, including the host's `ready?` check, still runs before any checkout. The digest and key never appear in `Inspect`, errors, telemetry or the `Registry` name. Registry entries use an opaque reference that maps to the digest inside the manager.

### 3. Reads reuse, mutations do not

The method decides the checkout:

| Method | With an idle pooled connection | Without one |
| --- | --- | --- |
| GET, HEAD | Reuse, after validation | Open fresh |
| Any other | Never reused; open fresh | Open fresh |

After any request whose response completed cleanly, the connection is offered back to its binding's pool if all of these hold: the response did not carry `connection: close`, the status was not 101, `Mint.HTTP.open?/1` is true, and the pool is below `size`. Otherwise it is closed. `HTTP.request/4` already keeps `connection` a transport-owned request header, so callers cannot ask the server to close. A fresh connection opened for a mutation can therefore later serve a read, but a mutation never travels over a socket that has sat idle.

This keeps failure classification unchanged. A mutation's connect failure is still `:connection`, and a failure after the connection opened is still `:uncertain`. Reusing pooled sockets for mutations would turn a server's idle close, racing with our write, into a spurious `:uncertain` with no way to tell it from a real lost response. Reads stay safe to classify: a stale-socket failure on a reused GET is reported with its existing kind, normally `:response_closed`, and is never retried by the library. The caller sees one failed read, as it can today, and host code that already treats `:response_closed` reads as recoverable, such as the gateway acceptance host's bounded metadata-read recovery, keeps that choice.

### 4. Reuse validation

Before handing out an idle connection, the pool checks that `Mint.HTTP.open?/1` is true. It then performs a non-blocking `Mint.HTTP.recv(conn, 0, 0)`. A `:timeout` transport error means the socket is idle and healthy. A closed socket, any received bytes or response events, or any other error discards the connection, and the next idle one is tried. When none passes, the request opens a fresh connection. Idle passive sockets have no reader, so this probe is how a server-side close or stray data is detected before reuse.

A reused socket still carries the `send_timeout` set when it was opened. Before writing, the worker resets `send_timeout` on the underlying socket to the current request's remaining deadline. If that fails, the connection is discarded and the request opens a fresh one. Receive deadlines are already passed per `recv/3` call.

### 5. No queueing, no I/O in the pool

The pool never performs a handshake. NimblePool's `init_worker/1` returns an empty slot and never connects. Fresh connections are opened by the request's bounded worker, outside the pool, and offered back at check-in. Checkout uses a short fixed bound (single-digit milliseconds, set in implementation and documented). If no idle connection is available within it, the worker proceeds with a fresh connection. A slow pool or a dead binding therefore degrades to today's behavior and never blocks a request or adds a failure.

When `max_bindings` is reached, new bindings are not admitted and their requests run unpooled. The pool never evicts an active binding.

### 6. Ownership and kills

Checkout transfers the socket to the bounded worker with `Mint.HTTP.controlling_process/2`. Check-in transfers it back. If the guard or a `WorkScope` kills the worker mid-request, NimblePool sees the client go down and removes that worker, closing the socket in `terminate_worker/3`. A partially read response is never returned to the pool. A worker killed after check-in has nothing to lose. Pool processes trap no caller exits and hold no caller references beyond NimblePool's own monitors. This depends only on the worker being killed, so it holds whether guards poll or, under `add-event-driven-cancellation`, react to events.

### 7. Dependency

`{:nimble_pool, "~> 1.1", optional: true}` is small, depends only on Elixir, and starts no application processes. The gateway already compiles its Plug and Cowboy modules only when those optional dependencies are present, and the isolated consumer check builds a client-only consumer without them. `ConnectionPool` follows the same pattern. `Transport` reaches NimblePool only through `ConnectionPool`, and only when a connection carries `pool:`. Requesting `pool:` when `ConnectionPool` is not compiled raises `ArgumentError` at construction, which is a code check, not I/O.

### 8. Surfaces that stay unpooled

- **Gateway relays.** `HTTPRelay`, `WebSocketRelay` and `RawRelay` open their backend through `Transport.open/2`, stream in active-once mode, relay caller-chosen methods, and close their backend socket when a lease expiry, revocation or owner loss interrupts the exchange. The documented gateway contract is one new backend connection per exchange, never pooled, retried or redirected. Pooling there would mix relay ownership with pool ownership and gain little, because each exchange already holds its socket for its whole life. Relays ignore `pool:`.
- **Streams and channels.** `Transfer`, SimpleStreams downloads, `ExecRun`, `ExecOutput`, `WebSocket`, `RawChannel`, SFTP, NBD, `EventListener` and `DynamicConsole` keep their own connection for the stream's life. Upgrades take over their socket.
- **Host adapters.** OCI registry access and SimpleStreams delta conversion run in host adapters and are outside the library's transport.

## Alternatives Considered

### Finch (rejected)

Finch 0.24 is the standard Mint pool and is built on NimblePool. It supports Unix sockets, tags pools, and does not retry requests on its own. It does not fit here:

- **Credentials are fixed at start.** Finch keys pools by scheme, host, port and an optional tag, and takes TLS options from the `pools:` map at `Finch.start_link/1` or from a single `:default` entry. Central Opsmaru registers HTTPS targets at runtime, each with its own client certificate. That forces either one Finch instance per target, which the host would have to supervise dynamically, or a tag scheme kept outside Finch so that different credentials never share a pool keyed by host.
- **There is no reuse policy per method.** Finch reuses any idle connection for any method. Restricting mutations to fresh sockets would require a parallel tag per binding.
- **Response guards move.** The library's header byte budget, body limit and absolute deadline are enforced in `receive_response/5`. With Finch they would need to be re-implemented through `Finch.stream_while/5` callbacks, and the deadline would be split between Finch's `receive_timeout` and `request_timeout`.
- **It adds dependencies.** Finch requires `:telemetry`, `nimble_options` and `mime`, which works against keeping `:telemetry` optional in `add-incus-telemetry`.
- **It does not cover upgrades.** Channels and gateway relays would stay on direct Mint anyway, leaving two transport stacks.

Using NimblePool directly keeps the existing transport, framing and failure code as the single implementation and adds only reuse.

### TLS session resumption without a pool

OTP `:ssl` can resume TLS 1.3 sessions with client session tickets. This skips certificate verification on reconnect but still costs a TCP round trip and part of a handshake, and resumption state lives in OTP's shared session cache, against the per-connection trust handling in `tls_options/1`. It is measured as a baseline in task 1.1, not adopted.

## Risks / Trade-offs

- **Server idle close.** An Incus server may close idle keep-alive connections sooner than `idle_timeout`. The probe in decision 4 catches most cases. The remaining race only affects reads, which fail visibly as `:response_closed` without retry. Hosts may see that kind more often than today.
- **Stale trust.** A connection verified against an old CA or pinned fingerprint keeps serving its binding until it idles out. Rotation creates a new binding immediately. Hosts that must revoke trust instantly can stop and restart the pool.
- **More open sockets.** Up to `max_bindings * size` idle sockets per node. All are bounded and closed on idle or pool stop. On a relayed Unix socket, such as Macus's guest relay, idle sockets also hold relay resources.
- **Per-request digest.** Hashing certificate, key and CA bytes costs microseconds, small next to the file reads already done per request.

## Open Questions

- Should hosts be able to opt mutations into reuse for bindings they consider safe? Deferred. It changes `:uncertain` frequency and needs evidence from real Incus idle-close behavior.
- Should long `Operation.wait/2` loops pin one connection for the whole wait instead of checking out per poll? Deferred until measurements show checkout cost matters.
