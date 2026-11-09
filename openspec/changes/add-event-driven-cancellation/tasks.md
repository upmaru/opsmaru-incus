# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Task 1.1 gates the rest. This change adds no typed-client evidence and changes no `priv/incus/coverage.json` entry or completion record.

## 1. Baseline

- [ ] 1.1 Measure idle scheduler wakeups, scheduler wall time, process CPU and cancellation latency on macOS and Linux for 1, 100 and 1,000 open event listeners and SFTP sessions with and without a host context, and for a waiting `Operation.wait/2` and a pending OCI adapter call; record the method and results in this change and decide whether to continue. If the cost is immaterial, record that and stop.

## 2. Subscriber table

- [ ] 2.1 Add the subscriber table to `RequestContext.new!/1` with the owner as heir, update `validate!/1`, `Inspect` and the moduledoc; verify construction creates no process, socket or file, the table survives creator exit while the owner lives, is deleted on owner exit, and `status/1` and `check/1` return the same values as today for every state.
- [ ] 2.2 Implement subscribe, notify and unsubscribe with aliases; verify with deterministic interleavings that cancel-before-insert, cancel-after-insert, concurrent `cancel/1` calls, owner exit and deadline each produce exactly one observed terminal state per waiter, at most one message per alias and no message after `unalias`.
- [ ] 2.3 Implement table deletion by the winner of each terminal compare-and-exchange; verify tables are released after cancellation, observed deadline and owner exit, and that a missing table never changes a status result.

## 3. Event-driven waiters

- [ ] 3.1 Convert `Transport.guard_until/5`; verify a bounded request with a context performs no periodic wakeups while waiting, and that cancellation, context-owner exit, caller exit and deadline each kill the worker and yield today's error kind.
- [ ] 3.2 Convert `Transport.watch_until/4` and remove `tick/2`; verify every channel type stops on cancellation, context-owner exit and deadline with today's closure kind, keeps the 100 ms owner-exit grace period and has no periodic wakeups while open; verify a watcher without a context, such as the gateway WebSocket writer's, keeps only today's monitors.
- [ ] 3.3 Convert `Operation.sleep_until/2`; verify waits end promptly on cancellation and deadline with today's results, send no backend `DELETE`, and leave no message, monitor or alias in the caller after returning, including when `cancel/1` races the return.
- [ ] 3.4 Convert `OCI.AdapterCall.await_result/6`; verify OCI and SimpleStreams delta adapter calls with a context perform no periodic wakeups, end on cancellation, context-owner exit and deadline with today's `:adapter_canceled`, `:adapter_deadline` or owner-loss results, and still run per-call cleanup exactly once.

## 4. Internal contexts

- [ ] 4.1 Replace the SFTP lifetime context with a session deadline and timer, read by `closed_kind/2`, `request_deadline/2` and the lock wait; verify lifetime expiry, host-context cancellation, owner exit and a lock wait report today's kinds and that a session without a host context creates no context or watcher.
- [ ] 4.2 Verify that `ExecRun`'s existing cancel on return releases its private context's table, including for the deadline-tightened copy, and that exec results, output limits and uncertainty reporting are unchanged.

## 5. Verification

- [ ] 5.1 Repeat the 1.1 measurements and record before and after results side by side, without claiming Macus installation or hardware acceptance.
- [ ] 5.2 Run `mise run check`, `mise run check:reference` and `mise run check:consumer` against a pushed immutable revision.
