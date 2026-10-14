# Embedded library boundary

`:opsmaru_incus` is a pure library with no application callback, so it has no
supervision tree. Loading, starting or restarting it starts no process,
listener, Endpoint or Repo, creates no state, reads no keys and contacts no
backend. PHX_SERVER/PORT have no effect. There is no deployment mode to
configure and no dependency runtime.exs to evaluate.

A host supplies verified identity, authorization, private state references,
readiness and platform capabilities. These are values, not provisioning hooks.
No Opsmaru code invokes host capabilities or owns Swift/Incus lifecycle.
Configuration is per call, not a mutable global current remote:

```elixir
context = Opsmaru.Incus.Context.new!(
  owner: :macus,
  identity: verified_host_identity,
  ready?: fn -> MyHost.Identity.ready?() end,
  private_state: host_private_state,
  capabilities: %{runtime: MyHost.RuntimeAdapter}
)

connection = Opsmaru.Incus.Connection.unix!(
  host_private_incus_socket,
  owner: :macus,
  project: "default",
  timeout: 5_000
)

# Linux/remote consumer: host selects trust and client key references.
remote = Opsmaru.Incus.Connection.https!("https://incus.example:8443",
  owner: :macus,
  tls: [cacertfile: ca_file, certfile: client_cert_file, keyfile: client_key_file]
)

{:ok, client} = Opsmaru.Incus.connect(connection, context)
{:ok, response} = Opsmaru.Incus.raw_query(client, "GET", "/1.0/profiles")
# response.metadata is native Incus data; response.etag retains the native ETag.
```

Only the host constructs these trusted values. Owner mismatch or readiness
failure prevents backend contact. Authorization belongs to the host; this
context does not validate tokens. File references and identities are redacted
from Inspect; keep raw configuration maps out of logs.

Optionally add `{Opsmaru.Incus.ClientSupervisor, name: MyHost.Clients,
max_children: 8}` to your host tree and explicitly call
`Opsmaru.Incus.ClientSupervisor.async(MyHost.Clients, fn -> ... end)`. Capacity is
immediate failure, with no work queue or replay/recovery. A worker loss says
nothing about backend cancellation. Your existing endpoint and runtime remain
host-owned.

The namespace-cleanup revision exposes both helpers under `Opsmaru.Incus`.
Consumers adopting it update their context aliases and struct references to
`Opsmaru.Incus.Context`, and supervisor child specifications/calls to
`Opsmaru.Incus.ClientSupervisor`. Earlier revisions used top-level helpers under
`Opsmaru`; the new revision supplies no legacy compatibility modules. Construction,
readiness, owner isolation, redaction and explicit host supervision are unchanged.

`mise run check` formats, compiles warning-free, runs strict Credo, the
database-free fixture suite and strict OpenSpec validation. No database,
provider credentials, listener or real backend is involved.
`mise run check:reference` runs the Go inventory/schema verifier tests and the
generated constants check. Fixture evidence does not establish installed Macus
or real Incus acceptance.

## Immutable consumer dependency

Pin an implemented immutable revision of this repository:

```elixir
{:opsmaru_incus, git: "https://github.com/upmaru/opsmaru-incus.git",
 ref: "3c5d6b1f6a72a6dc73d999032eec6ae49be46a9c"}
```

`test/consumer/revision.txt` records the independently verified revision; its
`mix.lock` records the resolved Macus-compatible dependency set. Run
`mise run check:consumer` (or `python3 scripts/check-consumer.py`) to fetch it
in a fresh directory. An explicit `OPSMARU_INCUS_FIXTURE_REVISION` permits
verifying a newer pushed revision; no local path dependency is used. The
fixture's private Unix server is an independent fake backend, never an
installed Macus socket. Installation, bundled ERTS and real Macus hardware
acceptance remain owned by the consumer.

Revisions before the extraction were published from
[upmaru/opsmaru](https://github.com/upmaru/opsmaru) as the `:opsmaru`
application; those pins remain valid history but new consumers use this
repository.
