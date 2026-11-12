# Spec Delta

## Purpose

Allows another host application to embed the portable Incus library without activating a second public server or taking over host installation and runtime lifecycle.

## ADDED Requirements

### Requirement: Passive library loading

The library SHALL have no application callback or supervision tree of its own. Loading, starting or restarting it MUST NOT start an endpoint, repository, listener or worker, create state, read credentials or contact a backend. Ambient web-server environment variables MUST NOT have any effect.

#### Scenario: Dependency startup

- **WHEN** a host starts and restarts the dependency while PHX_SERVER and PORT are present
- **THEN** no dependency-owned process, endpoint, repository, listener or state is created and the host retains its existing public endpoint

### Requirement: Host-supplied integration

Library calls SHALL accept the host's backend connection, private state location, identity integration and host capabilities explicitly. Client operations MUST NOT require Macus, Swift, a fixed state directory, a database, Phoenix or a separately running Opsmaru process.

The trusted host context SHALL be exposed as `Opsmaru.Incus.Context`, and optional
host-owned bounded supervision SHALL be exposed as `Opsmaru.Incus.ClientSupervisor`.
Both helpers MUST retain their existing behavior and require explicit host use.

#### Scenario: Consumer adopts the namespace cleanup

- **WHEN** a consumer pins the namespace-cleanup revision and updates its context aliases, struct references and supervisor child specifications
- **THEN** the Incus-scoped helpers preserve readiness, owner isolation, redaction, bounded supervision and passive dependency startup without legacy compatibility modules

#### Scenario: Macus embedding

- **WHEN** Macus supplies its native socket backend and host context
- **THEN** client operations execute inside the Macus server process without an Opsmaru service installation

### Requirement: Independent runtime ownership

Starting, stopping or recovering the library or host-supervised client workers MUST NOT implicitly start, stop or delete the host runtime or Incus workloads. Optional host lifecycle actions SHALL require an explicitly selected host operation and authorization.

#### Scenario: Embedded workers restart

- **WHEN** a host-supervised client worker supervisor restarts
- **THEN** existing host runtime and Incus workloads remain owned by their original services and are not restarted

### Requirement: Host readiness before execution

Configured execution and recovery SHALL wait for the host's identity and provider integration to become ready. Dependency startup order MUST NOT authorize queued work or open a privileged backend before that integration is available.

#### Scenario: Host authentication starts later

- **WHEN** dependency workers start before the embedding host's identity integration is ready
- **THEN** no queued execution or recovery contacts the backend until trusted host readiness is established

### Requirement: Reproducible consumer dependency

Production consumers SHALL identify an immutable dependency revision or released version and its resolved dependencies. Editable local path dependencies SHALL be restricted to development and MUST NOT be necessary to build or run an installed consumer.

#### Scenario: Isolated consumer build

- **WHEN** Macus is built without a sibling opsmaru-incus checkout
- **THEN** its pinned dependency resolves reproducibly and its installed package records the opsmaru-incus source identity

### Requirement: Database-free library verification

Library embedding and client fixture checks SHALL be runnable without database credentials, provider login, an HTTP endpoint or a live backend. The library's ordinary test command MUST NOT require database setup. Consumer builds SHALL remain reproducible without a sibling checkout.

#### Scenario: Isolated library checks

- **WHEN** library checks run with no PostgreSQL service, DATABASE_URL, OIDC configuration or Macus runtime
- **THEN** embedding and fake Unix/HTTPS client checks can complete without activating any of those services
