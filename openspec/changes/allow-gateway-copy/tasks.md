# Tasks

## 1. Volume copy through the gateway

- [x] 1.1 Add `storage_api_local_volume_handling` and `storage_api_remote_volume_handling` to the WebSocket-dependent extension allowlist.
- [x] 1.2 Verify with the unchanged pinned `CopyStoragePoolVolume` that a custom volume copies in relay, pull and push modes with gateways in front of both servers, that both sides advertise only the gateway addresses and certificate, that each side receives exactly one POST and no DELETE, and that pull and push admit the peer server only to the named operation WebSocket.
- [x] 1.3 Verify that interrupted volume source and target migration requests are reported as uncertain and never replayed or cancelled.

## 2. Image copy through the gateway

- [x] 2.1 Add `images_push_relay` to the extension allowlist.
- [x] 2.2 Add the `:image` request field (route, fingerprint and decoded secret) and the optional `admit_image_secret/2` host callback for exactly `GET /1.0/images/{fp}?secret=`, `GET /1.0/images/{fp}/export?secret=`, `POST /1.0/images` with one `X-Incus-secret` and one `X-Incus-fingerprint`, and `GET /1.0/operations/{id}/wait?secret=`. Verify that duplicate, empty or misplaced secrets, non-hex or overlong fingerprints, other methods, protocols, routes and all-projects selections never reach the callback; that explicit denial, a missing callback, malformed, raising and late results fail closed; that a granted request is still rechecked by `valid?/3`; that the operation WebSocket keeps its own callback; and that the request inspection redacts the secret. Document that the host must verify the secret because the backend trusts the gateway connection.
- [x] 2.3 Verify with the unchanged pinned `CopyImage`, and the unchanged pinned client calls of incusd's pull download and export push, that an image copies in relay, pull and push modes with gateways in front of both servers; that both sides advertise only the gateway addresses and certificate; that relay admits no server peer; that pull admits the target server only to the info and export routes and push admits the source server only to the upload and its wait; and that without the callback pull and push are refused before the peer reaches the backend.

## 3. Documentation and checks

- [x] 3.1 Document the extensions and the callback in `docs/gateway.md` and `Host`, add the CHANGELOG entry and run `mise run check` and `mise run check:reference`.
