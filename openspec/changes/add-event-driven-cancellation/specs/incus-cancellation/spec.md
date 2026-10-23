# Spec Delta

## Purpose

Delivers request-context cancellation, owner exit and deadline to the processes waiting on a context as events, without periodic polling and without changing context status semantics or making the context a process.

## ADDED Requirements

### Requirement: Passive context construction

Creating a request context SHALL create no process, socket or file. It MAY create one subscriber table, which MUST NOT be the source of truth for the context's status and MUST be released no later than the owner's exit.

#### Scenario: Context created by a non-owner

- **WHEN** a process creates a context for a different local owner and then exits
- **THEN** the context remains usable, its status is unchanged and cancellation still reaches its waiters

### Requirement: No polling while waiting

Request guards, channel watchers and operation waits MUST NOT wake periodically while waiting on a request context. They SHALL react to explicit cancellation, context-owner exit and the absolute deadline as delivered events.

#### Scenario: Idle channel with a context

- **WHEN** an event listener with a host request context stays open with no traffic
- **THEN** its watcher performs no periodic wakeups until a channel, owner, cancellation or deadline event occurs

### Requirement: Exactly-once cancellation delivery

Every waiter registered on a context SHALL observe its terminal state exactly once, regardless of whether cancellation happens before, during or after registration. Each registered waiter MUST receive at most one cancellation message, and no message MUST reach a waiter after it has unregistered.

#### Scenario: Cancellation races registration

- **WHEN** `cancel/1` runs concurrently with a guard registering on the same context
- **THEN** the guard observes `:canceled` and kills its worker, and receives no more than one notification

#### Scenario: Cancellation races the end of a wait

- **WHEN** `cancel/1` runs while `Operation.wait/2` is returning in the host's process
- **THEN** no cancellation message remains in the host's mailbox afterwards

### Requirement: Unchanged status and outcomes

`RequestContext.status/1` and `check/1` SHALL return the same values as before for every combination of cancellation, owner exit and deadline. Requests, channels and operation waits SHALL report the same error and closure kinds, and local cancellation MUST NOT send any backend request.

#### Scenario: Owner exits during a request

- **WHEN** the context owner, distinct from the caller, exits during a bounded request
- **THEN** the worker is killed and the caller receives `:canceled`, as before

### Requirement: No internal lingering contexts

Library-internal request contexts SHALL be released when their scope ends, and SFTP sessions without a host context MUST NOT create a request context or watcher.

#### Scenario: SFTP without a host context

- **WHEN** a host opens an SFTP session on a client without a request context
- **THEN** no request context or watcher process is created, and the session still ends at its stream deadline
