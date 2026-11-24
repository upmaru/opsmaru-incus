# Spec Delta

## ADDED Requirements

### Requirement: Exchange telemetry

Every request that reaches a gateway adapter SHALL emit one `[:opsmaru_incus, :gateway, :exchange, :start]` event and exactly one `[:opsmaru_incus, :gateway, :exchange, :stop]` event when a host has attached a handler, for native HTTP relays, locally served discovery and trust, WebSocket and raw upgrades, and requests refused before admission. The stop event SHALL be emitted when the exchange actually ends, including when its owning process is killed, and SHALL report its duration, the body bytes moved in each direction, the HTTP status sent to the caller, how the request was admitted, an outcome that equals the gateway failure outcome when the exchange did not complete, and a reason from a documented closed set.

#### Scenario: Relayed request

- **WHEN** an authorized caller reads a native resource through the gateway
- **THEN** one start and one stop event are emitted, and the stop event reports the native status, `outcome: :ok`, `admitted_as: :caller` and the response bytes

#### Scenario: Refused before admission

- **WHEN** a request is refused because the host does not authorize it
- **THEN** one start and one stop event are emitted, the stop event reports status 403, `outcome: :not_sent` and `reason: :unauthorized`, and no backend is contacted

#### Scenario: Revoked WebSocket

- **WHEN** an established WebSocket exchange is ended because its grant was revoked and its relay is killed
- **THEN** exactly one stop event reports the lifetime of the exchange, the bytes moved before it ended and `reason: :revoked`

#### Scenario: Raw upgrade

- **WHEN** a raw SFTP upgrade is relayed through the Cowboy handler and the caller later closes the tunnel
- **THEN** one start event and exactly one stop event are emitted for it, although the request never entered the host's Plug pipeline

#### Scenario: Interrupted mutation

- **WHEN** a relayed POST is interrupted after request bytes may have reached the backend
- **THEN** the stop event reports `outcome: :uncertain` and the request is not retried

### Requirement: Bounded secret-free exchange metadata

Exchange event metadata SHALL contain only the documented fields: the gateway's host module, protocol, HTTP method, canonical request path, parsed project, target and all-projects selection, operation ID, peer address and port, the SHA-256 fingerprint of a presented peer certificate, admission kind, HTTP status, outcome, reason and a span correlation reference. Metadata MUST NOT contain the `authorization` header or any other header, the raw query string, operation or image secrets, request or response bodies, WebSocket frames, the host's grant or host configuration, backend addresses or credentials, or native and gateway error messages. A path the gateway refused as non-canonical or too long MUST NOT be emitted.

#### Scenario: Operation secret in the query

- **WHEN** a server peer opens an operation WebSocket with a `secret` query value
- **THEN** the events carry the path and the operation ID but neither the query string nor the secret

#### Scenario: Bearer credential

- **WHEN** a caller sends an `authorization` header
- **THEN** no event value contains the header or any part of the credential

#### Scenario: Unsafe path

- **WHEN** a request path contains a dot segment and is refused
- **THEN** the stop event reports `reason: :invalid_request` with no path

#### Scenario: Host grant

- **WHEN** a host returns a grant from `authorize/2`
- **THEN** no event value contains the grant or the host configuration

### Requirement: Passive exchange telemetry

Exchange telemetry SHALL be emitted only through the optional `:telemetry` dependency, and the gateway MUST compile and behave identically without it. Loading the library or building a gateway MUST NOT create a process, table, handler or state for telemetry, and no observer SHALL run for an exchange when no handler is attached. Emission and handler behaviour MUST NOT alter admission, authorization, relayed bytes, responses, deadlines, revocation or retry decisions, and a handler MUST NOT run in a process that holds a backend socket once the exchange has been admitted.

#### Scenario: No handler attached

- **WHEN** a host that runs `:telemetry` serves gateway requests without attaching a handler to the exchange events
- **THEN** responses are unchanged and no observer process is started for any exchange

#### Scenario: Raising handler

- **WHEN** a host handler raises on a stop event
- **THEN** the exchange it describes and later exchanges complete normally with the same wire behaviour

#### Scenario: Slow handler

- **WHEN** a stop handler blocks for longer than the exchange's idle timeout
- **THEN** the relay's backend socket is closed and its admission slot is released without waiting for the handler

#### Scenario: Client-only consumer

- **WHEN** a consumer without `:telemetry`, Plug or Cowboy compiles the library
- **THEN** compilation succeeds without warnings and no telemetry dependency is resolved
