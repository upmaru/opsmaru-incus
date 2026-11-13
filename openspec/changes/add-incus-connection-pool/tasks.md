# Tasks

Pool evidence never changes a `priv/incus/coverage.json` entry, completion record or acceptance gate. The first implementation slice covers verified HTTPS buffered reads.

## 1. Measure the existing transport

- [ ] 1.1 Against an explicitly opted-in isolated Incus project, measure a buffered GET, `Incus.connect/2` discovery, repeated polls against an operator-supplied operation, and a shared inspection with a host binding that supplies a connection and context. Compare Unix, verified HTTPS with full handshakes, and verified HTTPS with observed TLS 1.3 resumption when supported. Use the same endpoints, workloads, warm-up and sample counts across runs. Record p50/p95 latency, connection and handshake counts, errors and Incus CPU if the isolated host supplies it. Record unavailable measurements and the decision on proceeding. Use supplied bindings and existing project data for the timed requests. Keep the gate open until there is a verified HTTPS baseline.

The paired baseline in [real Incus acceptance](../../../docs/real-incus-acceptance.md)
establishes the verified HTTPS gate and supports proceeding with the HTTPS
slice. Operation polling, observed TLS resumption and Incus CPU remain open.

## 2. Verified HTTPS buffered reads

- [x] 2.1 Add `{:nimble_pool, "~> 1.1", optional: true, runtime: false}` and a host-started child spec with validated binding, slot, idle and age limits. Verify passive startup with NimblePool installed and absent. Add the passive `pool:` option, verify it survives context and selection updates, and document host opt-in in `docs/incus-client.md`.
- [x] 2.2 Take a bounded credential and trust snapshot after authorization. Derive the digest and in-memory handshake options from it. Verify owner, address, `require_authenticated`, client chain/key, CA and pin isolation, rotated credentials as observed by the peer, failure on an invalid snapshot, and redacted diagnostics. Prove unready and mismatched hosts perform no checkout or backend I/O.
- [ ] 2.3 Implement synchronous admission and handoff in the buffered Mint worker. Assert saturated calls never enter NimblePool's resource queue, stopped or blocked pools and exhausted binding limits fall back before dispatch, and late replies cannot transfer an untracked socket. Cap acquisition by one shared budget. Test worker death, cancellation, owner loss and `WorkScope` shutdown at both handoffs, including death after transfer and before check-in.
- [ ] 2.4 Verify GET and HEAD reuse over verified HTTPS by counting accepted sockets. Use the final Mint state for check-in. Cover server close, half-close, stray data, response limits, incomplete responses, upgrades and the current send and receive deadline. Assert a close after dispatch is reported once with the existing error kind and no replay.
- [ ] 2.5 Verify idle, age and empty-binding eviction with fixture barriers, including repeated reads across the age cap and stale expiry after a binding restarts. Stop the pool with one idle and one checked-out socket. Verify idle close, completion of the in-flight read within its existing deadline, close on completion and a fresh next request. Document shutdown and eviction behavior.

The HTTPS implementation and focused fixtures cover saturation, blocked
bindings, owner loss, request cancellation, work scope termination, an
abandoned return, stale sockets, response limits, age and idle eviction.
The unchecked tasks retain their remaining verification scenarios.

## 3. Remaining buffered call sites and mutations

- [ ] 3.1 Add Unix buffered reuse with the same admission and ownership rules. Verify reuse through the existing shared inspection executor, HTTP and OCI passive handles, and SimpleStreams catalog requests. Verify project/member selection, request context and response budgets apply per request and preserve native queries, ETags, results and operation identities.
- [ ] 3.2 Keep every non-GET/HEAD request on a fresh connection. Return eligible completed sockets for later reads. Verify fresh-connect failure remains `:connection`, lost mutation responses remain `:uncertain`, and each dispatched mutation appears once under cancellation, deadline and response loss. A failed pool return must preserve the completed result.
- [ ] 3.3 Verify gateway HTTP, WebSocket and raw relays, transfers, SimpleStreams downloads, exec, events, consoles, and raw/SFTP/NBD channels open their own sockets even when their binding carries `pool:`. Confirm the per-exchange rule in `docs/gateway.md`.

## 4. Integration and acceptance

- [ ] 4.1 When PR #69's executors are available, verify a pooled host binding through both `Operations.Composite.run/3` and `Operations.Native.run/3`. Prove denied calls never touch the pool or backend, allowed reads reuse, and mutations use fresh sockets. The pool can be delivered before that combined check, which belongs on the first revision containing both changes.
- [ ] 4.2 Run `mise run check`, `mise run check:reference` and `mise run check:consumer` from a clean immutable feature revision. Verify the full extracted Hex consumer starts the pool explicitly and the client-only consumer compiles without NimblePool. Preserve the coverage ledger.
- [ ] 4.3 Repeat the task 1.1 measurements with pooling against the same isolated real backend, including server-side idle close. Record benefit, errors and handshake count separately from fixture, consumer and Macus hardware acceptance.

The [HTTPS pool comparison](../../../docs/real-incus-acceptance.md#https-pool-comparison-on-2026-11-13)
records steady-state pool-off and pool-on latency, errors and connection counts
against the isolated Incus project. The server-side idle-close live scenario is pending.
