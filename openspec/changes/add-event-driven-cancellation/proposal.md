# Proposal

## Why

`RequestContext` is a plain value around one `:atomics` cell. Nothing is notified when it is cancelled, when its owner exits or when its deadline passes, so every process that must react polls. Request guards (`Transport.guard_until/5`), channel watchers (`Transport.watch_until/4`), `Operation.wait/2` (`sleep_until/2`) and host adapter calls (`OCI.AdapterCall.await_result/6`, used by OCI and SimpleStreams delta conversion) each wake every 20 ms while a context is attached, read the atomic and call `Process.alive?/1` on the context owner. `SFTP` always builds its own lifetime context and watcher, so every SFTP session polls even when the host passed none, and a session with a host context runs a second polling watcher.

Each wakeup is cheap, but long-lived channels keep schedulers awake 50 times a second each for up to an hour, which matters for Macus on battery-powered Macs, and cancellation takes effect up to 20 ms late. Two of the three triggers already have event-driven BEAM equivalents (a monitor on the owner and a timer on the absolute deadline). The third, explicit `cancel/1` from an arbitrary process, needs a way to reach the processes waiting on the context without turning the context into a process.

## What Changes

- Give each `RequestContext` a public ETS subscriber table, created by `new!/1` with the context owner as heir, alongside the existing atomics cell. The atomic stays the single source of truth for `status/1` and `check/1`.
- Waiters register a process alias in the table, then re-read the atomic, so a cancellation racing registration is never lost. `cancel/1` keeps its compare-and-exchange; the process that wins it sends one message to every registered alias, then deletes the table.
- Waiters monitor the context owner instead of polling `Process.alive?/1`, and wait on the absolute deadline with a `receive ... after` timer instead of 20 ms ticks.
- Convert the four polling loops (request guard, channel watcher, operation wait, adapter call wait) to wait on those three events. Remove the 20 ms tick.
- Replace SFTP's private lifetime `RequestContext` with a plain deadline in the session, so a session without a host context creates no context or watcher. `ExecRun` already cancels its private context when execution returns; with the table, that cancel also releases it.
- Start with measurement: record wakeups, CPU and cancellation latency today, and continue only if the result justifies the change.

## Scope

Wait loops added or changed since this plan was first written were reviewed against current `develop`. Only loops that poll a `RequestContext` are in scope.

- **In.** `Transport.guard_until/5` and `watch_until/4`, `Operation.sleep_until/2`, `OCI.AdapterCall.await_result/6` (missed by the first draft; it predates it) and the SFTP lifetime context.
- **Covered without a new site.** The shared operation tools (`incus-operations`) wait with the native `GetOperationWait` through `Transport.bounded/4`, and SimpleStreams refresh and download also run under `Transport.bounded/4`; both reach the converted guard. The gateway's WebSocket writer calls `Transport.watch_owner/2` without a context and must keep exactly today's monitor-only path.
- **Out: gateway revocation and expiry rechecks** (`Gateway.Lease`). They call the host's policy on a `recheck_interval` of at most 5 s; that is a documented host-policy bound, not context cancellation, and stays periodic.
- **Out: gateway WebSocket watchdog** (`min(left, 25)`). It reads an idle clock that relays update per frame; making it event-driven would need a message per frame. Revisit only if 1.1 shows it matters.
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

- `RequestContext.new!/1` now creates one ETS table in addition to the atomics cell. Its moduledoc ("one cancellation cell and no process, socket or file") is updated: still no process, socket or file. `Inspect` stays redacted and `validate!/1` checks the new field.
- Touches `RequestContext`, `Transport` (guard and watcher), `Operation.wait/2`, `OCI.AdapterCall` and `SFTP`. Public function signatures, return values, error kinds and wire behavior are unchanged; cancellation becomes observable sooner.
- No new dependency. Process aliases need OTP 24 or later; the pinned OTP is 27.
- `priv/incus/coverage.json` and its completion records are unaffected. This change adds no typed-client evidence.
- `add-incus-telemetry` emits channel closure from the same owner watcher this change converts. Whichever lands second adapts to the other; neither modifies the other's plan.
- `add-incus-connection-pool` is independent: a guard still kills its worker the same way whether a tick or an event triggers it.
