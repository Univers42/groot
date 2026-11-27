# A signed removal for a machine the bridge does not know is out of scope

- Decided: 2026-11-27 · by devil (connector trusted-browser ruling, TB13)
- Holds while: the bridge can verify a heartbeat only against a stored `pubkey`, and losing a row is possible

## The concept

When a heartbeat names a machine id the bridge has no row for, the bridge would answer with a
bridge-signed "gone". The connector would then archive `machine.json` and stop. That would give
deleted accounts a clean local unpair too.

## Why not

- **Anyone could get one.** Without a row there is no `pubkey`, so the heartbeat signature cannot
  be checked (`scripts/bridge-machines.mjs:98-100`, osionos d9bc375ca). The bridge would then sign
  a removal for anyone who sends a machine id.
- **Lost rows are not removals.** A row can be missing because of:
  - a DB restore or a wipe
  - a beta pointed at an empty database
  - a wrong bridge URL

  Signing "gone" in those cases erases every pairing at once. That is P4, the failure the
  signed removal exists to end.
- **Erasure deletes rather than revokes.** Account erasure deletes the row
  (`models/osionos-machines-migration.sql:69` cascade, `models/osionos-account-erasure-migration.sql:373`).
  So "unknown" cannot be told apart from "lost".

## Prior requests

- 2026-11-27 (connector trusted-browser design, D3): the design itself kept unsigned 410s for
  unknown rows. The ruling asked whether that should change.

## Reopen when

The bridge keeps a revoked tombstone, holding the id and `pubkey`, for every removed or erased
machine for at least one heartbeat window. Then a gone can be signed after verifying the
heartbeat, and a missing row truly means "never existed here".
