# Spec Delta

## Purpose

Provides optional, passive and redacted `:telemetry` events that let a host observe native Incus requests, channels, event listener callbacks and operation waits through its own handlers, without changing client behavior.

## ADDED Requirements

### Requirement: Optional passive emission

The library SHALL emit telemetry only through the optional `:telemetry` dependency and MUST compile and behave identically without it. Loading or starting the library MUST NOT create processes, tables, handlers, metrics or state for telemetry, and emission MUST NOT raise into a client call when `:telemetry` is loaded but not running.

#### Scenario: Client-only consumer

- **WHEN** a consumer without `:telemetry`, Plug or Cowboy compiles and calls the client
- **THEN** compilation succeeds, calls return the same results and no telemetry process or state exists

#### Scenario: Host with telemetry

- **WHEN** a host that runs `:telemetry` starts `:opsmaru_incus` without attaching handlers
- **THEN** no handler, table or process is created by the library

### Requirement: Exactly-once request outcomes

Every native Incus request that reaches the transport, including buffered calls, DoHTTP requests and streamed transfers, SHALL emit one `[:opsmaru_incus, :request, :start]` and, unless its calling process dies, exactly one `[:opsmaru_incus, :request, :stop]` from the calling process. The stop `outcome` MUST equal the result classification returned by the native request entry point, including `:uncertain` for possibly accepted mutations, and byte counts MUST include bytes moved before a deadline or cancellation. Composite work bounded by the transport MUST NOT emit request events of its own.

#### Scenario: Worker killed at deadline

- **WHEN** a download exceeds its deadline after transferring part of the body and the worker is killed
- **THEN** one stop event reports `outcome: :deadline` and the bytes already transferred, and no later event follows

#### Scenario: Lost mutation response

- **WHEN** a POST is sent and its response is lost
- **THEN** the stop event reports `outcome: :uncertain` and the request is not retried

#### Scenario: Native error status

- **WHEN** a typed call receives a native 404 error response
- **THEN** the stop event reports `status: 404` and `outcome: :native`, matching the returned error

#### Scenario: Bounded exec collection

- **WHEN** an exec run is bounded as one unit of work that issues requests and drains channels
- **THEN** only the contained native requests and channels emit events, and the bounding itself emits none

### Requirement: Exactly-once channel closure

Every successfully upgraded host-visible channel SHALL emit exactly one `[:opsmaru_incus, :channel, :close]` with its lifetime, byte and message counts and a closure reason, including when the channel process is killed. Upgrade attempts SHALL emit a `channel.open` span whose outcome equals the returned result. Composite channels SHALL emit one open/close pair for the host-visible channel only.

#### Scenario: Owner dies

- **WHEN** the process that opened a WebSocket channel exits and the channel is killed
- **THEN** one close event reports `reason: :owner_down` with the counts accumulated before death

#### Scenario: Failed upgrade

- **WHEN** a raw upgrade is rejected by the backend
- **THEN** an open stop event reports the returned error kind and no close event is emitted

#### Scenario: SFTP session

- **WHEN** a host opens and closes an SFTP session over its inner raw channel
- **THEN** exactly one `:sftp` open/close pair is emitted and no `:raw` events

### Requirement: Event listener callback outcomes

Each event listener callback invocation SHALL emit one `[:opsmaru_incus, :event_listener, :callback]` from the listener process with its duration and an outcome of success, failure or timeout. Event types and payloads MUST NOT be emitted.

#### Scenario: Callback timeout

- **WHEN** a callback exceeds its deadline and its worker is killed
- **THEN** one callback event reports `outcome: :callback_timeout` without the event type or payload

### Requirement: Operation wait outcomes

Each `Operation.wait` SHALL emit one span reporting poll count, final native status when observed and an outcome equal to the returned result. A local deadline or cancellation MUST NOT be reported as, or cause, backend cancellation.

#### Scenario: Local wait deadline

- **WHEN** a wait reaches its deadline while the operation is still running
- **THEN** the stop event reports `outcome: :deadline` with `native_status` absent, and no DELETE is sent

#### Scenario: Wait with explicit context

- **WHEN** a host waits on an operation with an explicit request context
- **THEN** exactly one wait span is emitted

### Requirement: Redacted bounded metadata

Event metadata SHALL contain only documented closed values: HTTP method, typed Go declaration name, request shape, transport, channel kind, HTTP status, error kind, closure reason, final native operation status and a span correlation reference. Metadata MUST NOT contain paths, queries, resource or project names, addresses, socket paths, certificates, credentials, identities, request contexts, operation IDs or URLs, ETags, headers, native messages or payloads. Callers MUST NOT be able to set the declaration name through public request options.

#### Scenario: Named resource request

- **WHEN** a typed call reads a named instance in a named project
- **THEN** its events carry the declaration name and outcome but neither the instance name nor the project

### Requirement: Bounded emission surface

Telemetry SHALL cover native Incus traffic issued by the client, including traffic issued on behalf of shared operations, and MUST NOT emit events for gateway relays, operation tool invocations as such, or requests and transfers against SimpleStreams or OCI image origins.

#### Scenario: Gateway relay

- **WHEN** a host-mounted gateway relays a native request or WebSocket upgrade
- **THEN** no `[:opsmaru_incus | _]` event is emitted for the relayed exchange

#### Scenario: Operation tool call

- **WHEN** a shared operation tool reads an instance through the client
- **THEN** the native request emits ordinary request events with its declaration name and no tool-level event is emitted

#### Scenario: Image origin fetch

- **WHEN** a SimpleStreams client refreshes its catalogue from an image origin
- **THEN** no request event is emitted for the origin traffic

### Requirement: No behavioral effect

Emission and handler behavior MUST NOT alter return values, error classification, deadlines, cancellation, retries, replay decisions, accepted options, wire requests or resource cleanup. Handler failures SHALL be contained by `:telemetry` and never propagate into a client call.

#### Scenario: Raising handler

- **WHEN** a host handler raises on `request.stop`
- **THEN** the client call returns its normal result and the same wire requests occur as without the handler
