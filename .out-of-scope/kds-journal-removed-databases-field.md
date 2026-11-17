# A `removed` field in the KDS unload journal is out of scope

- Decided: 2026-11-17 · by devil ([ADR 0055](../docs/adr/0055-the-kds-unload-journal-is-per-tab-keyed-by-every-base-it-may-land-on-and-never-regresses-an-acked-record.md))
- Holds while: [ADR 0051](../docs/adr/0051-an-object-database-is-never-deleted-by-a-stale-or-empty-read-and-stays-cached-locally.md) holds, so that an object database is never deleted by a stale read.

## The concept

Design J1 listed `removed: dbKey[]` in the journal. When applied (J2), it would delete those databases from the stored copy.

## Why not

- The journal is read on a later load, possibly by another tab, and possibly over a base that other tabs touched since. That is a stale capture by construction.
  A delete driven by it is the deletion path ADR 0051 forbids.
- No producer exists. The design names no edit that removes a database from the KDS in the unload window.
- Without the field, the worst case is a database the user deleted in the last ≤ 3 s that comes back. That is the safe direction under ADR 0051: a resurrected database, never a lost one.

## Prior requests

- 2026-11-17 (osionos main session, journal design J1/J2): proposed, rejected.

## Reopen when

A user-visible database delete is shown to happen inside the unload window, and it is carried as a tombstone with its own base check, not as a bare key list.
