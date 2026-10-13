# Spec Delta

## Purpose

Provides one shared definition of Incus operations that hosts expose to agents, with host-supplied trust and truthful synchronous results.

## ADDED Requirements

### Requirement: Shared operation descriptors

The library SHALL define each supported Incus operation once with a canonical name, description, input/output schemas, required scope, destructive flag and bounds, executed only through the public Incus client. Descriptor names and schemas SHALL be stable public contract.

#### Scenario: Same contract in two hosts

- **WHEN** two hosts expose the shared operations
- **THEN** each operation has the same name, schemas, scope and confirmation rule in both

### Requirement: Host-supplied trust

Operations SHALL obtain their connection, context and authorization only from the host binding for an authenticated caller. Tool input MUST NOT select sockets, URLs, credentials, owner identity or host paths. Missing or failing host binding SHALL deny before backend access.

#### Scenario: Forged backend input

- **WHEN** tool input includes a URL, socket path or owner value
- **THEN** the input is rejected by schema or ignored for routing and no backend other than the host-selected connection is contacted

### Requirement: Scope and destructive confirmation

Each operation SHALL require its declared scope. Deletion and destructive restore SHALL additionally require explicit confirmation naming the affected resource. Denied calls MUST NOT reach the backend.

#### Scenario: Missing confirmation

- **WHEN** an authorized caller requests instance deletion without the matching confirmation input
- **THEN** validation fails and no request reaches Incus

#### Scenario: Read-only caller

- **WHEN** a caller with only the read scope invokes a mutation
- **THEN** it is denied with a stable permission failure before backend access

### Requirement: Truthful synchronous mutation results

Mutations SHALL execute synchronously within a bounded wait and report the native operation identity with completed, running, failed or uncertain status. Local timeout MUST NOT be reported as remote cancellation, and potentially accepted mutations MUST NOT be retried automatically. Durable task handles MUST NOT be advertised.

#### Scenario: Long-running create

- **WHEN** instance creation is still running when the bounded wait expires
- **THEN** the result reports the native operation identity as running and the caller can poll it with the operation tools

#### Scenario: Lost response

- **WHEN** the connection fails after a mutation may have been accepted
- **THEN** the result reports an uncertain outcome with any known operation identity and the mutation is not sent again

### Requirement: Bounded results and exec

Inputs, outputs, list sizes and deadlines SHALL be bounded per operation, with explicit truncation or failure when exceeded. Guest exec SHALL run only in an explicitly named instance with bounded arguments, input, captured output and duration and no interactive terminal.

#### Scenario: Exec output limit

- **WHEN** a command produces more output than the exec capture limit
- **THEN** the result is truncated with an explicit indicator and other requests remain responsive

### Requirement: Optional MCP binding

The library SHALL provide TamaMCP tool modules for the shared operations when `tama_mcp` is available, and SHALL compile without it. The binding MUST NOT start an endpoint, server, task store or process.

#### Scenario: Client-only consumer

- **WHEN** a consumer depends on the library without `tama_mcp`
- **THEN** it compiles and uses the client and descriptors without MCP modules or warnings

#### Scenario: Host composition

- **WHEN** a host includes the shared tool modules in its own TamaMCP server with its runtime tools
- **THEN** all tools are discoverable through one endpoint under the host's authorization and duplicate names fail compilation

### Requirement: Evidence-backed catalogue

Each exported operation SHALL record the client methods it uses and their verification evidence. Operations depending on client behavior without evidence MUST NOT be exported, and tool success MUST NOT count as client coverage.

#### Scenario: Pending client area

- **WHEN** an operation would require client methods still open in foundation task 3.9
- **THEN** it is not exported and the catalogue documents it as unavailable
