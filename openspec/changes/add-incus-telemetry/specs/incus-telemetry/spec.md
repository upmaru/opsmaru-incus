# Spec Delta

## Purpose

Provides optional, passive and redacted `:telemetry` events that let a host observe native Incus requests, channels and operation waits through its own handlers, without changing client behavior.

## ADDED Requirements

### Requirement: Optional passive emission

The library SHALL emit telemetry only through the optional `:telemetry` dependency and MUST compile and behave identically without it. Loading or starting the library MUST NOT create processes, tables, handlers, metrics or state for telemetry, and emission MUST NOT raise into a client call when `:telemetry` is loaded but not running.

#### Scenario: Client-only consumer

- **WHEN** a consumer without `:telemetry` compiles and calls the client
- **THEN** compilation succeeds, calls return the same results and no telemetry process or state exists

#### Scenario: Host with telemetry

- **WHEN** a host that runs `:telemetry` starts `:opsmaru_incus` without attaching handlers
- **THEN** no handler, table or process is created by the library

### Requirement: Exactly-once request outcomes

Every started native request, including buffered calls and streamed transfers, SHALL emit one `[:opsmaru_incus, :request, :start]` and, unless its calling process dies, exactly one `[:opsmaru_incus, :request, :stop]` from the calling process. The stop `outcome` MUST equal the result classification returned to the caller, including `:uncertain` for possibly accepted mutations, and byte counts MUST include bytes moved before a deadline or cancellation.

#### Scenario: Worker killed at deadline

- **WHEN** a download exceeds its deadline after transferring part of the body and the worker is killed
- **THEN** one stop event reports `outcome: :deadline` and the bytes already transferred, and no later event follows

#### Scenario: Lost mutation response

- **WHEN** a POST is sent and its response is lost
- **THEN** the stop event reports `outcome: :uncertain` and the request is not retried

### Requirement: Exactly-once channel closure

Every successfully upgraded host-visible channel SHALL emit exactly one `[:opsmaru_incus, :channel, :close]` with its lifetime, byte and message counts and a closure reason, including when the channel process is killed. Upgrade attempts SHALL emit a `channel.open` span whose outcome equals the returned result. Composite channels SHALL emit one open/close pair for the host-visible channel only.

#### Scenario: Owner dies

- **WHEN** the process that opened a WebSocket channel exits and the channel is killed
- **THEN** one close event reports `reason: :owner_down` with the counts accumulated before death

#### Scenario: Failed upgrade

- **WHEN** a raw upgrade is rejected by the backend
- **THEN** an open stop event reports the returned error kind and no close event is emitted

### Requirement: Operation wait outcomes

Each `Operation.wait` SHALL emit one span reporting poll count, final native status when observed and an outcome equal to the returned result. A local deadline or cancellation MUST NOT be reported as, or cause, backend cancellation.

#### Scenario: Local wait deadline

- **WHEN** a wait reaches its deadline while the operation is still running
- **THEN** the stop event reports `outcome: :deadline` with `native_status` absent, and no DELETE is sent

### Requirement: Redacted bounded metadata

Event metadata SHALL contain only documented closed values: HTTP method, typed Go declaration name, request shape, transport, channel kind, HTTP status, error kind, closure reason, final native operation status and a span correlation reference. Metadata MUST NOT contain paths, queries, resource or project names, addresses, socket paths, certificates, credentials, identities, request contexts, operation IDs or URLs, ETags, headers, native messages or payloads.

#### Scenario: Named resource request

- **WHEN** a typed call reads a named instance in a named project
- **THEN** its events carry the declaration name and outcome but neither the instance name nor the project

### Requirement: No behavioral effect

Emission and handler behavior MUST NOT alter return values, error classification, deadlines, cancellation, retries, replay decisions, wire requests or resource cleanup. Handler failures SHALL be contained by `:telemetry` and never propagate into a client call.

#### Scenario: Raising handler

- **WHEN** a host handler raises on `request.stop`
- **THEN** the client call returns its normal result and the same wire requests occur as without the handler
