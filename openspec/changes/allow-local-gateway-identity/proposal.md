# Proposal

## Why

The gateway accepts host identity (`Host.identity/2`) only when its origin and every advertised address are public. It refuses literal loopback, private-network (RFC 1918, CGNAT, unique-local), link-local and unspecified IPs, `localhost`, `*.localhost` and single-label names, and answers `/` and `/1.0` with 503 "Gateway identity is unavailable". The rule exists so a guest's internal addresses can never be advertised as the gateway.

Macus serves its gateway on loopback by default (`https://127.0.0.1:8443`), the address its own CLI registers as an Incus remote, and on an explicitly configured LAN address otherwise. Native Incus advertises such addresses as a matter of course: `core.https_address` is usually a LAN or loopback address. With the current rule, every native route on Macus's default listener fails, and a LAN listener must invent a dotted DNS name. The host already supplies identity explicitly from its own configuration and the gateway never takes it from the guest, so a host-declared local gateway can safely advertise its own local addresses.

## What Changes

- Add a gateway option `identity_scope`, `:public` (the default, unchanged) or `:local`. A host sets `:local` when its gateway listens on loopback or a private network.
- With `:local`, the identity's origin and addresses may also be loopback (`127.0.0.0/8`, `::1`), private-network (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `fc00::/7`) literals, `localhost`, `*.localhost` or single-label host names.
- Both scopes still refuse unspecified, link-local, multicast and reserved IPs, IPv4-mapped IPv6 addresses, socket names, paths, user information and non-HTTPS origins.
- Guest metadata is still never advertised: authenticated `GET /1.0` replaces `environment.addresses` and `environment.certificate` with the host's identity in both scopes.
- Document the option in `docs/gateway.md` and the `Host.identity/2` callback documentation.

## Capabilities

### Modified Capabilities

- `incus-gateway`: "Gateway identity and trust isolation" allows host-declared local gateways to advertise their own loopback and private-network addresses.

## Impact

- `Opsmaru.Incus.Gateway` gains the validated `:identity_scope` field; `Opsmaru.Incus.Gateway.Identity` checks origins and addresses by scope. No other module, public function, wire shape or default changes.
- Existing hosts keep the public-only rule without changes. Macus sets `identity_scope: :local`.
