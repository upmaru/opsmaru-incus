# Spec Delta

## MODIFIED Requirements

### Requirement: Cross-server migration parity

Instance and snapshot copy/move and custom storage volume copy SHALL work through the gateway in relay, pull and push modes, with the gateway as source or target, as the pinned v7.0.1 Go client negotiates them. The gateway SHALL advertise the storage volume migration extensions only when its WebSocket adapter is present and the host approves them. Endpoints derived from the gateway connection SHALL resolve only to host-approved public gateway addresses. Guest-side reachability failures SHALL be reported natively without retrying through another address.

The pinned v7.0.1 CLI's unsupported snapshot `move` SHALL preserve its native `400 Invalid instance name` failure before any migration mutation, retaining the source. These cases SHALL be recorded as native limitations separately from successful transfers and count as pinned native parity, following the explicit user decision on 2026-11-07. The gateway SHALL NOT synthesize a compensating copy or deletion.

#### Scenario: Pull copy from the gateway

- **WHEN** an authorized client copies an instance in pull mode from a gateway-fronted source to another Incus server
- **THEN** the target server connects to the gateway's public address, is admitted to that operation's WebSocket only by host policy and the copy completes without any guest address being offered

#### Scenario: Pinned CLI snapshot move limitation

- **WHEN** the unchanged pinned CLI attempts snapshot `move` in relay, pull or push mode with either gateway orientation
- **THEN** the native invalid-instance-name error is preserved before any migration POST or DELETE, and the case is reported as an upstream CLI limitation with the source retained

#### Scenario: Volume copy through gateways

- **WHEN** an authorized client copies a custom storage volume in relay, pull or push mode between two gateway-fronted servers
- **THEN** each side receives one migration request, the peer server reaches only the named operation WebSocket by host admission, and both sides advertise only their gateway addresses and certificate
