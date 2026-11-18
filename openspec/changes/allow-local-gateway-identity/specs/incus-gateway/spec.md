# Spec Delta

## MODIFIED Requirements

### Requirement: Gateway identity and trust isolation

Discovery, advertised gateway identity and certificate enrollment/trust SHALL be governed by host policy. Anonymous discovery SHALL be narrowly allowlisted, bounded and backend-free. Gateway credentials MUST NOT be forwarded as backend credentials, and guest trust MUST NOT authorize public gateway access. Advertised gateway addresses SHALL come only from the host's explicit identity, never from the backend. They SHALL be public unless the host declares a local gateway, which MAY advertise its own loopback and private-network addresses; unspecified, link-local, multicast and reserved addresses, socket names and paths MUST NOT be advertised in either case.

#### Scenario: Native remote enrollment

- **WHEN** a standard Incus client inspects or enrolls against the gateway
- **THEN** responses identify the host-selected gateway and its host-owned trust policy without enrolling guest trust or exposing guest addresses

#### Scenario: Advertised server addresses

- **WHEN** an authorized client reads `GET /1.0` through the gateway
- **THEN** `environment.addresses` and `environment.certificate` carry only the host-approved gateway addresses and certificate, and other environment fields stay native

#### Scenario: Local gateway identity

- **WHEN** a host that declared a local gateway supplies a loopback or private-network origin and addresses
- **THEN** discovery and `GET /1.0` serve that identity in place of the guest's, while a host that did not declare a local gateway is refused it with 503 before backend access
