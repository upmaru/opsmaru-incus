# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Pool evidence never closes foundation task 3.9 or any `priv/incus/coverage.json` entry.

## 1. Baseline and passive component

- [ ] 1.1 Measure per-request latency and backend CPU for buffered GETs and `Operation.wait/2` polls over Unix and verified HTTPS, without pooling and with OTP TLS 1.3 session resumption, against an explicitly opted-in isolated Incus project; record the baseline and whether pooling's expected gain justifies continuing.
- [ ] 1.2 Add `{:nimble_pool, "~> 1.1"}` and the `Opsmaru.Incus.ConnectionPool` child spec with validated bounded options; verify that loading and starting `:opsmaru_incus` starts no pool, registry, table or socket, that invalid options raise before start, and that stopping the pool closes only pooled sockets.
- [ ] 1.3 Add the passive `pool:` option to `Connection.unix!/2` and `Connection.https!/2`; verify construction performs no I/O, `Inspect` stays redacted, and connections without it take today's code path byte for byte.

## 2. Binding isolation

- [ ] 2.1 Implement the binding digest and opaque registry naming; verify that connections differing only in client certificate, key, CA bundle, pinned fingerprint, address or `require_authenticated` never share a socket, that rotated files produce a new binding, and that the digest appears in no `Inspect`, error, registry name or log.
- [ ] 2.2 Verify that project, member, request context and `Context` do not split pools, and that `Context.authorize/2` still rejects an unauthorized call before any checkout or connect.

## 3. Checkout, reuse and check-in

- [ ] 3.1 Implement method-based checkout and clean-response check-in; verify GET and HEAD reuse idle connections, every other method opens a fresh connection that may be returned afterwards, and upgraded, `connection: close`, errored, oversized or partially read responses are never returned.
- [ ] 3.2 Implement the open-and-probe reuse validation; verify that server-closed, half-closed and stray-byte sockets are discarded before use and that the request then succeeds on a fresh connection.
- [ ] 3.3 Implement the non-queueing checkout bound, async-free empty `init_worker/1` and `max_bindings` admission; verify that a saturated binding, a blocked or killed pool process, and an exhausted binding limit each degrade to an unpooled request with today's result and no added failure kind.

## 4. Failure semantics and lifecycle

- [ ] 4.1 Verify that mutations keep today's classification: `:connection` before the request is written, `:uncertain` after, a single request on the wire, and no retry under deadline, cancellation, owner loss or response loss.
- [ ] 4.2 Verify that a guard-killed worker removes its checked-out connection, that no partially read socket re-enters the pool, and that a stale-socket failure on a reused GET is reported once and not retried.
- [ ] 4.3 Implement idle removal through `handle_ping/2` and manager-driven termination of empty lazy binding pools; verify that sockets and binding pools close within the documented bound after `idle_timeout`.

## 5. Acceptance

- [ ] 5.1 Repeat the 1.1 measurements with pooling against the same isolated real Incus project, including server-side idle close, and record a separate pool report without claiming Macus or hardware acceptance.
- [ ] 5.2 Extend the isolated consumer check to start the pool in a host tree and to build a consumer that never starts it; verify both from a pushed immutable revision with `mise run check:consumer`.
- [ ] 5.3 Run `mise run check` and `mise run check:reference`.
