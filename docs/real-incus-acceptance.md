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
  MIX_ENV=library mise exec -- mix run --no-start scripts/accept-incus.exs
```

Host DNS must resolve the verified hostname. The local run used a private
process-local Erlang `inetrc`, without modifying system DNS. Private state,
credentials and raw journals are ignored and are not committed.

## Separate gates

- [x] Foundation 4.3: direct native inspection, mutation, operation and stream
  behavior over Unix and verified authenticated HTTPS.
- [ ] Foundation 3.9: complete remaining supported client/model/helper coverage.
- [ ] Installed OCI/delta conversion adapter acceptance.
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
