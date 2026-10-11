# Embedded library boundary

Opsmaru defaults to `:embedded`, supervising no children. Starting or restarting
the dependency does not start Endpoint, Repo, PubSub or a listener, create state,
read keys or contact a backend. PHX_SERVER/PORT have no effect in this mode.
Standalone is an explicit scaffold role; it is not an authenticated service.
The dependency's runtime.exs is not host configuration.

A host supplies verified identity, authorization, private state references,
readiness and platform capabilities. These are values, not provisioning hooks.
No Opsmaru code invokes host capabilities or owns Swift/Incus lifecycle.
Configuration is per call, not a mutable global current remote:

```elixir
config :opsmaru, :deployment_mode, :embedded

context = Opsmaru.Context.new!(
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

Optionally add `{Opsmaru.ClientSupervisor, name: MyHost.Clients,
max_children: 8}` to your host tree and explicitly call
`Opsmaru.ClientSupervisor.async(MyHost.Clients, fn -> ... end)`. Capacity is
immediate failure, with no work queue or replay/recovery. A worker loss says
nothing about backend cancellation. Your existing endpoint and runtime remain
host-owned. The library can be called without starting the Opsmaru application.

`mise run check:library` uses MIX_ENV=library, no Ecto alias, no standalone test
configuration and no database credentials. It compiles the same application
and runs isolated fixtures with no SQL setup. `mise run check` separately
checks the existing Phoenix scaffold and requires a dedicated test database.
Fixture evidence does not establish installed Macus or real Incus acceptance.

## Immutable consumer dependency

The independently verified implemented revision is:

```elixir
{:opsmaru, git: "https://github.com/upmaru/opsmaru.git",
 ref: "21c21932ea659ce7e2d6eb8448dee8c1270628d7"}
```

`test/consumer/revision.txt` records this revision; its `mix.lock` records the
resolved Macus-compatible dependency set. Run `python3 scripts/check-consumer.py`
to fetch it in a fresh directory. An explicit `OPSMARU_FIXTURE_REVISION` permits
verifying a newer immutable feature revision; no local path dependency is used.
The fixture's private Unix server is an independent fake backend, never an
installed Macus socket. Installation, bundled ERTS and real Macus hardware
acceptance remain owned by the consumer.
