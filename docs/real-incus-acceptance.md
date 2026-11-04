# Opt-in direct Incus acceptance

Task 4.3 passed on 2026-10-12 against a fresh isolated Incus 7.0.1 backend.
The portable runtime under test was published revision
`2b308f8487a88cfd5b5397b505d61c044c317b19`. This is direct-client evidence,
independent of the proposed gateway and remaining task 3.9 coverage.

The user explicitly authorized using installed Macus to start this backend.
Installed Macus `0.0.0-dev.20261009035620.fd8d1c761376` owned a new private
state directory and Apple VM. No Macus source, default state, launch agent or
workload was changed. The Unix address came from the isolated client's
`incus remote list`; it reaches Incus through Macus's existing private byte
bridge. HTTPS connected directly to the guest's native TLS listener, with
an isolated client certificate/private key and exact server-certificate pin;
hostname verification remained enabled. The installed CLI was 7.5.1, but the
backend and unchanged differential reference were both 7.0.1.

Both transports independently verified:

- Typed project/storage inspection and native 404 errors.
- Creation of project-isolated custom filesystem volumes, conditional updates,
  and native 412 rejection of a stale ETag. Incus volume ETags include name,
  type and config; description alone does not change the ETag.
- Native file upload/download of 140,000 bytes containing NUL, non-UTF-8 and
  newline bytes, with mode `0640` preserved. SHA-256:
  `00c64059547b9a9adf84c84fc529417387c586d2dda1805da8e2687a54e1eaa9`.
- Accepted snapshot operation identity, authoritative completion via polling,
  and a native WebSocket operation event with the same ID.
- Completed snapshot deletion and explicit cleanup limited to the successful
  run's resources. Project absence was then verified over HTTPS.
- No Opsmaru application supervisor, Endpoint or Repo running throughout.

The final runner passed in project `opsmaru-acceptance-20261012-direct-v4`.
Its successful snapshot operations were
`/1.0/operations/b55069d9-3a6f-415f-8c1f-3201ddcabe02` (Unix) and
`/1.0/operations/d6ab78f1-cedb-42a8-8731-0058e722f0d3` (HTTPS).
The previous successful v3 run independently exercised the same matrix.
Two earlier failed runs retained their projects and volumes: the first exposed
the ETag test assumption; the second used the wrong transfer result field in
the runner. Neither was a portable-client failure. Their retained state and
journals remain available to the operator; no cleanup runs after failure.
Wrong-hostname rejection also passed in the separate live read-only preflight.

## Reproducing on an explicitly approved isolated backend

`scripts/accept-incus.exs` does not launch a backend, generate credentials,
discover remotes, use default configuration, or run as part of ordinary checks.
The host prepares an isolated backend, verified TLS identity and private files.
Provide a private JSON configuration file containing these required fields:

```json
{
  "allow_namespaced_mutations": true,
  "project": "opsmaru-acceptance-unique-run",
  "report": "/absolute/private/run/report.json",
  "socket": "/absolute/private/incus.sock",
  "https": "https://verified-incus-host:8443",
  "server_certificate": "/absolute/private/server.crt",
  "client_certificate": "/absolute/private/client.crt",
  "client_key": "/absolute/private/client.key",
  "expected_version": "7.0.1",
  "pool": "explicit-approved-pool"
}
```

Use a fresh unique project and report path; the runner refuses an existing
report or a project present through either transport. Before mutation it also
requires matching server certificate pins and server names. After creating its
project through Unix, it requires the unique run marker to be visible through
both transports before either volume suite; copied certificates alone cannot
substitute for shared backend state. Credential contents are never printed. The report records
request intent/outcome and known operation URLs for reconciliation, without
automatic retry or failure cleanup. Request deadlines are 10 seconds, stream
lifetimes 30 seconds and stream capacity 2 MiB. Event collection is bounded
by time and 128 messages. Only the successfully verified run is cleaned up.

```sh
OPSMARU_ACCEPTANCE_CONFIG=/absolute/private/run/config.json \
  mise exec -- mix run --no-start scripts/accept-incus.exs
```

Host DNS must resolve the verified hostname. The local run used a private
process-local Erlang `inetrc`, without modifying system DNS. Private state,
credentials and raw journals are ignored and are not committed.

## Shared operations (add-incus-operations task 4.2)

Passed on 2026-11-04 over Unix only, with the user's explicit opt-in, against
the user's Macus appliance at `unix:///Users/zacksiri/.tama/incus-mac/incus.sock`:
Incus 7.0.1 on guest kernel `6.18.60-0-lts` with a ZFS default pool, booted
from the requalified pin in draft upmaru/macus#10. The library under test was
`69d893a991cbe89e569ca281460202860fbebeba`; the runner carried only the fix
below. HTTPS was not exercised. Before the run an Alpine 3.24 container image
(`502c4d50dd5f`) was imported into `default` as `opsmaru-acceptance-alpine`
and deleted after the pass.

Run `opsmaru-acceptance-20261104-ops-v2` passed all 16 journaled steps and was
cleaned: inspection; a project denial without backend access; instance create
and start (`08598418-f721-4679-b769-e173ee6e4892`) then `incus_operation_get`
and `incus_operation_wait` by that ID; exec with stdin, stderr and exit 3
(`ef2f9dc3-4886-45d7-82ee-0e347c0faf9d`), a 100,000-byte stdout truncated to
64 KiB (`8ce06e7d-c561-418e-823d-b7411e450685`) and `sleep 60` killed at 2 s
with exit 137 (`56069d9e-559a-4fdd-80af-efb921a64a4e`); snapshot create, a
refused restore with `confirm: "yes"`, then a confirmed restore and snapshot
deletion; forced stop and confirmed instance deletion.

The first run, `opsmaru-acceptance-20261104-ops-v1`, stopped at its second step
because the runner sent `project` to `incus_project_get`, which takes none
(schema rejection, no backend request). That was a runner bug, fixed before
v2. As with the foundation runs, its failure state was kept: the empty project
remains for the operator.

`scripts/accept-incus-operations.exs` exercises the
shared operations through `Opsmaru.Incus.Operations.run/3` with a fixed
acceptance host binding, over Unix and, when `https` is given, verified HTTPS:
server/project/instance inspection, a project denial that never reaches the
backend, instance create and start with native operation polling by ID, bounded
exec (stdin, exit status, 100,000-byte truncation and a killed 2 s timeout),
snapshot create, a refused and then a confirmed restore, confirmed snapshot
and instance deletion. The configuration uses the fields above (without
`pool`) plus `image`, a local image alias in the default project; the run
project shares the default project's images and profiles. Requests may take
65 s so the tools can use their full 60 s wait. Each step is journaled to
`report`; nothing is retried and failures keep their state.

```sh
OPSMARU_OPERATIONS_ACCEPTANCE_CONFIG=/absolute/private/run/config.json \
  mise exec -- mix run --no-start scripts/accept-incus-operations.exs
```

This is separate from fixture, consumer, Macus composition and hardware
evidence, and tool success never counts as client coverage.

## Separate gates

- [x] Foundation 4.3: direct native inspection, mutation, operation and stream
  behavior over Unix and verified authenticated HTTPS.
- [x] Foundation 3.9: complete remaining supported client/model/helper coverage
  (closed by the 2026-11-03 closing review in `docs/task-3-9-closure.md`).
- [ ] Installed OCI/delta conversion adapter acceptance.
- [x] Shared operations acceptance (`add-incus-operations` task 4.2), Unix only; HTTPS not exercised.
- [ ] Embeddable gateway acceptance.
- [ ] Macus Elixir integration, packaging and full hardware/guest acceptance.

Starting this isolated installed Macus runtime establishes the test environment;
it does not close Macus's independently owned integration or hardware plans.


The strengthened preflight also passed a complete isolated v5 run after Greptile
review. Three private divergent-backend entrypoint regressions verify rejection
before foreign mutation. These remain fixture evidence; the v5 binary, operation
and event assertions ran against actual Incus independently.


The finalized runner passed again at immutable published runtime
`27c2f87471e1033572734763524d7a4158340652`, in project
`opsmaru-acceptance-20261012-direct-v6`, with matching backend identities, dual
project absence and the cross-transport run marker verified before volume work.
Successful snapshot operation IDs were
`/1.0/operations/ed60799a-52ad-4530-a33b-82b0c331d251` (Unix) and
`/1.0/operations/955f31b5-19d6-4d11-bac9-ef9d4b22efdb` (HTTPS).
Both 140,000-byte binary transfers and operation-event/completion assertions
passed, and v6 resources were explicitly cleaned. The separate Macus and
installed-converter gates are unchanged.
