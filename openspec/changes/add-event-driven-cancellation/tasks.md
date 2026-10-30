# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Task 1.1 gates the rest. This change adds no typed-client evidence and never closes foundation task 3.9 or any `priv/incus/coverage.json` entry.

## 1. Baseline

- [ ] 1.1 Measure idle scheduler wakeups, scheduler wall time, process CPU and cancellation latency on macOS and Linux for 1, 100 and 1,000 open event listeners and SFTP sessions with and without a host context, and for a waiting `Operation.wait/2`; record the method and results in this change and decide whether to continue. If the cost is immaterial, record that and stop.

## 2. Subscriber table

- [ ] 2.1 Add the subscriber table to `RequestContext.new!/1` with the owner as heir, update `validate!/1`, `Inspect` and the moduledoc; verify construction creates no process, socket or file, the table survives creator exit while the owner lives, is deleted on owner exit, and `status/1` and `check/1` return the same values as today for every state.
- [ ] 2.2 Implement subscribe, notify and unsubscribe with aliases; verify with deterministic interleavings that cancel-before-insert, cancel-after-insert, concurrent `cancel/1` calls, owner exit and deadline each produce exactly one observed terminal state per waiter, at most one message per alias and no message after `unalias`.
- [ ] 2.3 Implement table deletion by the winner of each terminal compare-and-exchange; verify tables are released after cancellation, observed deadline and owner exit, and that a missing table never changes a status result.

## 3. Event-driven waiters

- [ ] 3.1 Convert `Transport.guard_until/5`; verify a bounded request with a context performs no periodic wakeups while waiting, and that cancellation, context-owner exit, caller exit and deadline each kill the worker and yield today's error kind.
- [ ] 3.2 Convert `Transport.watch_until/4` and remove `tick/2`; verify every channel type stops on cancellation, context-owner exit and deadline with today's closure kind, keeps the 100 ms owner-exit grace period and has no periodic wakeups while open.
- [ ] 3.3 Convert `Operation.sleep_until/2`; verify waits end promptly on cancellation and deadline with today's results, send no backend `DELETE`, and leave no message, monitor or alias in the caller after returning, including when `cancel/1` races the return.

## 4. Internal contexts

- [ ] 4.1 Replace the SFTP lifetime context with a session deadline timer; verify lifetime expiry, host-context cancellation and owner exit report today's kinds and that a session without a host context starts no watcher.
- [ ] 4.2 Cancel `ExecRun`'s private context when execution returns; verify its table is released and exec results, output limits and uncertainty reporting are unchanged.

## 5. Verification

- [ ] 5.1 Repeat the 1.1 measurements and record before and after results side by side, without claiming Macus installation or hardware acceptance.
- [ ] 5.2 Run `mise run check`, `mise run check:reference` and `mise run check:consumer` against a pushed immutable revision.
