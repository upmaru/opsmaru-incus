# Proposal

## Why

Copies between Incus servers are performed by the Incus daemons themselves. A client that holds access to both servers only introduces them: it asks the source for one-time operation secrets and gives the target the source's address and certificate (pull), or the reverse (push), or carries the migration channels itself (relay). A gateway-fronted guest such as Macus therefore needs no copy operation of its own. The official client or another controller drives the copy through the gateway, and the gateway's job is to advertise only its approved address and certificate and to admit the peer server to the named operation WebSocket.

Instances and snapshots already work this way. Custom storage volumes do not: the pinned v7.0.1 `CopyStoragePoolVolume` first requires the `storage_api_local_volume_handling` extension (and `storage_api_remote_volume_handling` for a cross-server copy), and the gateway's extension allowlist removes both, so every volume copy through the gateway fails in the client before any request. Volume migration uses the same operation WebSocket negotiation and the same peer admission as instance migration, which the gateway already implements.

## What Changes

- Add `storage_api_local_volume_handling` and `storage_api_remote_volume_handling` to the gateway's WebSocket-dependent extension allowlist. As with the instance migration extensions, the host must still approve them and the verified backend must support them.
- Extend the cross-server migration evidence to custom storage volume copy in relay, pull and push modes, with gateways in front of both the source and the target, using the unchanged pinned client. Endpoints stay the host-approved gateway addresses; no guest address is offered.
- Extend the interrupted-migration evidence to volume source and target requests: a lost backend reply or frontend disconnect is reported as uncertain and never replayed or cancelled.
- Document the extensions in `docs/gateway.md`.

Image copy through the gateway is not part of this change. Two of its orientations (the gateway as a pull source, and the gateway as a push target) need an untrusted peer server to reach image and operation routes other than the operation WebSocket, which "Operation-secret peer admission" does not allow.

## Capabilities

### Modified Capabilities

- `incus-gateway`: "Cross-server migration parity" covers custom storage volume copy alongside instance and snapshot copy and move.

## Impact

- `Opsmaru.Incus.Gateway.Identity` advertises two more extensions when the WebSocket adapter is present and the host approves them. No new route, admission rule, callback, wire shape or default changes.
- Hosts that approve these extensions let standard clients copy custom volumes to and from the guest.
