# Design

## Context

See [proposal.md](proposal.md). `RequestContext.new!/1` validates a finite timeout and a local owner and returns `%RequestContext{owner, deadline, cancelled}`, where `cancelled` is a one-slot `:atomics` array: `0` active, `1` cancelled, `2` deadline. `cancel/1` compare-and-exchanges `0` to `1` (or to `2` if the deadline already passed). `status/1` reads the slot and, while it is `0`, also checks the deadline and `Process.alive?(owner)`, recording either result with the same compare-and-exchange.

Four loops call `status/1` on a 20 ms tick when a context is present:

| Site | Process | Duration |
| --- | --- | --- |
| `Transport.guard_until/5` | one guard per bounded request | the request |
| `Transport.watch_until/4` | one watcher per channel (`WebSocket`, `RawChannel`, `SFTP`, `DynamicConsole`, `EventListener`) | the channel's life |
| `Operation.sleep_until/2` | the caller | each gap between polls (`poll_interval`, default 50 ms) |
| `OCI.AdapterCall.await_result/6` | one controller per OCI or SimpleStreams delta adapter call | the host callback |

The guard, watcher and adapter controller already monitor their worker or channel and its caller, so caller death is event-driven today. The context owner can differ from the caller (`owner:` option), and that is the only reason `Process.alive?/1` is polled. `SFTP.lifetime/1` creates a private context from `stream_timeout` for every session and watches it, plus a second watcher when the host supplied a context. `ExecRun` creates one private context per execution, copies it with the host context's tighter deadline (the copy shares the atomic) and cancels it in its `after` clause.

The proposal's Scope section lists the newer wait loops (gateway lease rechecks and watchdog, WebSocket relay reads, `NativeYaml` decoding, single-timer lifetimes) and why each stays as it is.

## Goals / Non-Goals

**Goals:** no periodic wakeups while waiting on a context; cancellation, owner exit and deadline observed as soon as the BEAM delivers them; identical `status/1`, `check/1` and error classification; contexts remain values with no process.

**Non-Goals:** backend cancellation (local cancellation still never sends a `DELETE`), cancellation across nodes, changes to deadlines or default timeouts, propagating a host context's cancellation into library-internal contexts beyond what happens today, changes to `WorkScope`, and changes to gateway recheck, idle or lifetime timing.

## Decisions

### 1. Polling baseline

Measured at `f0b367bd527020e818f8f72b09d0bafc11d75a91`, based on `develop` at `be1f2986e7dcff7e5c5a9b25c0d149e0d7dc76fd` with #29 merged. Both runs used Elixir 1.19.5, OTP 27.3.4.16, four normal schedulers, two dirty CPU and two dirty I/O schedulers, and an 8,192 file-descriptor limit on the same ARM64 Mac. The macOS run was native on 27.0.1. The Linux run used an offline arm64 OrbStack container with kernel `7.2.9-orbstack-00391-g2b298d05fbd4`.

Three rounds exercised the existing client against disposable Unix-socket fixtures. The WebSocket fixture upgraded and sent no frames. The SFTP peer answered the version negotiation and stayed idle. The operation fixture returned one running status before a 60-second refresh gap. The OCI adapter callback signaled readiness and blocked. Each with-context trial shared one host context across its channels.

After 140 ms of settling, sample BEAM process CPU and normal-scheduler active wall time for roughly one second. Count schedule-ins of the context waiters in a separate ~550 ms traced window. Waiter entries count BEAM scheduler events. The active time and CPU include the fixture peers and independent listener I/O. Compare workload changes within each OS because Linux guest overhead and variance differ from native macOS.

After a seeded 1–45 ms delay, measure from the start of `RequestContext.cancel/1` until the caller observes each channel exit or wait result. The channel measurement includes observations in the caller's mailbox. Every scoped case checked its cancellation result, and adapter cases checked cleanup. Each row shows medians across three trials for the idle metrics. Cancellation percentiles pool all observations for that row. The operation and adapter rows each have three cancellation samples per platform.

#### macOS

| Fixture | Count | Host context | Waiter entries/s | One core % | Active scheduler ms/s | Cancel p50 / p95 / max (ms) |
|---|---:|---|---:|---:|---:|---:|
| control | 0 | no | 0 | 0.003 | 1.08 | — |
| event | 1 | no | 0 | 0.007 | 2.16 | — |
| event | 1 | yes | 98 | 0.015 | 1.34 | 18.00/19.14/19.14 |
| event | 100 | no | 0 | 0.036 | 6.39 | — |
| event | 100 | yes | 10,916 | 0.141 | 19.69 | 13.05/20.95/20.99 |
| event | 1000 | no | 0 | 0.232 | 46.86 | — |
| event | 1000 | yes | 114,702 | 1.081 | 222.39 | 10.13/19.39/21.18 |
| sftp | 1 | no | 49 | 0.006 | 0.93 | — |
| sftp | 1 | yes | 147 | 0.012 | 1.25 | 15.45/18.02/18.02 |
| sftp | 100 | no | 5,270 | 0.097 | 5.83 | — |
| sftp | 100 | yes | 16,518 | 0.099 | 14.60 | 8.00/19.82/20.88 |
| sftp | 1000 | no | 58,576 | 0.290 | 54.07 | — |
| sftp | 1000 | yes | 179,423 | 0.809 | 153.86 | 12.11/20.26/20.99 |
| operation | 1 | no | 0 | 0.003 | 0.84 | — |
| operation | 1 | yes | 49 | 0.007 | 1.07 | 16.04/19.00/19.00 |
| adapter | 1 | no | 0 | 0.003 | 1.02 | — |
| adapter | 1 | yes | 49 | 0.007 | 1.25 | 16.11/18.02/18.02 |

#### Linux

| Fixture | Count | Host context | Waiter entries/s | One core % | Active scheduler ms/s | Cancel p50 / p95 / max (ms) |
|---|---:|---|---:|---:|---:|---:|
| control | 0 | no | 0 | 0.097 | 1.07 | — |
| event | 1 | no | 0 | 0.240 | 1.81 | — |
| event | 1 | yes | 87 | 0.554 | 3.69 | 14.36/23.18/23.18 |
| event | 100 | no | 0 | 1.437 | 7.67 | — |
| event | 100 | yes | 10,059 | 4.749 | 17.48 | 8.19/16.57/20.80 |
| event | 1000 | no | 0 | 12.307 | 79.64 | — |
| event | 1000 | yes | 106,150 | 29.078 | 212.70 | 19.31/28.70/32.92 |
| sftp | 1 | no | 43 | 0.420 | 1.47 | — |
| sftp | 1 | yes | 130 | 0.389 | 1.69 | 1.58/13.64/13.64 |
| sftp | 100 | no | 4,856 | 3.738 | 9.08 | — |
| sftp | 100 | yes | 15,321 | 5.038 | 17.23 | 12.42/18.25/23.31 |
| sftp | 1000 | no | 53,256 | 11.910 | 58.14 | — |
| sftp | 1000 | yes | 168,123 | 30.807 | 261.20 | 18.77/33.23/34.56 |
| operation | 1 | no | 0 | 0.102 | 0.94 | — |
| operation | 1 | yes | 42 | 0.441 | 1.39 | 5.87/17.27/17.27 |
| adapter | 1 | no | 0 | 0.144 | 1.71 | — |
| adapter | 1 | yes | 43 | 0.446 | 1.92 | 16.39/18.33/18.33 |

At 100 channels with a host context, the waiters account for roughly 10,000–16,500 entries per second. At 1,000 channels, the rate exceeds 100,000 per second with a host context, and SFTP's internal context also drives polling without one. These fixture results and the measured cancellation latency satisfy the baseline gate. The same workload and measurements will be used after implementation. They provide fixture evidence only.

### 2. Subscription and delivery protocol

`RequestContext.new!/1` still allocates only the atomic. The first subscription starts one local, unlinked notifier on demand. It owns in-memory subscription records and monitors the context owner and each waiter. It drops a context's records on terminal delivery, owner exit or the last waiter leaving, and stops when empty. The creator has no role in subscription lifetime. A context that never has a waiter never allocates subscription resources.

The atomic remains authoritative. An additional active value marks that the first subscriber claimed the cell. A terminal transition races this claim with compare-and-exchange. For an unclaimed cell, the transition is a direct compare-and-exchange. For a claimed cell, the notifier serializes the transition with registrations and writes the terminal state itself. Each subscriber rechecks status after registration. Removing the last subscription releases the claim if the cell is still active.

The notifier replies to a cancellation once it commits the atomic, then sends the notification to each subscriber in a continuation. Canceller exit after its message reaches the notifier cannot interrupt that work. Subscribers monitor the notifier with a process alias. If the notifier itself dies before or during delivery, the monitor wakes all of its subscribers, including any that already received a notification. Waiters recheck the atomic and consume one terminal outcome. When the cell is still active after notifier loss, waiters register with a replacement using their original absolute deadlines. An owner-exit notification is also a wakeup to evaluate current status, so it preserves deadline precedence on a still-active cell.

On teardown, demonitoring with `:flush` deactivates the alias and removes its `:DOWN`. The waiter selectively drains any notification already in its mailbox, then removes its subscription from the notifier. Waiter death also removes the subscription. An already-queued notification and a late delivery attempt are covered by deterministic barriers, along with both creator/owner exit orders and the notifier's loss immediately after committing and partway through fanout.

The notifier runs no host callbacks. Registration and subscribed terminal transitions serialize through its mailbox. A follow-up benchmark will measure the cost of registration, teardown and cancellation fanout. See the [process alias delivery semantics](https://www.erlang.org/doc/system/ref_man_processes.html#process-aliases).

### 3. Owner exit and deadline without polling

Use a context-owner monitor and preserve existing caller and worker monitoring. Where one process plays both roles, preserve the existing outcome and channel grace rules for the shared `:DOWN`. Resolve cancellation, owner exit and deadline through the existing status rules. An active context checks its absolute deadline before owner liveness. Explicit cancellation chooses its terminal kind at the point of cancellation, and a recorded terminal kind persists.

Bound each receive by the earlier of the wait's own deadline and the context deadline. An earlier request timeout or next operation refresh does not change a longer-lived shared context. The internal `ExecRun` deadline-tightened copy continues to share its private terminal state. Waiters with no context use their existing monitors and local deadlines.

### 4. Transport guards and pooled HTTPS reads

Convert `Transport.guard_until/5` and `watch_until/4` after proving the subscription protocol. Preserve worker termination and current error classification, the channel watcher's 100 ms caller-exit grace, and the monitor-only path for the gateway's context-free WebSocket writer.

For #29's pool, test cancellation at three points using deterministic fixture barriers. Cancel a read queued for checkout, a read whose worker owns a socket, and a read handing ownership back. Verify worker and socket cleanup, the next read's ability to use the shared pool, and the behavior of unpooled reads. Preserve existing replay rules and the outcome of possibly accepted mutations.

### 5. Operation and adapter waits

`Operation.sleep_until/2` waits for a context event or the next native refresh, capped by the wait deadline. Verify the local wait's result and mailbox cleanup when cancellation races refresh, timeout or return. The refresh cadence and explicit native cancellation API keep their current behavior.

`OCI.AdapterCall.await_result/6` waits for callback completion, worker or caller exit, context events or the call deadline. Preserve the existing error kinds and exactly-once cleanup for both OCI and SimpleStreams delta conversion. Validate the shared native executors on a combined revision once #69 is ready.

### 6. Internal contexts

Replace SFTP's private lifetime context with an absolute deadline and a session timer. Carry #29's startup deadline across the upgrade and version handshake. Preserve stream expiry, lock waits, owner loss, error classification and dispatched mutation uncertainty. Expiring the local SFTP session leaves a longer-lived host context active. Only the host context uses a context watcher.

Verify `ExecRun` releases the resources associated with its private context on return, including its deadline-tightened copy. Preserve exec output limits, native results and uncertainty reporting.

## Risks and trade-offs

- A notification substrate can add per-context memory or per-waiter work. Measure construction and cleanup and document the lifetime of contexts with and without waiters before converting call sites.
- Cancellation may now race with a normal result sooner. Verify both observations using barriers, while preserving the existing terminal outcomes and no-replay rules.
- The follow-up benchmark should show zero periodic context-waiter entries during the idle window, including SFTP with no host context. Compare CPU and latency distributions within each platform and keep native operation refreshes and independent I/O timers covered.
