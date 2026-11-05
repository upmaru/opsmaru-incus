# Spec Delta

## Purpose

Provides optional, host-started reuse of idle native HTTP/1.1 connections for buffered reads, keyed by the full connection binding, without changing wire behavior, failure classification or the library's passive default.

## ADDED Requirements

### Requirement: Host-started passive pool

The connection pool SHALL exist only when a host explicitly starts it in its own supervision tree with bounded options. Loading or starting the library, constructing a `Connection` or making calls without a `pool:` option MUST NOT start pool processes, open sockets or change request behavior.

#### Scenario: Library without a pool

- **WHEN** a host loads and starts `:opsmaru_incus` and makes requests on connections without a `pool:` option
- **THEN** no pool process exists and every request opens and closes its own connection as before

#### Scenario: Pool stopped

- **WHEN** the host stops a running pool
- **THEN** only pooled local sockets close, no Incus request or operation is sent or cancelled, and later requests run unpooled

### Requirement: Binding isolation

Pooled connections SHALL be shared only between requests with an identical binding: transport, address, server-trust material, client certificate and key, pinned fingerprint and `require_authenticated`. Changing any credential or trust file MUST produce a different binding. Binding keys and digests MUST NOT appear in diagnostics, errors, registry names or telemetry.

#### Scenario: Different client certificates

- **WHEN** two connections target the same HTTPS host with different client certificates
- **THEN** they never receive each other's sockets

#### Scenario: Rotated credentials

- **WHEN** the host replaces a connection's certificate and key files between requests
- **THEN** the next request does not reuse any connection opened under the previous files

### Requirement: Reads-only reuse

Only buffered GET and HEAD requests SHALL reuse an idle pooled connection, and only after it passes open-socket validation. All other methods MUST use a fresh connection. A connection MUST be returned to the pool only after a complete, non-upgraded response without `connection: close`. Streamed transfers and upgrades MUST NOT use the pool.

#### Scenario: Mutation with idle connections available

- **WHEN** a POST is issued while its binding has idle pooled connections
- **THEN** the POST is sent on a newly opened connection

#### Scenario: Server closed an idle connection

- **WHEN** a GET would reuse an idle connection that the server has closed
- **THEN** validation discards it and the GET runs on another valid or fresh connection

### Requirement: Unchanged failure semantics

Pooling MUST NOT change error kinds, deadlines, cancellation or wire requests. Mutations SHALL keep reporting `:connection` when no request bytes could have left and `:uncertain` afterwards. The library MUST NOT retry any request, including a read that fails on a reused connection.

#### Scenario: Killed worker holding a pooled connection

- **WHEN** a request's worker is killed at its deadline while using a checked-out connection
- **THEN** that connection is closed and never returned, and the caller receives the same deadline error as without pooling

### Requirement: No queueing and no pool I/O

Pool processes MUST NOT perform network I/O or TLS handshakes. A request that cannot obtain a validated idle connection within a short documented bound, or whose binding cannot be admitted under `max_bindings`, SHALL proceed on a fresh unpooled connection rather than wait or fail.

#### Scenario: Saturated binding

- **WHEN** every pooled connection for a binding is checked out and another GET arrives
- **THEN** the GET opens a fresh connection immediately and returns the same result it would without the pool
