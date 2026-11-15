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

The event-driven rerun used commit `83f398c59fca0efcc05762b0dca0d0b6447d6692` on the same macOS version and offline Linux container kernel. It reused the harness, pinned runtimes, resource limits, workload order and seeded cancellation delays. The readiness check for a scoped operation was updated to recognize its new event-driven receive. Each measurement reads **baseline → rerun**. Cancellation percentiles pool observations, including three samples per platform for the operation and adapter.

#### macOS

| Fixture | Count | Host context | Waiter entries/s | One core % | Active scheduler ms/s | Cancel p50 / p95 / max (ms) |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| control | 0 | no | 0 → 0 | 0.003 → 0.003 | 1.08 → 1.63 | — |
| event | 1 | no | 0 → 0 | 0.007 → 0.010 | 2.16 → 2.71 | — |
| event | 1 | yes | 98 → 0 | 0.015 → 0.006 | 1.34 → 1.93 | 18.00/19.14/19.14 → 0.18/0.22/0.22 |
| event | 100 | no | 0 → 0 | 0.036 → 0.076 | 6.39 → 13.66 | — |
| event | 100 | yes | 10,916 → 0 | 0.141 → 0.093 | 19.69 → 15.20 | 13.05/20.95/20.99 → 2.55/3.73/4.09 |
| event | 1000 | no | 0 → 0 | 0.232 → 0.414 | 46.86 → 119.29 | — |
| event | 1000 | yes | 114,702 → 0 | 1.081 → 0.653 | 222.39 → 122.74 | 10.13/19.39/21.18 → 10.89/18.99/20.88 |
| sftp | 1 | no | 49 → 0 | 0.006 → 0.005 | 0.93 → 1.79 | — |
| sftp | 1 | yes | 147 → 0 | 0.012 → 0.011 | 1.25 → 3.66 | 15.45/18.02/18.02 → 0.20/0.26/0.26 |
| sftp | 100 | no | 5,270 → 0 | 0.097 → 0.007 | 5.83 → 3.30 | — |
| sftp | 100 | yes | 16,518 → 0 | 0.099 → 0.005 | 14.60 → 1.96 | 8.00/19.82/20.88 → 2.25/4.25/4.47 |
| sftp | 1000 | no | 58,576 → 0 | 0.290 → 0.005 | 54.07 → 1.50 | — |
| sftp | 1000 | yes | 179,423 → 0 | 0.809 → 0.005 | 153.86 → 1.73 | 12.11/20.26/20.99 → 11.84/23.16/30.68 |
| operation | 1 | no | 0 → 0 | 0.003 → 0.007 | 0.84 → 2.22 | — |
| operation | 1 | yes | 49 → 0 | 0.007 → 0.014 | 1.07 → 5.28 | 16.04/19.00/19.00 → 0.21/0.22/0.22 |
| adapter | 1 | no | 0 → 0 | 0.003 → 0.005 | 1.02 → 1.86 | — |
| adapter | 1 | yes | 49 → 0 | 0.007 → 0.006 | 1.25 → 2.09 | 16.11/18.02/18.02 → 0.36/0.36/0.36 |

#### Linux

| Fixture | Count | Host context | Waiter entries/s | One core % | Active scheduler ms/s | Cancel p50 / p95 / max (ms) |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| control | 0 | no | 0 → 0 | 0.097 → 0.269 | 1.07 → 3.93 | — |
| event | 1 | no | 0 → 0 | 0.240 → 0.377 | 1.81 → 2.69 | — |
| event | 1 | yes | 87 → 0 | 0.554 → 0.342 | 3.69 → 3.15 | 14.36/23.18/23.18 → 0.27/0.27/0.27 |
| event | 100 | no | 0 → 0 | 1.437 → 3.145 | 7.67 → 19.81 | — |
| event | 100 | yes | 10,059 → 0 | 4.749 → 3.059 | 17.48 → 16.95 | 8.19/16.57/20.80 → 2.44/3.73/4.18 |
| event | 1000 | no | 0 → 0 | 12.307 → 25.019 | 79.64 → 171.00 | — |
| event | 1000 | yes | 106,150 → 0 | 29.078 → 23.172 | 212.70 → 158.83 | 19.31/28.70/32.92 → 18.90/42.47/51.77 |
| sftp | 1 | no | 43 → 0 | 0.420 → 0.216 | 1.47 → 2.01 | — |
| sftp | 1 | yes | 130 → 0 | 0.389 → 0.203 | 1.69 → 2.06 | 1.58/13.64/13.64 → 0.25/0.26/0.26 |
| sftp | 100 | no | 4,856 → 0 | 3.738 → 0.203 | 9.08 → 2.08 | — |
| sftp | 100 | yes | 15,321 → 0 | 5.038 → 0.251 | 17.23 → 2.49 | 12.42/18.25/23.31 → 2.98/4.66/5.53 |
| sftp | 1000 | no | 53,256 → 0 | 11.910 → 0.188 | 58.14 → 1.70 | — |
| sftp | 1000 | yes | 168,123 → 0 | 30.807 → 0.180 | 261.20 → 1.77 | 18.77/33.23/34.56 → 19.38/37.05/49.46 |
| operation | 1 | no | 0 → 0 | 0.102 → 0.199 | 0.94 → 1.91 | — |
| operation | 1 | yes | 42 → 0 | 0.441 → 0.248 | 1.39 → 3.12 | 5.87/17.27/17.27 → 0.31/0.41/0.41 |
| adapter | 1 | no | 0 → 0 | 0.144 → 0.240 | 1.71 → 2.66 | — |
| adapter | 1 | yes | 43 → 0 | 0.446 → 0.265 | 1.92 → 3.68 | 16.39/18.33/18.33 → 0.43/0.47/0.47 |

### 2. Subscription and delivery protocol

`RequestContext.new!/1` still allocates only the atomic. The first subscription starts one local, unlinked notifier on demand. It owns in-memory subscription records and monitors the context owner and each waiter. It drops a context's records on terminal delivery, owner exit or the last waiter leaving, and stops when empty. The creator has no role in subscription lifetime. A context that never has a waiter never allocates subscription resources.

The atomic remains authoritative. An additional active value marks that the first subscriber claimed the cell. A terminal transition races this claim with compare-and-exchange. For an unclaimed cell, the transition is a direct compare-and-exchange. For a claimed cell, the notifier serializes the transition with registrations and writes the terminal state itself. Each subscriber rechecks status after registration. Removing the last subscription releases the claim if the cell is still active.

The notifier replies to a cancellation once it commits the atomic, then sends the notification to each subscriber in a continuation. Canceller exit after its message reaches the notifier cannot interrupt that work. Subscribers monitor the notifier with a process alias. If the notifier itself dies before or during delivery, the monitor wakes all of its subscribers, including any that already received a notification. Waiters recheck the atomic and consume one terminal outcome. When the cell is still active after notifier loss, waiters register with a replacement using their original absolute deadlines. An owner-exit notification is also a wakeup to evaluate current status, so it preserves deadline precedence on a still-active cell.

On teardown, demonitoring with `:flush` deactivates the alias and removes its `:DOWN`. The waiter selectively drains any notification already in its mailbox, then removes its subscription from the notifier. Waiter death also removes the subscription. An already-queued notification and a late delivery attempt are covered by deterministic barriers, along with both creator/owner exit orders and the notifier's loss immediately after committing and partway through fanout.

The notifier runs no host callbacks. Registration and subscribed terminal transitions serialize through its mailbox. The idle benchmark measures after registration and before teardown, with cancellation fanout timed separately. Registration and teardown costs remain unmeasured. See the [process alias delivery semantics](https://www.erlang.org/doc/system/ref_man_processes.html#process-aliases).

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

Replace SFTP's private lifetime context with an absolute deadline and a session timer. Carry #29’s startup deadline across the upgrade and version handshake. The raw channel also takes the session deadline as its write bound. Its existing watcher observes the SFTP opener so a stalled raw operation releases the socket on opener exit. Preserve stream expiry, lock waits, owner loss, error classification and dispatched mutation uncertainty. Expiring the local SFTP session leaves a longer-lived host context active. Only the host context uses a context watcher.

Unix and verified HTTPS fixtures trace `ExecRun` from construction through cleanup. Preflight rejection allocates no private context. For dispatched runs and a work-scope rejection before dispatch, the cell reaches its terminal state and the notifier releases its records. Cleanup uses the tightened deadline on the same cell, leaving a still-active host context usable. Killing the caller during output delivery frees the subscriptions, stops the sink and closes the peers. The fixtures check native operation and error results, the exact aggregate output limit and overflow, and uncertainty after a dispatched POST without an acceptance response. They also check that no POST is replayed and no backend DELETE is sent.


### 7. Idle trace and timer verification

Each platform completed 51 trials. There were 45 windows per platform with at least one traced waiter, covering 23,130 waiter observations per platform over windows of 550–558 ms. Every individual window recorded zero schedule-ins. The harness verified the expected number of trace targets in every trial. Each idle event listener had two watchers. A scoped SFTP session had two watchers and an unscoped session had only its raw channel's owner watcher. The scoped operation was parked between native refreshes and the OCI adapter controller was waiting on a blocked callback. A separate pending GET traced the request guard both with and without a context and the shared notifier in the scoped case. These traces also recorded zero idle schedule-ins on both platforms.

At 1,000 scoped workloads, measured process CPU fell from 1.081% to 0.653% for macOS listeners and from 29.078% to 23.172% for Linux listeners. It fell from 0.809% to 0.005% for macOS SFTP and from 30.807% to 0.180% for Linux SFTP. At 1,000 SFTP sessions without a host context, CPU fell from 0.290% to 0.005% on macOS and from 11.910% to 0.188% on Linux. Unscoped event listeners used more CPU in the rerun, and the Linux no-workload control also rose. The runs were on different days. CPU and scheduler wall time include fixture work and independent I/O, so the waiter-specific trace is the direct evidence for removal of periodic checks.

Cancellation p95 fell to 3.73–4.66 ms across the 100-channel scoped trials and to 0.22–0.47 ms for the single operation and adapter. At 1,000 scoped channels, macOS listener p95 was nearly flat at 19.39 → 18.99 ms. SFTP p95 rose from 20.26 to 23.16 ms on macOS and from 33.23 to 37.05 ms on Linux. Linux listener p95 rose from 28.70 to 42.47 ms. Large fanout still includes peer closure and delivery of each `:DOWN` to the caller.

The operation, raw channel and SFTP session fixture suites passed all 46 tests on each platform. They verified native GET refresh cadence, raw upgrade and lifetime deadlines, and independent SFTP session and request deadlines. These measurements and timer checks used disposable fixtures.

## Risks and trade-offs

- A notification substrate can add per-context memory or per-waiter work. Measure construction and cleanup and document the lifetime of contexts with and without waiters before converting call sites.
- Cancellation may now race with a normal result sooner. Verify both observations using barriers, while preserving the existing terminal outcomes and no-replay rules.
