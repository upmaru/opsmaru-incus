# Spec Delta

## Purpose

Allows another host application to embed the reusable compute service without activating a second public server or taking over host installation and runtime lifecycle.

## ADDED Requirements

### Requirement: Safe embedded default

The service SHALL default to embedded mode. Embedded startup SHALL expose configured compute services without starting its own endpoint process, repository or network listener. Ambient web-server environment variables MUST NOT override the host's embedded configuration.

#### Scenario: Dependency startup

- **WHEN** a host starts the dependency in embedded mode while PHX_SERVER and PORT are present
- **THEN** no dependency-owned endpoint, repository or listener starts and the host retains its existing public endpoint

### Requirement: Host-supplied integration

Embedding SHALL accept the host's backend connection, private state location, identity integration and host capabilities. Shared operations MUST NOT require Macus, Swift, a fixed state directory, an independent database or a separately running Opsmaru process.

#### Scenario: Macus embedding

- **WHEN** Macus supplies its native socket backend and registered runtime adapter
- **THEN** shared compute operations execute inside the Macus server process without an Opsmaru service installation

### Requirement: Independent runtime ownership

Starting, stopping or recovering the compute service MUST NOT implicitly start, stop or delete its host runtime or Incus workloads. Optional host lifecycle actions SHALL require an explicitly selected host operation and authorization.

#### Scenario: Embedded workers restart

- **WHEN** the shared worker supervision tree restarts
- **THEN** existing host runtime and Incus workloads remain owned by their original services and are not restarted

### Requirement: Host readiness before execution

Configured execution and recovery SHALL wait for the host's identity and provider integration to become ready. Dependency startup order MUST NOT authorize queued work or open a privileged backend before that integration is available.

#### Scenario: Host authentication starts later

- **WHEN** dependency workers start before the embedding host's identity integration is ready
- **THEN** no queued execution or recovery contacts the backend until trusted host readiness is established

### Requirement: Reproducible consumer dependency

Production consumers SHALL identify an immutable dependency revision or released version and its resolved dependencies. Editable local path dependencies SHALL be restricted to development and MUST NOT be necessary to build or run an installed consumer.

#### Scenario: Isolated consumer build

- **WHEN** Macus is built without a sibling Opsmaru checkout
- **THEN** its pinned dependency resolves reproducibly and its installed package records the Opsmaru source identity

### Requirement: Database-free library verification

Library embedding and client fixture checks SHALL be runnable without database credentials, provider login, an HTTP endpoint or a live backend. Generated web-test database setup MUST NOT be required for the library test profile. Consumer builds SHALL remain reproducible without a sibling checkout.

#### Scenario: Isolated library checks

- **WHEN** library checks run with no PostgreSQL service, DATABASE_URL, OIDC configuration or Macus runtime
- **THEN** embedding and fake Unix/HTTPS client checks can complete without activating any of those services
