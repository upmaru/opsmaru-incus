# Design

## Context

See [proposal.md](proposal.md). `Transport.request/5` runs `do_request/5` inside a `Transport.bounded/4` worker. The worker opens a passive HTTP/1.1 Mint connection (`Transport.open/2`), sends one request, reads the full response under header and body byte limits, and closes the socket in an `after` clause. An independent guard kills the worker on deadline, cancellation or owner loss. `failed/2` reports any failure of a non-GET/HEAD request after a connection opened as `:uncertain`. A connect failure is reported as `:connection`, because no request bytes could have left.

`Connection.tls_options/1` reads the client certificate, key and CA bundle on every connect, deliberately avoiding OTP's shared trust-file cache, and may add a pinned-fingerprint `verify_fun`. Connections carry no pool, and `Opsmaru.Incus.disconnect/1` is a no-op.

## Goals / Non-Goals

**Goals:** fewer HTTPS handshakes for reads and operation polls; a pool the host starts, sizes and stops; strict separation of credentials and trust; unchanged wire behavior and failure classification; no queueing and no new failure modes for callers that do not opt in.

**Non-Goals:** HTTP/2 or multiplexing, request retries, pooling of streams or upgrades, reuse for mutations, shared pools across hosts or nodes, health checking of Incus servers, automatic pool creation on dependency load, and changes to `Context` authorization.

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

A pool's key is a SHA-256 digest of the transport, the normalized address (socket path, or scheme, host and port), `require_authenticated`, and for HTTPS the bytes of the client certificate, the private key and the CA bundle together with any pinned fingerprint. The worker computes the digest from the same files `tls_options/1` already reads, once per request, before checkout. The cost is the same file reads as today, and rotated material produces a new key without host action. Old bindings idle out.

Project, member, request context, timeouts, host identity and `Context` are not in the key. They do not affect the TLS session or the socket. They are applied per request exactly as today, and `Context.authorize/2` still runs before any checkout. The digest and key never appear in `Inspect`, errors, telemetry or the `Registry` name. Registry entries use an opaque reference that maps to the digest inside the manager.

### 3. Reads reuse, mutations do not

The method decides the checkout:

| Method | With an idle pooled connection | Without one |
| --- | --- | --- |
| GET, HEAD | Reuse, after validation | Open fresh |
| Any other | Never reused; open fresh | Open fresh |

After any request whose response completed cleanly, the connection is offered back to its binding's pool if all of these hold: the response did not carry `connection: close`, the request was not upgraded, `Mint.HTTP.open?/1` is true, and the pool is below `size`. Otherwise it is closed. A fresh connection opened for a mutation can therefore later serve a read, but a mutation never travels over a socket that has sat idle.

This keeps failure classification unchanged. A mutation's connect failure is still `:connection`, and a failure after the connection opened is still `:uncertain`. Reusing pooled sockets for mutations would turn a server's idle close, racing with our write, into a spurious `:uncertain` with no way to tell it from a real lost response. Reads stay safe to classify: a stale-socket failure on a reused GET is reported with its existing local kind and is never retried by the library, so the caller sees one failed read, as it can today.

### 4. Reuse validation

Before handing out an idle connection, the pool checks that `Mint.HTTP.open?/1` is true. It then performs a non-blocking `Mint.HTTP.recv(conn, 0, 0)`. A closed socket, unexpected bytes or any error discards the connection, and the next idle one is tried. When none passes, the request opens a fresh connection. Idle passive sockets have no reader, so this probe is how a server-side close or stray data is detected before reuse.

### 5. No queueing, no I/O in the pool

The pool never performs a handshake. NimblePool's `init_worker/1` returns an empty slot and never connects. Fresh connections are opened by the request's bounded worker, outside the pool, and offered back at check-in. Checkout uses a short fixed bound (single-digit milliseconds, set in implementation and documented). If no idle connection is available within it, the worker proceeds with a fresh connection. A slow pool or a dead binding therefore degrades to today's behavior and never blocks a request or adds a failure.

When `max_bindings` is reached, new bindings are not admitted and their requests run unpooled. The pool never evicts an active binding.

### 6. Ownership and kills

Checkout transfers the socket to the bounded worker with `Mint.HTTP.controlling_process/2`. Check-in transfers it back. If the guard kills the worker mid-request, NimblePool sees the client go down and removes that worker, closing the socket in `terminate_worker/3`. A partially read response is never returned to the pool. A worker killed after check-in has nothing to lose. Pool processes trap no caller exits and hold no caller references beyond NimblePool's own monitors.

### 7. Dependency

`{:nimble_pool, "~> 1.1"}` is small, depends only on Elixir, and starts no application processes. Declaring it `optional: true` would let client-only consumers skip it, at the cost of compiling `ConnectionPool` conditionally. The proposal keeps it required: it is inert unless the host starts the pool. This is revisited if a consumer objects.

## Alternatives Considered

### Finch (rejected)

Finch 0.23 is the standard Mint pool and is built on NimblePool. It supports Unix sockets, tags pools, and does not retry requests on its own. It does not fit here:

- **Credentials are fixed at start.** Finch keys pools by scheme, host, port and an optional tag, and takes TLS options from the `pools:` map at `Finch.start_link/1` or from a single `:default` entry. Central Opsmaru registers HTTPS targets at runtime, each with its own client certificate. That forces either one Finch instance per target, which the host would have to supervise dynamically, or a tag scheme kept outside Finch so that different credentials never share a pool keyed by host.
- **There is no reuse policy per method.** Finch reuses any idle connection for any method. Restricting mutations to fresh sockets would require a parallel tag per binding.
- **Response guards move.** The library's header byte budget, body limit and absolute deadline are enforced in `receive_response/5`. With Finch they would need to be re-implemented through `Finch.stream_while/5` callbacks, and the deadline would be split between Finch's `receive_timeout` and `request_timeout`.
- **It adds dependencies.** Finch requires `:telemetry`, `nimble_options` and `mime`, which works against keeping `:telemetry` optional in `add-incus-telemetry`.
- **It does not cover upgrades.** Channels would stay on direct Mint anyway, leaving two transport stacks.

Using NimblePool directly keeps the existing transport, framing and failure code as the single implementation and adds only reuse.

### TLS session resumption without a pool

OTP `:ssl` can resume TLS 1.3 sessions with client session tickets. This skips certificate verification on reconnect but still costs a TCP round trip and part of a handshake, and resumption state lives in OTP's shared session cache, against the per-connection trust handling in `tls_options/1`. It is measured as a baseline in task 1.1, not adopted.

## Risks / Trade-offs

- **Server idle close.** An Incus server may close idle keep-alive connections sooner than `idle_timeout`. The probe in decision 4 catches most cases. The remaining race only affects reads, which fail visibly without retry.
- **Stale trust.** A connection verified against an old CA or pinned fingerprint keeps serving its binding until it idles out. Rotation creates a new binding immediately. Hosts that must revoke trust instantly can stop and restart the pool.
- **More open sockets.** Up to `max_bindings * size` idle sockets per node. All are bounded and closed on idle or pool stop.
- **Per-request digest.** Hashing certificate, key and CA bytes costs microseconds, small next to the file reads already done per request.

## Open Questions

- Should hosts be able to opt mutations into reuse for bindings they consider safe? Deferred. It changes `:uncertain` frequency and needs evidence from real Incus idle-close behavior.
- Should long `Operation.wait/2` loops pin one connection for the whole wait instead of checking out per poll? Deferred until measurements show checkout cost matters.
