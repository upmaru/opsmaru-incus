# Incus reference attribution

The generated declarations in `priv/incus/inventory.json` derive from the
official [lxc/incus](https://github.com/lxc/incus) source at commit
`13f3992766142d5087fff2e362cd2e1a75294fe8` (v7.0.1).
Incus is licensed under Apache-2.0; its unmodified `COPYING` is included here
as `incus-APACHE-2.0.txt`. Upstream has no separate NOTICE file at this revision.
The original source and contributor history remain available at that commit.

Macus transforms declarations into an inventory with source paths, line
numbers, signatures, source hashes, build constraints and evidence slots.
These additions are Macus verification data. No upstream implementation is
installed as a runtime sidecar, and this inventory does not establish parity.
