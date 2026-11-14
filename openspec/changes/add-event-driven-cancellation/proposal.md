# Proposal

## Why

`RequestContext` is a plain value around one `:atomics` cell. Nothing is notified when it is cancelled, when its owner exits or when its deadline passes, so every process that must react polls. Request guards (`Transport.guard_until/5`), channel watchers (`Transport.watch_until/4`), `Operation.wait/2` (`sleep_until/2`) and host adapter calls (`OCI.AdapterCall.await_result/6`, used by OCI and SimpleStreams delta conversion) each wake every 20 ms while a context is attached, read the atomic and call `Process.alive?/1` on the context owner. `SFTP` always builds its own lifetime context and watcher, so every SFTP session polls even when the host passed none, and a session with a host context runs a second polling watcher.

The [macOS and Linux baseline](design.md#1-polling-baseline) measured roughly 106,000–115,000 cancellation-waiter scheduler entries per second for 1,000 idle listeners with a host context. SFTP also polled without a host context, at roughly 53,000–59,000 entries per second for 1,000 sessions. At that scale, explicit cancellation took 19–33 ms at p95 across the two channel workloads. Those fixture results justify proceeding.

## What Changes

- Prove a subscription, delivery and cleanup protocol before converting call sites. Keep the atomic authoritative for `status/1` and `check/1`, and keep construction free of processes, sockets and files.
- Replace the 20 ms context checks with cancellation notifications, context-owner monitors and waits until the effective absolute deadline. Preserve caller and worker monitors and native operation refreshes.
- Replace SFTP's private context with a session deadline and timer. Preserve the startup deadline from #29, lock waits and mutation uncertainty. Verify that `ExecRun` releases its private context after execution, including when it tightens the deadline.
- Repeat the baseline on both platforms and compare waiter scheduler entries, CPU and cancellation latency.

## Scope

Wait loops added or changed since this plan was first written were reviewed against current `develop`. Only loops that poll a `RequestContext` are in scope.

- **In.** `Transport.guard_until/5` and `watch_until/4`, `Operation.sleep_until/2`, `OCI.AdapterCall.await_result/6` (missed by the first draft; it predates it) and the SFTP lifetime context.
- **Covered without a new site.** Shared operation executors and SimpleStreams refresh and download reach the transport guard through `Transport.bounded/4`. When draft #69’s executors are ready, verify their binding and cancellation on the combined revisions. The gateway's WebSocket writer calls `Transport.watch_owner/2` without a context and must keep exactly today's monitor-only path.
- **Out: gateway revocation and expiry rechecks** (`Gateway.Lease`). They call the host's policy on a `recheck_interval` of at most 5 s; that is a documented host-policy bound, not context cancellation, and stays periodic.
- **Out: gateway WebSocket watchdog** (`min(left, 25)`). It reads an idle clock that relays update per frame; making it event-driven would need a message per frame.
- **Out: gateway WebSocket read** (`Mint.WebSocket.recv/3` with 20 ms). It is socket I/O multiplexing, not a cancellation wait.
- **Out: `NativeYaml` decode worker** (20 ms). It samples worker reductions to enforce a CPU budget within a 2 s decode, which cannot be event-driven.
- **Out: single-timer waits** (HTTP and raw relays, `RawChannel`, `WebSocket`, `DynamicConsole` lifetimes, `EventListener.wait/2`). They already use one timer, not a tick.

Gateway relays carry no `RequestContext`, so this change does not alter gateway behavior.

## Capabilities

### New Capabilities

- `incus-cancellation`: event-driven delivery of request-context cancellation, owner exit and deadline to request guards, channel watchers, operation waits and host adapter call waits, with unchanged status semantics and no polling.

### Modified Capabilities

None. The main specs (`incus-client`, `embedded-service`, `incus-operations`) state the outcomes of cancellation, deadline and owner loss, not how waiters learn of them. This change keeps those outcomes and adds delivery requirements.

## Impact

- Update the `RequestContext` lifecycle documentation and validation after the notification protocol is verified. Keep `Inspect` redacted.
- Touches `RequestContext`, `Transport` (guard and watcher), `Operation.wait/2`, `OCI.AdapterCall` and `SFTP`. Public function signatures, return values, error kinds and wire behavior are unchanged; cancellation becomes observable sooner.
- No new dependency. Process aliases need OTP 24 or later; the pinned OTP is 27.
- `priv/incus/coverage.json` and its completion records are unaffected. This change adds no typed-client evidence.
- `add-incus-telemetry` emits channel closure from the same owner watcher this change converts. Whichever lands second adapts to the other; neither modifies the other's plan.
- Verify the merged HTTPS pool from #29 under cancellation during checkout, while a request owns a socket, and as the socket returns to the pool.
