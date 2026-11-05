# Design

## Context

See [proposal.md](proposal.md). `RequestContext.new!/1` validates a finite timeout and a local owner and returns `%RequestContext{owner, deadline, cancelled}`, where `cancelled` is a one-slot `:atomics` array: `0` active, `1` cancelled, `2` deadline. `cancel/1` compare-and-exchanges `0` to `1` (or to `2` if the deadline already passed). `status/1` reads the slot and, while it is `0`, also checks the deadline and `Process.alive?(owner)`, recording either result with the same compare-and-exchange.

Three loops call `status/1` on a 20 ms tick when a context is present:

| Site | Process | Duration |
| --- | --- | --- |
| `Transport.guard_until/5` | one guard per bounded request | the request |
| `Transport.watch_until/4` | one watcher per channel (`WebSocket`, `RawChannel`, `SFTP`, `DynamicConsole`, `EventListener`) | the channel's life |
| `Operation.sleep_until/2` | the caller | each gap between polls |

The guard and watcher already monitor their worker or channel and its caller, so caller death is event-driven today. The context owner can differ from the caller (`owner:` option), and that is the only reason `Process.alive?/1` is polled. `SFTP.lifetime/1` creates a private context from `stream_timeout` for every session, and `ExecRun` creates one per execution.

## Goals / Non-Goals

**Goals:** no periodic wakeups while waiting on a context; cancellation, owner exit and deadline observed as soon as the BEAM delivers them; identical `status/1`, `check/1` and error classification; contexts remain values with no process.

**Non-Goals:** backend cancellation (local cancellation still never sends a `DELETE`), cancellation across nodes, changes to deadlines or default timeouts, propagating a host context's cancellation into library-internal contexts beyond what happens today, and changes to `WorkScope`.

## Decisions

### 1. Measure first

Before any implementation, record on macOS and Linux, for 1, 100 and 1,000 concurrently open event listeners and SFTP sessions with and without a host context: scheduler wakeups (`:erlang.statistics(:context_switches)` and scheduler wall time over an idle interval), process CPU and observed cancellation latency. Repeat for a waiting `Operation.wait/2`. Continue only if idle cost or latency is material for Macus; otherwise record the numbers and archive the change unimplemented.

### 2. Subscriber table with the owner as heir

`new!/1` additionally creates

```elixir
:ets.new(__MODULE__, [:set, :public, {:heir, owner, :request_context}, read_concurrency: false])
```

and stores its id in a new `subscribers` field. The creating process owns it; if the creator exits before the owner, the table passes to the owner. When the owner exits, the table is deleted, which matches the existing rule that owner exit cancels the context. No process is created, and the table name is not registered.

The table holds `{alias, true}` rows only. It is never the source of truth: a missing table, a failed insert or an empty table cannot make a context look active or cancelled. `status/1` and `check/1` keep reading the atomic exactly as today.

### 3. Registration, notification and the lost-wakeup rule

A waiter subscribes in this order:

1. Create an alias with `:erlang.alias([:explicit_unalias])`.
2. Insert `{alias, true}` into the table. If the table no longer exists, skip to step 3.
3. Re-read `status/1`. If it is no longer `:active`, act on it immediately.
4. Otherwise wait for one of: `{alias, :request_context_cancelled}`, `:DOWN` for the context owner, the waiter's other existing monitors, or `after` the remaining time to the absolute deadline.

Re-reading after insertion is what prevents a lost wakeup: a `cancel/1` that won its compare-and-exchange before the insert is seen in step 3, and one that wins after it finds the alias in the table.

`cancel/1` is unchanged up to its compare-and-exchange. Only the caller whose exchange succeeds then sends `{alias, :request_context_cancelled}` to every alias in the table and deletes the table. Later `cancel/1` calls lose the exchange and do nothing more, so each subscriber gets at most one message.

A waiter that finishes deletes its row (ignoring a missing table) and calls `:erlang.unalias/1`. After `unalias`, a notification already in flight is dropped by the runtime rather than delivered. This matters for `Operation.wait/2`, which waits in the host's own process: a cancellation racing the end of a wait can never leave a stray message in the host's mailbox.

### 4. Owner exit and deadline without polling

Waiters call `Process.monitor(context.owner)` unless the owner is a process they already monitor, and treat its `:DOWN` exactly as `status/1` treats a dead owner: compare-and-exchange `0` to `1` and act on the result. The deadline is absolute, so each waiter computes `max(0, min(context.deadline, own_deadline) - now())` once and uses it as the `after` value, recomputing only after handling an unrelated message. On timeout it calls `status/1`, which records `2` as today.

### 5. Converting the three loops

- **Request guard.** `guard_until/5` becomes one `receive` over the worker and caller `:DOWN`s (existing), the context owner `:DOWN`, the cancellation alias and the deadline. Any of the last three kills the worker as today. The caller's outcome classification in `bounded_active/4` is unchanged.
- **Channel watcher.** `watch_until/4` becomes one `receive` over the existing channel and owner `:DOWN`s, the context owner `:DOWN`, the alias and the context deadline. The 100 ms grace period after owner exit is unchanged. Without a context there is no alias, monitor or timer beyond today's.
- **Operation wait.** `sleep_until/2` waits in the caller with `receive` on the alias and the context owner `:DOWN`, `after` the next poll time capped at the deadline. It unsubscribes, demonitors with `:flush` and unaliases before returning.

The `tick/2` helper is removed.

### 6. Internal contexts

`SFTP` stops creating a lifetime `RequestContext`. The session keeps a plain absolute deadline and a `Process.send_after/3` timer, as `RawChannel` already does for its lifetime, and `closed_kind/2` reports `:deadline` from that value. Only a host-supplied context gets a watcher.

`ExecRun` keeps its private context, because its workers already share it, and cancels it when `execute/8` returns. Its status is never read after that point, so cancelling only releases the table and wakes any remaining waiter.

### 7. Table lifetime

A table is deleted when the winning `cancel/1` finishes, when `status/1` or a waiter records a deadline or owner exit (the process that wins that compare-and-exchange deletes it), or when the owner exits. A host context that is never cancelled, never reaches a waiter after its deadline and whose owner lives on keeps its table until the owner exits. The moduledoc tells hosts that create many contexts in a long-lived process to cancel each one when its work ends. Cancelling a finished context has no backend effect.

## Alternatives Considered

### Context as a process (rejected)

A GenServer per context could push notifications directly, but it breaks the contract that construction creates no process, adds a lifecycle the host must supervise, and makes `status/1` a call instead of an atomic read.

### Longer or adaptive ticks (rejected)

Backing off from 20 ms to seconds cuts wakeups but makes cancellation latency unbounded in practice, weakening the guarantee the guard exists to provide.

### `:pg` or a global registry (rejected)

A process group scope or a named table needs a long-lived owning process, which the library must not start. A host-started scope would make cancellation correctness depend on optional host configuration.

### Subscriber pids instead of aliases (rejected)

Sending to a pid cannot be revoked. A notification racing the end of `Operation.wait/2` would land in the host's mailbox. Aliases make late messages disappear.

## Risks / Trade-offs

- **One ETS table per context.** Construction costs microseconds and a few hundred bytes. Hosts that never cancel contexts in long-lived owners accumulate tables until the owner exits; documented and covered by the lifetime rules above.
- **Public table.** Any local process holding the context can write to the table. That is the same trust boundary as the public atomics cell today, and the table never decides status.
- **Ordering subtleties.** Lost-wakeup and double-notification races are the main correctness risk. Tasks require deterministic interleaving tests for each ordering of subscribe, cancel, owner exit and deadline.

## Open Questions

- Should `RequestContext` gain a public `release/1` that deletes the table without cancelling, for hosts that want to keep a finished context's `:active` status? Deferred; `cancel/1` covers known uses.
- Should `ExecRun`'s private context subscribe to the host context, so host cancellation reaches exec workers directly instead of through the deadline it already copies? Deferred to keep this change behavior-preserving.
