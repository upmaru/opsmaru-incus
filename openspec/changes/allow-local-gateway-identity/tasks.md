# Tasks

## 1. Local gateway identity

- [x] 1.1 Add the validated `identity_scope` gateway option (`:public` default, `:local`) and check identity origins and addresses by scope. Verify that the public scope still refuses every local and private form it refused, that the local scope accepts loopback, private-network, `localhost`, `*.localhost` and single-label identities, and that both refuse unspecified, link-local, multicast, reserved and IPv4-mapped addresses, socket names, paths and non-HTTPS origins, all without backend access.
- [x] 1.2 Verify that a local-scope gateway serves anonymous and authenticated `/1.0` with only the host's loopback addresses and certificate in place of the guest's, and that the pinned official Incus client reaches a loopback origin.
- [x] 1.3 Document the option in `docs/gateway.md` and `Host.identity/2`, add the CHANGELOG entry and run `mise run check`, `mise run check:reference` and `mise run check:consumer`.
