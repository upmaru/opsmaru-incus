# Changelog

## 0.2.0 — 2026-11-16

opsmaru_incus now publishes its operations as `tama-operations/1` documents,
the profile [tama-dex](https://hexdocs.pm/tama_dex) indexes, and offers the
native client API beside the composite operations. See
`docs/incus-operations.md`.

```elixir
{:opsmaru_incus, "~> 0.2.0"}
```

### Added

- **Composite document.** `Opsmaru.Incus.Operations.Composite.openapi/0`
  returns the 32 composite operations as a `tama-operations/1` document
  (source `opsmaru_incus`), mapped field for field from the descriptors.
- **Native operations.** `Opsmaru.Incus.Operations.Native.openapi/0` returns
  274 native client methods as a second document (source
  `opsmaru_incus_native`), with operation IDs `incus_native_<snake_method>`.
  It is generated from the verified `methods.json` and `models.json` by
  `mix opsmaru.incus.native`; the pinned upstream `rest-api.yaml` supplies
  descriptions only and is not shipped.
  - Scopes are separate and never implied by the composite ones:
    `incus.native.read`, `incus.native.write`, `incus.native.delete` and
    `incus.native.admin`.
  - Every `DELETE` and `PUT` is destructive and requires `confirm` to repeat
    its target.
  - `Native.unavailable/0` lists the 33 methods that are not exported:
    interactive channels, binary transfers, and calls that select another
    backend or carry credentials. Body fields that could do so are removed
    from every exported schema.
- **Native execution.** `Operations.Native.run/3` applies the composite trust
  model (scope, schema, confirmation, restricted config, host `binding/2` and
  `authorize/3`) and then makes one native call. Background operations return
  their identity without waiting, a lost response is reported as `uncertain`
  and nothing is retried. Native success is never client evidence.
- **Release cassette.** Each release also publishes a tama-dex cassette,
  `opsmaru_incus-<version>.tama-cassette`, holding both documents, as a GitHub
  Release asset with its SHA-256 and a build provenance attestation. It is
  not part of the Hex package, and tama_dex is only a development dependency.
- **Optional HTTPS connection pool.** A host can start
  `Opsmaru.Incus.ConnectionPool` in its own supervision tree and pass
  `pool:` to `Connection.https!/2`. Buffered GET and HEAD requests then reuse
  verified sockets, keyed by owner, origin, credentials, trust and
  authentication requirement. It needs `{:nimble_pool, "~> 1.1"}` in the host;
  nothing starts unless the host starts it, and connections without `pool:`
  behave as before. This first slice pools only verified HTTPS buffered
  reads: mutations, Unix requests, gateway relays, streams and upgrades still
  open fresh connections. See `docs/incus-client.md`.

### Changed

- **Request-context cancellation is event-driven.** Request guards, channel
  watchers, `Operation.wait/2`, host adapter calls and SFTP sessions are
  notified of cancellation, owner exit and deadline instead of polling every
  20 ms. `RequestContext.status/1` and `check/1` and the reported outcomes are
  unchanged.
- **Operations module layout.** The 32 composite operations move from
  `Opsmaru.Incus.Operations` to `Opsmaru.Incus.Operations.Composite` (`all/0`,
  `describe/1`, `run/3`, `unavailable/0`, `scopes/0`, `fetch/1` and
  `output_schema/1`), with their implementations under `Composite.*`.
  `Opsmaru.Incus.Operations.Native` is the namespace for the native client
  operations. Shared infrastructure (`Operations.Host`, descriptors, schemas,
  results and evidence) stays under `Opsmaru.Incus.Operations`. Operation
  names, schemas, the `describe/1` data and `coverage.json` are unchanged.

- **Package contents.** The `priv/incus` files are listed one by one. The
  package gains `native-operations.json` and `native-policy.json` and never
  contains `rest-api.yaml`.
- `Opsmaru.Incus.Operations.Schema` resolves `$ref` into shared components and
  accepts the `number` type.

### Deprecated

- The 0.1.0 functions on `Opsmaru.Incus.Operations` are deprecated delegates
  to `Opsmaru.Incus.Operations.Composite`. They return exactly what
  `Composite` returns, warn at compile time and are removed in 0.3.0.

## 0.1.0 — 2026-11-11

First release of `:opsmaru_incus`, the portable native Incus library used by
Macus and central Opsmaru, published to Hex under the Apache-2.0 licence. Hex
is the only distribution route; Git revision pins are no longer documented.

```elixir
{:opsmaru_incus, "~> 0.1.0"}
```

### Included

- **Native Incus client** (`openspec/specs/incus-client`, `embedded-service`):
  explicit Unix-socket and verified HTTPS connections passed on every call,
  native routes, queries, ETags, errors, operation identity and
  streaming/upgrade semantics, and no replay of a possibly accepted mutation.
  It is a pure library with no application callback.
- **Shared Incus operations** (`openspec/specs/incus-operations`): 32
  agent-facing `incus_<resource>_<verb>` operations with JSON schemas, scopes
  and destructive-confirmation rules, run synchronously through the client.
  Hosts choose how to expose them. See `docs/incus-operations.md`.
- **Embeddable native gateway** (`openspec/specs/incus-gateway`): a host
  mounts it in its own Plug/Cowboy server under its own policy. It relays
  native HTTP, WebSockets (exec, console, events, operations) and SFTP/NBD
  upgrades on the host listener. It mediates gateway identity and trust,
  admits operation-scoped migration peers, and supports relay/pull/push
  instance and snapshot copy at pinned Incus v7.0.1 client parity. `plug` and
  `cowboy` stay optional, so client-only consumers compile without them. See
  `docs/gateway.md`.

### Fixed before release

- `incus_instance_exec` wrote all stdin before reading any output. A command
  that echoes its input could fill the bounded output frame queue (64 frames)
  first and lose its output and exit status. `Session.collect/4` now accepts a
  `:stdin` option that writes input while both outputs drain, and the
  operation uses it.

### Packaging

- Apache-2.0 `LICENSE` and `NOTICE`; upstream Incus, pkg/sftp and Macus
  notices ship in `priv/notices`.
- The package contains `lib`, the compile-time `priv/incus` data, the notices,
  `README.md` and `CHANGELOG.md`. `mise run check:consumer` now builds this
  package and verifies it in fresh host and client-only consumers.
- A `v*` tag publishes the package and docs through GitHub Actions.
- The development lockfile moves to cowlib 2.22.0, cowboy 2.21.0 and
  plug_crypto 2.2.1 for published security advisories. The package's version
  ranges already allow these, so consumers pick them up by updating their own
  lockfiles.

### Evidence and limits

- **Client coverage is partial.** `priv/incus/coverage.json` maps the
  pinned Incus v7.0.1 Go client: 1239 declarations are partial, 41 are missing,
  and `complete_port=false`. This release does not claim complete client
  parity.
- **Gateway evidence** is recorded per class in `docs/gateway.md`: portable
  fixtures and pinned-CLI conformance, the package consumer build on Linux
  and macOS, and an isolated real-Incus run (28 of 35 cases on 2026-11-09).
- **Accepted native limitations:**
  - Snapshot `move` with the pinned v7.0.1 CLI fails natively with
    `400 Invalid instance name`, and the gateway preserves that failure.
  - Live NBD is `unrun` and is planned for a later revisit.
- **Not covered here:** installed-host and Macus hardware acceptance belong to
  the consuming host. Production trust storage and issuance, host
  authorization policy, restricted certificates and asynchronous certificate
  tokens are host-owned or unsupported.
