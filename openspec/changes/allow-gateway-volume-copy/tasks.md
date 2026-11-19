# Tasks

## 1. Volume copy through the gateway

- [x] 1.1 Add `storage_api_local_volume_handling` and `storage_api_remote_volume_handling` to the WebSocket-dependent extension allowlist.
- [x] 1.2 Verify with the unchanged pinned `CopyStoragePoolVolume` that a custom volume copies in relay, pull and push modes with gateways in front of both servers, that both sides advertise only the gateway addresses and certificate, that each side receives exactly one POST and no DELETE, and that pull and push admit the peer server only to the named operation WebSocket.
- [x] 1.3 Verify that interrupted volume source and target migration requests are reported as uncertain and never replayed or cancelled.
- [x] 1.4 Document the extensions in `docs/gateway.md`, add the CHANGELOG entry and run `mise run check` and `mise run check:reference`.
