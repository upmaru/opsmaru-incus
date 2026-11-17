# Spec Delta

## Purpose

Delivers request-context cancellation, owner exit and deadline to the processes waiting on a context as events, without periodic polling and without changing context status semantics or making the context a process.

## ADDED Requirements

### Requirement: Passive context construction

Creating a request context SHALL create no process, socket or file. The atomic SHALL remain authoritative for the context's status. Any subscription resources SHALL be reclaimed after context-owner exit, including when a distinct creator survives. A terminal context SHALL release its subscription resources after delivery and teardown.

#### Scenario: Context created by a non-owner

- **WHEN** a process creates a context for a different local owner and then exits
- **THEN** the context remains usable, its status is unchanged and cancellation still reaches its waiters

#### Scenario: Context owner exits before creator

- **WHEN** a distinct context owner exits while the creator lives, including when the context has never had a waiter
- **THEN** any subscription resources are reclaimed without relying on creator exit or periodic cleanup

### Requirement: No polling while waiting

Request guards, channel watchers, operation waits and host adapter call waits MUST NOT wake periodically while waiting on a request context. They SHALL react to explicit cancellation, context-owner exit and the absolute deadline as delivered events.

#### Scenario: Idle channel with a context

- **WHEN** an event listener with a host request context stays open with no traffic
- **THEN** its watcher performs no periodic wakeups until a channel, owner, cancellation or deadline event occurs

#### Scenario: Pending adapter call with a context

- **WHEN** an OCI or SimpleStreams delta adapter call with a host request context is waiting on the host callback
- **THEN** its controller performs no periodic wakeups, and cancellation ends the call with `:adapter_canceled` and runs per-call cleanup once

### Requirement: Single terminal outcome per wait

A pending wait SHALL observe one terminal outcome when the context ends, including when cancellation races registration or the cancel caller exits during delivery. Unregistration SHALL prevent further deliveries and remove queued notifications and monitors that belong to the wait.

#### Scenario: Cancellation races registration

- **WHEN** `cancel/1` runs concurrently with a guard registering on the same context
- **THEN** the guard observes `:canceled` and kills its worker, and handles one terminal outcome

#### Scenario: Cancelling process exits during delivery

- **WHEN** a cancelling process exits after recording the terminal state, before or during delivery
- **THEN** pending waiters observe the recorded state without a second cancel call or periodic checks

#### Scenario: Cancellation races the end of a wait

- **WHEN** `cancel/1` runs while `Operation.wait/2` is returning in the host's process
- **THEN** no cancellation message remains in the host's mailbox afterwards and unrelated mailbox messages remain available

### Requirement: Unchanged status and outcomes

`RequestContext.status/1` and `check/1` SHALL return the same values as before for every combination of cancellation, owner exit and deadline. Requests, channels, operation waits and adapter calls SHALL report the same error and closure kinds, and local cancellation MUST NOT issue a backend cancellation request or replay a mutation.

#### Scenario: Owner exits during a request

- **WHEN** the context owner, distinct from the caller, exits during a bounded request
- **THEN** the worker is killed and the caller receives `:canceled`, as before

#### Scenario: Cancellation overlaps HTTPS pool ownership transfer

- **WHEN** a pooled read is cancelled during checkout, during the exchange or during socket return
- **THEN** the worker and its resources are released, the pool remains usable and its cancellation preserves the existing no-replay rules

### Requirement: No internal lingering contexts

Library-internal request contexts SHALL be released when their scope ends, and SFTP sessions without a host context MUST NOT create a request context or watcher.

#### Scenario: SFTP without a host context

- **WHEN** a host opens an SFTP session on a client without a request context
- **THEN** no request context or watcher process is created, and the session still ends at its stream deadline

#### Scenario: SFTP negotiation reaches its startup deadline

- **WHEN** the upgrade and version exchange exhaust the original SFTP startup budget
- **THEN** the session reports the existing deadline result and leaves a longer-lived host context active
