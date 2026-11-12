# Macus fixture attribution

`test/support/gateway/cowboy_upgrade_fixture.ex` is adapted from
`server/test/support/cowboy_upgrade_fixture.ex` in
[upmaru/macus](https://github.com/upmaru/macus) at commit
`5a8fb236dfbed28e513b6789b18f0f6ee6e7fbc0` (Macus task 1.5, the fixture-only
Cowboy protocol-switch trial). Macus is licensed under MIT; its unmodified
`LICENSE` is included here as `macus-MIT.txt`.

Module namespaces were changed, and the tunnel later moved each relay direction's
writes into its own process so a peer blocked writing one way cannot deadlock the
other (seen on macOS CI). Source and transferred SHA-256 digests are
recorded in `priv/incus/gateway-transfer.json` and checked by
`test/gateway_fixture_transfer_test.exs`. The fixture is test-only protocol
evidence: it uses a fixed fixture client certificate, not Macus policy, trust
storage or production gateway code, and it is not compiled into the library.
