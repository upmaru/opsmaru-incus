# Tasks

First implementation target. Existing scaffold checks are baseline evidence, not completion of the public library/client contracts below. All tasks start unchecked. No central database, OIDC provider, registry, connector, MCP tool or application task runner is required to complete this change.

## 1. Public library and safe embedding

- [x] 1.1 Define/document the public application/connection/context boundary on the existing app; verify actual embedded startup creates no endpoint/Repo/listener/credentials/state/backend contact with hostile PHX_SERVER/PORT settings.
- [x] 1.2 Implement explicit host configuration/readiness and bounded optional client supervision; verify delayed host startup or worker restart cannot invoke a backend or affect Swift/Incus lifecycle and multiple consumers do not inherit a global remote.
- [x] 1.3 Add a library-only test command/profile bypassing generated Ecto aliases and standalone test configuration; verify embedding/client fixtures run with PostgreSQL stopped and no DATABASE_URL/OIDC/server secrets while web checks remain separately documented.
- [x] 1.4 Document embedding and direct-call setup for Macus/Unix/HTTPS consumers; verify a minimal consumer supplies its own endpoint/backend/private secrets without Opsmaru activation, source-path assumptions or automatic workload setup.

## 2. Reference inventory and client transport foundation

- [x] 2.1 Transfer immutable Incus v7.0.1 reference inventory, source notices and reusable fixtures from Macus with provenance; verify hashes/regeneration and changed-entry detection while retaining Macus-specific proxy/bridge evidence.
- [x] 2.2 Implement fake Unix/HTTPS and pinned official-client differential fixtures; verify query/body/status/error/ETag and framing mismatches fail without starting a VM or live Incus.
- [x] 2.3 Implement typed codecs/errors and version/extension discovery in Opsmaru.Incus; verify optional/null fields, native error values and unavailable extensions against reference fixtures.
- [x] 2.4 Implement explicit connection values, native Unix/HTTPS requests, TLS server validation and protected client certificate/private-key use; verify wrong trust/keys, connection isolation, bounded deadlines/cleanup and absence of secret output without local trust generation or backend installation.
- [x] 2.5 Document public connection/API/coverage contracts and lock compatible transport dependencies; verify clean pinned builds and that client modules require no Macus/Swift, Phoenix endpoint, SQL, MCP or authentication service.

## 3. Canonical client behavior slices

- [x] 3.1 Port project/member selection, profiles and access/certificate methods; verify native parameters, conditional updates, errors and every affected reference entry.
- [x] 3.2 Port instance create/read/update/state/delete and snapshots/restore; verify native accepted handles, conflict/unsupported behavior and destructive request fidelity.
- [x] 3.3 Port image/alias/import/copy/export methods; verify streamed binary handoff, native operation metadata and coverage evidence.
- [x] 3.4 Port network/cluster methods; verify native member targeting/models/errors without adding a multi-target registry or workload scheduler.
- [x] 3.5 Port storage/volume/snapshot/bucket methods; verify reference models and native responses without implementing storage behavior.
- [x] 3.6 Port files/backups/native SFTP/NBD client upgrades; verify official wire comparison, coalesced handshake bytes, duplex binary traffic, half-close and cleanup independently of Macus proxy fixtures.
- [x] 3.7 Port operation wait/poll/supported cancellation and bounded events; verify local timeout versus backend cancellation, overflow/completion races and uncertainty without retrying possible accepted mutations.
- [x] 3.8 Port exec/console input/output/control streams; verify native exit status/control, bounds/backpressure and disconnect cleanup.
- [ ] 3.9 Port migration/copy and remaining reference entries; verify approved address/operation negotiation, transport-secret redaction and cleanup for every affected model/method.
- [x] 3.10 Complete and document the method/type evidence manifest; verify every supported entry has implementation/differential evidence before full-client acceptance and partial slices remain visibly incomplete.

## 4. Independent library and consumer acceptance

- [ ] 4.1 Run the database-free core checks and macOS/Linux protocol fixtures; verify no endpoint/Repo/listener/backend activation and separate embedding/client/stream evidence with exact dependency/reference provenance.
- [ ] 4.2 Add an external Macus-compatible Mix consumer fixture and document an actual immutable implemented dependency revision; verify a clean consumer build/call without sibling checkout or an Opsmaru process while source builds use their pinned toolchain and installed Macus runtime packaging remains consumer-owned.
- [ ] 4.3 With explicit isolated real-backend opt-in, prove native Unix/HTTPS inspection, mutation, operation and stream behavior; preserve Incus data and keep Macus VZ/installed-hardware acceptance separately owned and unchecked when unavailable.
