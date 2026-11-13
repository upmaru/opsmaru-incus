# Spec Delta

## Purpose

Provides optional, host-started reuse of idle native HTTP/1.1 connections for buffered reads, keyed by the full connection binding, without changing wire behavior, failure classification or the library's passive default.

## ADDED Requirements

### Requirement: Host-started passive pool

The connection pool SHALL exist only when a host explicitly starts it in its own supervision tree with bounded options. Loading or starting the library and constructing a connection MUST NOT start pool processes, start the pool dependency's OTP application, or open sockets. Client-only consumers SHALL compile without the optional pool dependency.

#### Scenario: Library without a pool

- **WHEN** a host loads and starts `:opsmaru_incus` and makes requests on connections without a `pool:` option
- **THEN** no pool process exists and every request opens and closes its own connection as before

#### Scenario: Dependency installed before opt-in

- **WHEN** a host with the optional dependency installed starts the library without a pool child
- **THEN** the dependency's OTP application and task supervisor remain stopped

#### Scenario: Pool stopped

- **WHEN** the host stops a running pool
- **THEN** idle sockets close, workers already performing I/O can finish under their existing deadline and close their sockets, and later requests run unpooled
- **AND** shutdown sends no native cancellation or repeated request

### Requirement: Binding isolation

Pooled connections SHALL be shared only between requests with an identical binding: connection owner, transport, address, `require_authenticated`, server-trust material, client certificate and key, and pinned fingerprint. Changing any credential or trust file MUST produce a different binding, and a pooled handshake MUST present the certificate and key bytes its binding was derived from. Binding keys and digests MUST NOT appear in diagnostics, errors, registry names or telemetry.

#### Scenario: Different client certificates

- **WHEN** two connections target the same HTTPS host with different client certificates
- **THEN** they never receive each other's sockets

#### Scenario: Different owners with identical credentials

- **WHEN** two connections with different owners target the same backend with identical credentials
- **THEN** they never receive each other's sockets

#### Scenario: Rotated credentials

- **WHEN** the host replaces a connection's certificate and key files between requests
- **THEN** the next request does not reuse any connection opened under the previous files and its handshake presents the new certificate

#### Scenario: Unready host

- **WHEN** a pooled call is made while the host context is not ready or its owner does not match the connection
- **THEN** the call is rejected before any checkout or connect, as without pooling

### Requirement: Reads-only reuse

Only buffered GET and HEAD requests SHALL reuse a validated idle connection within the configured age limit. All other methods MUST use a fresh connection. A socket can return to the pool only after a complete non-upgraded response that permits reuse. Streamed transfers, channels, upgrades and gateway relays MUST bypass the pool.

#### Scenario: Mutation with idle connections available

- **WHEN** a POST is issued while its binding has idle pooled connections
- **THEN** the POST is sent on a newly opened connection

#### Scenario: Server closed an idle connection

- **WHEN** a GET would reuse an idle connection that the server has closed
- **THEN** validation discards it and the GET runs on another valid or fresh connection

#### Scenario: Gateway relay on a pooled connection

- **WHEN** a gateway whose fixed connection carries a `pool:` option relays an exchange
- **THEN** the relay opens one new backend connection for that exchange and never takes it from or returns it to the pool

#### Scenario: Connection ages out during continuous reads

- **WHEN** an idle socket reaches its maximum connection age despite frequent use
- **THEN** the next read opens a fresh connection or uses another validated socket within its age limit

### Requirement: Unchanged failure semantics

Pooling MUST NOT change error kinds, deadlines, cancellation or wire requests. Mutations SHALL keep reporting `:connection` when no request bytes could have left and `:uncertain` afterwards. A reused connection MUST be bounded by the current request's deadline. The library MUST NOT retry any request, including a read that fails on a reused connection.

#### Scenario: Killed worker holding a pooled connection

- **WHEN** a request's worker is killed at its deadline while using a checked-out connection
- **THEN** that connection is closed and never returned, and the caller receives the same deadline error as without pooling

#### Scenario: Reused read closed by the server

- **WHEN** a reused GET passes validation but the server closes the socket before any response is parsed
- **THEN** the caller receives one `:response_closed` error and the library sends no second request

#### Scenario: Request worker dies during return

- **WHEN** the worker dies after transferring a completed socket back to the pool and before check-in is accepted
- **THEN** the pool closes the socket and releases the slot

### Requirement: Bounded acquisition without queueing

The pool SHALL reject saturation without waiting for a slot. One acquisition budget, capped by the remaining request deadline, MUST cover binding admission and checkout validation. A miss SHALL use a fresh connection while the request is active. Request workers SHALL perform TLS handshakes and request and response I/O.

#### Scenario: Saturated binding

- **WHEN** every pooled connection for a binding is checked out and another GET arrives
- **THEN** the GET opens a fresh connection immediately and returns the same result it would without the pool
