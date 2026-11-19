# Spec Delta

## MODIFIED Requirements

### Requirement: Cross-server migration parity

Instance and snapshot copy/move, custom storage volume copy and image copy SHALL work through the gateway in relay, pull and push modes, with the gateway as source or target, as the pinned v7.0.1 Go client negotiates them. The gateway SHALL advertise the storage volume migration and image push extensions only when the host approves them, and the volume extensions only with its WebSocket adapter. An image copy in which the gateway is the pull source or the push target SHALL also require the host image admission decision. Endpoints derived from the gateway connection SHALL resolve only to host-approved public gateway addresses. Guest-side reachability failures SHALL be reported natively without retrying through another address.

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

#### Scenario: Image copy through gateways

- **WHEN** an authorized client copies an image in relay, pull or push mode between two gateway-fronted servers whose hosts admit image peers
- **THEN** relay admits no server peer, the pulling server reaches only the source gateway's image info and export routes, the pushing server reaches only the target gateway's upload and its operation wait, and both sides advertise only their gateway addresses and certificate

### Requirement: Operation-secret peer admission

An untrusted Incus server peer SHALL reach only the operation WebSocket route of the named operation, or one of the exact image secret routes, only with the secret that route carries and only after an explicit host admission decision for that route family. The image secret routes are `GET /1.0/images/{fingerprint}` and `GET /1.0/images/{fingerprint}/export` with one `secret` query value, `POST /1.0/images` with one `X-Incus-secret` and one `X-Incus-fingerprint` header and no `secret` query, and `GET /1.0/operations/{id}/wait` with one `secret` query value, all without an all-projects selection. A host that makes no image admission decision SHALL keep these routes refused. The backend SHALL still validate an operation WebSocket secret. Because the backend treats the gateway's connection as trusted and does not check image secrets, the gateway SHALL give the host the decoded image secret and the host SHALL verify it against the backend's pending image operation before admitting. Because the backend picks the action of `POST /1.0/images` from the request body, the gateway SHALL refuse, before backend access, an image peer's upload whose body is empty or starts with JSON whitespace or `{`, so the peer can deliver only the image. Diagnostics SHALL redact every secret.

#### Scenario: Secret outside its operation

- **WHEN** an untrusted server peer presents an operation secret on any other route or for another operation
- **THEN** the gateway denies it before backend access

#### Scenario: Image secret not matching a pending transfer

- **WHEN** an untrusted server peer presents an image secret that does not match the host's pending image operation
- **THEN** the host denies it and the gateway refuses the request with 403 before backend access

#### Scenario: Image request in place of an upload

- **WHEN** an admitted image peer sends `POST /1.0/images` with a valid secret and fingerprint but a JSON image request as the body, under any content type
- **THEN** the gateway refuses it with 403 before backend access, and the same body from a caller the host authorizes itself is relayed unchanged

#### Scenario: Image secret without host admission

- **WHEN** an untrusted server peer presents an image secret and the host makes no image admission decision, denies it or fails to answer in time
- **THEN** the gateway denies it with 403 before backend access
