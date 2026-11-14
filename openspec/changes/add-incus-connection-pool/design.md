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
 name: MyHost.IncusPool, max_bindings: 64, size: 4, idle_timeout: 15_000,
 max_connection_age: 60_000}
```

It starts a manager that admits and owns linked per-binding NimblePool processes. The manager owns the private digest-to-PID map and shuts down its children when it stops. Every limit is a validated bounded integer. The initial default maximum connection age is 60 seconds. Record establishment time on connect and retire over-age sockets on checkout and on return, including under sustained use. Idle eviction uses time since the last return.

Each binding's NimblePool is `lazy: true` with synchronous empty slots. Periodic idle checks remove expired sockets. The manager stops an empty binding after `idle_timeout` once admission and checkout accounting confirm that no lease is active. Associate expiry with the specific binding process so a late expiry cannot stop its replacement. Document the maximum eviction delay from the sweep interval.

### 2. The binding key

A pool's key is a SHA-256 digest of the connection `owner`, the transport, the normalized address (socket path, or scheme, host and port), `require_authenticated`, and for HTTPS the bytes of the client certificate, the private key and the CA bundle when present, together with any pinned fingerprint. This follows `EventListener.backend_binding/1`, which already treats owner, transport, address and TLS as the backend binding, but digests file contents instead of paths, because paths can be rotated in place. Including `owner` keeps socket sharing inside the boundary `Context.authorize/2` enforces, even when two owners use identical credentials.

`:ssl` may serve `certfile`/`keyfile` from its PEM cache. After authorization, the request worker takes a bounded snapshot of the certificate chain, key and optional CA bundle. Derive the binding and the in-memory handshake options from that snapshot, preserving OTP's chain handling and the existing hostname, CA and pin checks. A fresh connection eligible for return uses those same options. An invalid or mismatched snapshot fails as a connection error before dispatch. Connections without `pool:` retain the existing TLS options. Rotating material creates a new binding, and old sockets age out. Keep snapshots in the request worker and use redacted errors.

Project, member, request context, timeouts, budgets and `Context` identity apply per request. `Context.authorize/2`, including the host's `ready?` check, still runs before any checkout. Binding processes are addressed by PID. The manager redacts its status and keeps the digest out of diagnostics.

### 3. Reads reuse, mutations do not

The method decides the checkout:

| Method | With an idle pooled connection | Without one |
| --- | --- | --- |
| GET, HEAD | Reuse, after validation | Open fresh |
| Any other | Never reused; open fresh | Open fresh |

Return a socket only after a complete, non-upgraded response with no close directive, an open Mint connection, no outstanding request, and a slot available. The receive loop hands back the final Mint state on success. Any I/O, framing, budget or cancellation failure discards the socket. An eligible fresh mutation socket may later serve a read. Mutations acquire a slot only when offering a completed connection.

This keeps failure classification unchanged. A mutation's connect failure is still `:connection`, and a failure after the connection opened is still `:uncertain`. Reusing pooled sockets for mutations would turn a server's idle close, racing with our write, into a spurious `:uncertain` with no way to tell it from a real lost response. Reads stay safe to classify: a stale-socket failure on a reused GET is reported with its existing kind, normally `:response_closed`, and is never retried by the library. The caller sees one failed read, as it can today, and host code that already treats `:response_closed` reads as recoverable, such as the gateway acceptance host's bounded metadata-read recovery, keeps that choice.

### 4. Reuse validation

After checkout, the request worker checks connection age and `Mint.HTTP.open?/1`, then runs `Mint.HTTP.recv(conn, 0, 0)`. An empty timeout on an open connection permits reuse. Close, received bytes or events, and other errors discard the connection. Try another idle socket only within the same acquisition budget. On a miss, open a fresh connection before any request has been sent.

A reused socket still carries the `send_timeout` set when it was opened. Before writing, the worker resets `send_timeout` on the underlying socket to the current request's remaining deadline. If that fails, the connection is discarded and the request opens a fresh one. Receive deadlines are already passed per `recv/3` call.

### 5. No queueing, no I/O in the pool

The bounded request worker performs handshakes, probes, writes and reads. Pool callbacks manage state, ownership transfers and teardown. NimblePool queues on saturation by default. Reject saturation in the binding's `handle_enqueue/2` before entering its queue. Use a per-binding count of slots reserved for checkouts, including handoffs. Release each reservation once on check-in, cancellation or checkout failure. Ensure a stale or rejected socket leaves an available empty slot or ends the checkout, so it cannot cause a reserved checkout to queue.

Use a five-millisecond acquisition budget capped by the current request deadline across lookup, admission, checkout and pre-send validation. A missing, blocked or saturated pool yields a miss before dispatch. Binding startup only initializes local state and is subject to that caller budget. Cap binding count and never evict an active binding. After dispatch, the result depends only on the request, including when a return fails.

### 6. Ownership and kills

The binding process owns idle sockets. Checkout transfers a passive socket to the bounded request worker using `Mint.HTTP.controlling_process/2`. The worker owns it during all request I/O, so a guard or `WorkScope` kill closes it. Before transferring a finished socket back, register it as a pending return under the checkout reference. The pool acknowledges registration before transfer. Only a matching successful check-in makes the socket available. If the worker dies during the handoff, the pool discards the registered socket if ownership transferred. The worker closes it on failed transfer while it still owns it. Keep every handoff bound by the request deadline.

Stopping the pool closes idle sockets and releases pending returns. A read already owned by its request worker can finish under its original deadline. Its socket closes on completion if the pool has stopped. Local shutdown sends no backend cancellation and never replays the request. Verify each transition with fixture barriers and socket close observations.

### 7. Dependency

`{:nimble_pool, "~> 1.1", optional: true, runtime: false}` keeps its OTP application out of automatic startup. NimblePool's application callback starts a task supervisor, which synchronous slots do not need. The full consumer opts in with the same runtime setting and starts only the host pool child. Compile `ConnectionPool` only when NimblePool is available. Requesting `pool:` when the module is unavailable raises `ArgumentError` at passive construction.

### 8. Surfaces that stay unpooled

- **Gateway relays.** `HTTPRelay`, `WebSocketRelay` and `RawRelay` open their backend through `Transport.open/2`, stream in active-once mode, relay caller-chosen methods, and close their backend socket when a lease expiry, revocation or owner loss interrupts the exchange. The documented gateway contract is one new backend connection per exchange, never pooled, retried or redirected. Pooling there would mix relay ownership with pool ownership and gain little, because each exchange already holds its socket for its whole life. Relays ignore `pool:`.
- **Streams and channels.** `Transfer`, SimpleStreams downloads, `ExecRun`, `ExecOutput`, `WebSocket`, `RawChannel`, SFTP, NBD, `EventListener` and `DynamicConsole` keep their own connection for the stream's life. Upgrades take over their socket.
- **Host adapters.** OCI registry access and SimpleStreams delta conversion run in host adapters and are outside the library's transport.

### 9. Baseline and adoption

Use operator-supplied bindings for one isolated project on the same Incus daemon. Verify the intended project and server identity before sampling. Use a bounded sequential workload with matching request counts, warm-up and timeouts across transports. Time discovery and a shared inspection from their public entry points. For polling, use a pre-existing operation in that project and measure individual GETs so changes in operation execution time do not dominate the comparison. Record the Incus and OTP versions, request counts, p50/p95 latency and error counts by workload. Count TLS connections and observed resumptions separately. Sample Incus CPU over the same workload windows when the host can provide it.

Compare the complete client cost, including credential-file handling. A Unix-only run can establish that leg of the baseline. The decision to implement depends on measured verified HTTPS behavior, which is the target workload. Repeat against the same isolated backend after pooling and include idle-close errors in the comparison.

Both PR #69 executors receive their connection from the host. Verify pooled behavior through the executors after their existing authorization checks. The generated documents and the release cassette have no connection or pool settings.

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

OTP `:ssl` can resume TLS 1.3 sessions with client session tickets. Benchmark this in a separate run with verified HTTPS and measure whether handshakes actually resume. Record unsupported or unobserved resumption explicitly. The benchmark does not change application TLS defaults.

## Risks / Trade-offs

- **Server idle close.** An Incus server may close idle keep-alive connections sooner than `idle_timeout`. The probe in decision 4 catches most cases. The remaining race only affects reads, which fail visibly as `:response_closed` without retry. Hosts may see that kind more often than today.
- **Stale trust.** Trust and credential rotation change the binding before checkout. Idle expiry and the absolute age cap retire sockets when files are unchanged. Hosts can remove admission immediately and stop the pool to release its idle sockets.
- **More open sockets.** Up to `max_bindings * size` idle sockets per node. All are bounded and closed on idle or pool stop. On a relayed Unix socket, such as Macus's guest relay, idle sockets also hold relay resources.
- **Per-request snapshot.** Reading and hashing client credentials may offset some handshake savings. Include this cost in the pooled comparison.

## Open Questions

- Should hosts be able to opt mutations into reuse for bindings they consider safe? Deferred. It changes `:uncertain` frequency and needs evidence from real Incus idle-close behavior.
- Should long `Operation.wait/2` loops pin one connection for the whole wait instead of checking out per poll? Deferred until measurements show checkout cost matters.
