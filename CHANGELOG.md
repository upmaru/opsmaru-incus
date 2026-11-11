# Changelog

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
