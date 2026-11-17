# `showcase` rebuilt from the osionos object-database definitions is out of scope

- Decided: 2026-11-17 · by devil ([ADR 0050](../docs/adr/0050-the-inception-mounts-move-to-a-vm-copy-on-its-own-internal-network.md),
  conditions SH1–SH17)
- Holds while: the `showcase` rows exist only on dlesieur42-3 and the user has not chosen a rebuild

## The concept

Recreate the 20 `showcase` base tables in the VM copy from the column definitions osionos still holds
(`osionos_object_databases`, keys `db-inception-live-showcase-*`), empty, so the 8 pages that read the mount
stop failing. A variant fills them with synthetic rows.

## Why not

- The 8 pages read 23 table names. Only 8 of them are among the 20 tables that can be rebuilt, and every
  page keeps at least one table that cannot.
- A covered block would show an empty table and totals of 0. Those look like real numbers. ADR 0050 rejected
  an empty `showcase` for that reason (IR8: silent data loss that looks healthy).
- The definitions hold column names and osionos property types. They hold no SQL types, keys, indexes or
  view text, so the rebuilt tables would be a guess presented under the original names.
- Synthetic rows would be invented data in a database the user knows by name.

## What runs instead

An empty `showcase` schema with one marker table, `_about_this_copy`, that says it is not a restore. The
mount answers; each block says its table was not found.

## Prior requests

- 2026-11-17 (plan SH1, option O1): 20 empty tables plus the marker.
- 2026-11-17 (plan SH1, option O2): O1 plus synthetic demo rows.

## Reopen when

One of these is true:

- the -3 disk, a dump of `showcase`, or the script that generated the Kestrel Harbor data is found. Restore
  from that instead;
- the user, told that a rebuild covers 8 of 23 tables and shows totals of 0, asks for it anyway. Synthetic
  rows also need their own plan and ruling, and a visible "invented" mark.
