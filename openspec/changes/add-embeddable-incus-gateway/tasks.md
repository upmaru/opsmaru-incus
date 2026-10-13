# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Foundation task 3.9 stays independently owned and direct real-backend task 4.3 is already complete; neither is affected by this change. Moved from `upmaru/opsmaru` on 2026-10-13. Installed Macus integration/hardware is separate consumer work.

## 1. Passive component and reference fixtures

- [ ] 1.1 Define/document the immutable Gateway configuration and host callback contract under Opsmaru.Incus.Gateway; verify dependency loading/configuration with PHX_SERVER/PORT starts no endpoint/listener/state/credentials/backend, requires no Macus runtime, and that Plug/Cowboy stay optional so client-only consumers compile without them.
- [ ] 1.2 Implement explicitly host-started bounded admission/worker supervision and redacted diagnostics; verify capacity rejection, callback deadlines, caller loss and restart cleanup cannot contact unauthorized backends, leak configuration or affect another host/runtime.
- [ ] 1.3 Transfer/adapt reusable native gateway/upgrade fixtures with source hashes and notices; verify the existing Incus v7.0.1 pin, altered-source detection and fake Unix/verified HTTPS denial/framing fixtures without modifying Macus source.

## 2. Host policy, identity and native route mounting

- [ ] 2.1 Implement shared authorization/readiness/backend-binding enforcement for ordinary and raw-handler requests; verify zero backend connections for missing/invalid identity, absent policy, project/member/operation denial, caller substitution and delayed host readiness; document policy inputs and failure behavior.
- [ ] 2.2 Implement bounded allowlisted host discovery/identity callbacks and canonical root/API mounting; verify anonymous discovery is backend-free, advertised capabilities match verified backend/implemented gateway support, original encoded path/query survives forwarding and `/runtime`/`/mcp` host routes coexist without blanket body parsing.
- [ ] 2.3 Implement host trust/enrollment delegation and an isolated test-only certificate-policy host; verify native discovery/certificate wire shapes, authorized standard-client enrollment, gateway/backend credential separation and rejection of unenforced restricted-certificate claims; document that production trust storage remains host-owned.
- [ ] 2.4 Implement expiry/revocation checks through the common policy path; verify active HTTP/WebSocket/raw access stops within the documented maximum interval and cleanup neither opens a new backend nor cancels/replays native operations.

## 3. Native HTTP and binary relay

- [ ] 3.1 Implement passive streamed Unix/verified HTTPS HTTP relay preserving native status/error/ETag/operation identity and raw paths/queries; verify pinned request/response comparisons, wrong upstream trust/keys, connection isolation, duplicate end-to-end headers and unknown typed-method pass-through; document the supported transport contract.
- [ ] 3.2 Implement bounded binary upload/download, trailers and hop-by-hop/framing guards; verify archive/file byte hashes, slow-sink/source backpressure, oversized/malformed framing, response-header injection rejection and disconnect cleanup without full-body JSON/capture.
- [ ] 3.3 Implement truthful pre-commit failure and post-commit termination handling; verify mutation-response loss, deadline, redirects and malformed responses issue at most one mutation, preserve known native operation identity and never imply remote cancellation; document reconciliation limits.

## 4. Native WebSocket channels

- [ ] 4.1 Implement/document native WebSocket upgrade and bidirectional exec/console/control relay through host policy; verify official client negotiation, binary/text/control/exit semantics, wrong authorization and partial handshake failure cleanup without Phoenix Channel framing or POST replay.
- [ ] 4.2 Implement bounded events/migration WebSocket flow and owner/revocation cleanup; verify overflow, backpressure, silent deadlines, close races and approved operation/address negotiation, with explicit unsupported cases and no guest-address fallback or interference with unrelated requests.

## 5. Native SFTP/NBD upgrades

- [ ] 5.1 Implement/document the same-listener Cowboy dispatch and raw protocol-switch adapter; verify canonical route/method/protocol matching, shared auth-before-connect, HTTP/1.1 requirements, unsupported versions/bodies and safe upgrade-response headers while ordinary traffic reaches the host router.
- [ ] 5.2 Implement ownership transfer and raw duplex relay; verify unchanged pinned SFTP/NBD clients, exactly-once client/backend prefetched bytes, binary traffic, supported half-close, bounded blocked writes, revocation, deadlines and takeover cleanup using the approved coalesced-byte oracle exception.

## 6. Independent composition and portable acceptance

- [ ] 6.1 Publish a verified immutable gateway revision and add an independent Macus-compatible host consumer with no sibling checkout; verify its endpoint/router and Cowboy dispatch mount every supported protocol while the library stays passive, and document host composition.
- [ ] 6.2 Run unmodified pinned native client/CLI conformance with isolated INCUS_CONF and test-only trust against the host fixture; verify discovery/enrollment, HTTP and binary transfers, exec/console/events, SFTP/NBD, migration negotiation and denial/error paths, recording exact client/tool/source provenance separately from typed-client coverage.
- [ ] 6.3 Run macOS/Linux database-free fixtures, canonical checks, strict OpenSpec and Greptile; verify reports distinguish fixtures, immutable consumer, current method/type evidence and unrun installed/real-backend/hardware gates.
- [ ] 6.4 With the same explicit isolated real-backend opt-in, verify native CLI/client behavior through the mounted gateway for authorized operations and every supported protocol, plus denied requests and interruption/uncertainty cleanup; record a separate gateway report and leave unavailable tests unrun rather than claiming Macus installation or hardware acceptance.
