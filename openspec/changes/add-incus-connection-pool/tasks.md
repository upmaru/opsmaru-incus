# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Pool evidence never changes a `priv/incus/coverage.json` entry, completion record or acceptance gate.

## 1. Baseline and passive component

- [ ] 1.1 Measure per-request latency and backend CPU for buffered GETs, `Incus.connect/2` discovery, `Operation.wait/2` polls and a shared-operations inspection call over Unix and verified HTTPS, without pooling and with OTP TLS 1.3 session resumption, against an explicitly opted-in isolated Incus project; record the baseline and whether pooling's expected gain justifies continuing.
- [ ] 1.2 Add `{:nimble_pool, "~> 1.1", optional: true}` and the conditionally compiled `Opsmaru.Incus.ConnectionPool` child spec with validated bounded options; verify that loading and starting `:opsmaru_incus` starts no pool, registry, table or socket, that invalid options raise before start, and that stopping the pool closes only pooled sockets.
- [ ] 1.3 Add the passive `pool:` option to `Connection.unix!/2` and `Connection.https!/2`, kept by `with_context/2`, `project/2` and `member/2`; verify construction performs no I/O, `Inspect` stays redacted, `pool:` raises when `ConnectionPool` is not compiled, and connections without it take today's code path byte for byte.

## 2. Binding isolation

- [ ] 2.1 Implement the binding digest, pooled `cert`/`key` handshake bytes and opaque registry naming; verify that connections differing only in owner, client certificate, key, CA bundle, pinned fingerprint, address or `require_authenticated` never share a socket, that rotated files produce a new binding whose handshake presents the new certificate, and that the digest appears in no `Inspect`, error, registry name or log.
- [ ] 2.2 Verify that project, member, request context, timeouts and `Context` identity do not split pools, and that `Context.authorize/2`, including an unready host, still rejects a call before any checkout or connect.

## 3. Checkout, reuse and check-in

- [ ] 3.1 Implement method-based checkout and clean-response check-in in `Transport.request/5`; verify GET and HEAD reuse idle connections, every other method opens a fresh connection that may be returned afterwards, and 101, `connection: close`, errored, oversized or partially read responses are never returned.
- [ ] 3.2 Implement the open-and-probe reuse validation and per-request `send_timeout` reset; verify that server-closed, half-closed and stray-byte sockets are discarded before use, that a reused socket honors the current request's deadline rather than the one it was opened under, and that the request then succeeds on a fresh connection.
- [ ] 3.3 Implement the non-queueing checkout bound, empty `init_worker/1` and `max_bindings` admission; verify that a saturated binding, a blocked or killed pool process, and an exhausted binding limit each degrade to an unpooled request with today's result and no added failure kind.
- [ ] 3.4 Verify that every `Transport.open/2` caller (transfers, SimpleStreams downloads, exec, WebSocket, raw, SFTP, NBD, event listener, dynamic console and the gateway HTTP, WebSocket and raw relays) opens one fresh connection per stream or exchange when its connection carries `pool:`, and that pooled SimpleStreams catalog, `HTTP.request/4` and shared-operations reads reuse sockets while their mutations do not.

## 4. Failure semantics and lifecycle

- [ ] 4.1 Verify that mutations keep today's classification: `:connection` before the request is written, `:uncertain` after, a single request on the wire, and no retry under deadline, cancellation, owner loss, `WorkScope` termination or response loss.
- [ ] 4.2 Verify that a guard-killed or scope-killed worker removes its checked-out connection, that no partially read socket re-enters the pool, and that a stale-socket failure on a reused GET is reported once with its existing kind (`:response_closed` for a close before any parsed response) and not retried.
- [ ] 4.3 Implement idle removal through `handle_ping/2` and manager-driven termination of empty lazy binding pools; verify that sockets and binding pools close within the documented bound after `idle_timeout`.

## 5. Documentation and acceptance

- [ ] 5.1 Document the pool, its options, the reads-only reuse rule and the unpooled surfaces in `docs/incus-client.md`, and confirm `docs/gateway.md` still states that relays never pool.
- [ ] 5.2 Repeat the 1.1 measurements with pooling against the same isolated real Incus project, including server-side idle close, and record a separate pool report without claiming Macus or hardware acceptance.
- [ ] 5.3 Extend the isolated consumer check so the full consumer starts the pool in its host tree and the client-only consumer compiles without NimblePool and never starts it; verify both from a pushed immutable revision with `mise run check:consumer`.
- [ ] 5.4 Run `mise run check` and `mise run check:reference`.
