# Task 3.9 closure ledger

Task 3.9 is open. This ledger records remaining behavior, not an exception that
closes the task. The unchanged reference is Incus v7.0.1 revision
`13f3992766142d5087fff2e362cd2e1a75294fe8`. Real Incus acceptance is task 4.3;
installed Macus gateway/runtime/hardware acceptance remains consumer-owned.

The declaration manifest currently has 883 partial and 397 missing entries.
Declarations include Go methods, interfaces, types, constants and transport
abstractions; these counts are not endpoint counts or complete parity evidence.
No partial mapping is promoted to completion by this continuation.

Verified in this continuation: the four response metadata extraction helpers,
operation-to-certificate/cluster token conversion and both token String helpers,
and the five EventListener lifecycle helpers. Permanent unchanged-native
differential drivers and independent failure/budget/owner-cleanup fixtures are
linked from `priv/incus/coverage.json`.

Remaining groups:

- Full copy/cross-cluster option matrices, negotiation and relay failure cleanup.
- Full SFTP protocol helpers beyond the native raw byte connections.
- Context/disconnect conveniences, operation and remote-operation handlers/waits.
- Full dynamic console callback/IO and recorded exec-output helpers.
- OCI and SimpleStreams protocols, backup variants, remaining model/JSON/YAML helpers.
- Per-entry supported-scope classification and meaningful complete-evidence gates
  in the coverage generator/tests; they currently intentionally emit partial/missing.

## OCI scope decision pending

The approved design excludes host commands and keeps platform behavior at the
host boundary. The pinned `client/oci_images.go` has `exec.LookPath("skopeo")`,
external process execution, a root requirement for `GetImageFile`, and private
temporary image conversion directories. A literal runtime port conflicts with
those constraints. Its 20 concrete OCI method declarations remain missing.
SimpleStreams is a separate protocol and is not excluded by this finding.

The user has been asked to choose an explicit host-adapter design and acceptance
contract for OCI, or an explicit foundation-scope exclusion. No answer or elapsed
time constitutes approval. No OCI commands, root execution, conversion state,
new host adapter or scope exclusion have been implemented.

## Closure gate

Every supported remaining behavior needs implementation and pinned differential
or independent protocol evidence, including errors, extension checks, project/
member selection, operation identities, credential redaction, bounded queues/
deadlines/streams and cleanup. Possibly accepted mutations must never be replayed.
Keep the approved coalesced-byte oracle exception and local-wait-no-cancellation
contract visible. Then run macOS/Linux library checks, immutable consumer build,
strict Credo/precommit, isolated canonical checks, strict OpenSpec and Greptile.
Only after those gates pass can the task checkbox be updated. Backend/hardware
acceptance stays separate and cannot substitute for missing client evidence.
