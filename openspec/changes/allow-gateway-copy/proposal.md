# Proposal

## Why

Copies between Incus servers are performed by the Incus daemons themselves. A client that holds access to both servers only introduces them: it asks one side for a one-time secret and gives the other side the address and certificate to dial (pull or push), or carries the data itself (relay). A gateway-fronted guest such as Macus therefore needs no copy operation of its own and holds no credentials for other servers. The official client or another controller drives the copy through the gateway, which advertises only its approved address and certificate and admits the peer server narrowly.

Instances and snapshots already work this way. Custom storage volumes and images do not:

- The pinned v7.0.1 `CopyStoragePoolVolume` requires `storage_api_local_volume_handling` (and `storage_api_remote_volume_handling` across servers), and `ExportImage` (push from the gateway) requires `images_push_relay`. The gateway's extension allowlist removes all three, so the client refuses these copies before any request.
- An image copy does not use an operation WebSocket. When the gateway is the pull source, the other server reads `GET /1.0/images/{fp}?secret=` and `GET /1.0/images/{fp}/export?secret=`. When the gateway is the push target, the other server uploads with `POST /1.0/images` carrying `X-Incus-secret` and `X-Incus-fingerprint`, then waits on `GET /1.0/operations/{id}/wait?secret=`. The gateway admits an untrusted server peer only to the operation WebSocket, so it refuses both orientations.

## What Changes

- Add `storage_api_local_volume_handling` and `storage_api_remote_volume_handling` to the WebSocket-dependent extension allowlist, and `images_push_relay` to the HTTP allowlist. The host must still approve them and the verified backend must support them.
- Add an optional host callback, `admit_image_secret/2`, called only after `authorize/2` returns unauthenticated and only for the four exact image secret routes above, with no all-projects selection. Requests gain an `image` field naming the route and fingerprint; the secret is not copied into it. Missing callbacks deny, so existing hosts keep refusing these routes until they opt in. The backend still validates the secret, and the original request is relayed unchanged.
- Verify volume copy and image copy in relay, pull and push modes with gateways in front of both servers, using the unchanged pinned client and the unchanged pinned client calls incusd makes for the server-to-server leg.

## Capabilities

### Modified Capabilities

- `incus-gateway`: "Cross-server migration parity" covers custom storage volume copy and image copy. "Operation-secret peer admission" also allows the exact image secret routes through a separate host decision.

## Impact

- `Opsmaru.Incus.Gateway.Identity` can advertise three more extensions. `Opsmaru.Incus.Gateway.Request` gains `:image`. `Opsmaru.Incus.Gateway.Host` gains the optional `admit_image_secret/2`. `Opsmaru.Incus.Gateway.Policy` recognises the image secret routes.
- No default changes: without the new callback, the image secret routes stay refused, and the extensions are advertised only when the host approves them.
- Macus must implement `admit_image_secret/2` against its own pending image transfers to allow pulls from it and pushes into it.
