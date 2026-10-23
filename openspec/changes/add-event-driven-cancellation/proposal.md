# Proposal

## Why

`RequestContext` is a plain value around one `:atomics` cell. Nothing is notified when it is cancelled, when its owner exits or when its deadline passes, so every process that must react polls. Request guards (`Transport.guard_until/5`), channel watchers (`Transport.watch_until/4`) and `Operation.wait/2` (`sleep_until/2`) each wake every 20 ms while a context is attached, read the atomic and call `Process.alive?/1` on the context owner. `SFTP` always builds its own lifetime context, so every SFTP session polls even when the host passed none.

Each wakeup is cheap, but long-lived channels keep schedulers awake 50 times a second each for up to an hour, which matters for Macus on battery-powered Macs, and cancellation takes effect up to 20 ms late. Two of the three triggers already have event-driven BEAM equivalents (a monitor on the owner and a timer on the absolute deadline). The third, explicit `cancel/1` from an arbitrary process, needs a way to reach the processes waiting on the context without turning the context into a process.

## What Changes

- Give each `RequestContext` a public ETS subscriber table, created by `new!/1` with the context owner as heir, alongside the existing atomics cell. The atomic stays the single source of truth for `status/1` and `check/1`.
- Waiters register a process alias in the table, then re-read the atomic, so a cancellation racing registration is never lost. `cancel/1` keeps its compare-and-exchange; the process that wins it sends one message to every registered alias, then deletes the table.
- Waiters monitor the context owner instead of polling `Process.alive?/1`, and wait on the absolute deadline with a `receive ... after` timer instead of 20 ms ticks.
- Convert the three polling loops (request guard, channel watcher, operation wait) to wait on those three events. Remove the 20 ms tick.
- Replace SFTP's private lifetime `RequestContext` with a plain deadline in the session process, and cancel library-internal contexts (such as `ExecRun`'s) when their scope ends, so internal use creates no lingering tables.
- Start with measurement: record wakeups, CPU and cancellation latency today, and continue only if the result justifies the change.

## Capabilities

### New Capabilities

- `incus-cancellation`: event-driven delivery of request-context cancellation, owner exit and deadline to request guards, channel watchers and operation waits, with unchanged status semantics and no polling.

### Modified Capabilities

None. The main spec inventory is empty. The foundation change owns the existing request-context behavior; this change keeps its observable results and adds delivery requirements.

## Impact

- `RequestContext.new!/1` now creates one ETS table in addition to the atomics cell. Its moduledoc ("one cancellation cell and no process, socket or file") is updated: still no process, socket or file. `Inspect` stays redacted and `validate!/1` checks the new field.
- Touches `RequestContext`, `Transport` (guard and watcher), `Operation.wait/2`, `SFTP` and `ExecRun`. Public function signatures, return values, error kinds and wire behavior are unchanged; cancellation becomes observable sooner.
- No new dependency. Process aliases need OTP 24 or later; the pinned OTP is 27.
- `priv/incus/coverage.json` and foundation task 3.9 are unaffected.
- If `add-incus-telemetry` lands first, its channel-close watcher builds on the event-driven watcher here; neither change modifies the other.
