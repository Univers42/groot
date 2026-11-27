# DRAFT. The page list is measured before it is re-protocolled; any manifest rev is content-addressed, never a global counter

- Status: proposed (draft, unnumbered). devil 2026-11-23, osionos #243: S0 PROCEED-WITH-CONDITIONS; S1 BLOCK; S2–S6 BLOCK until S0 selects B (D3), then PROCEED-WITH-CONDITIONS P243-7–P243-22.
- Date: 2026-11-23
- Code read: osionos worktree `osionos-337` at 0bc73c127; groot models in worktree `groot-pv344`.
- Full ruling: `/mnt/storage/dlesieur/scratch/pv243/RULING.md` (findings F1–F12, conditions P243-1–P243-22, decision table D1–D5).

## Context

- `/api/pages/all` returns the full 22-column list with archived rows (`scripts/bridge-api.mjs:1714`, `:2968`).
- Measured by the coordinator on 2026-11-23, prod, read-only: the DB builds the list for 8,772 rows in 35 ms, 5,455,644 B. Four candidate columns hold 38 kB in total. 5,248 rows (60 %) are archived. Every row has `properties = []` and `collaborators = []` (scratch `s0-time.out`, `s0-columns.out`).
- The issue's 2.1 s is therefore not the row read. The split across PostgREST, the access filter, gzip, transfer and the client is unmeasured.
- A global sequence rev leaks the instance's write rate to every tenant. That was already BLOCKED for `version` (`DRAFT-page-version-344-ruling.md:26`).
- An authoritative apply always persists the whole workspace cache (`src/store/sync/applyServerPages.ts:56`). The page cache is dropped whole when it does not fit (`src/store/pageStore.helpers.ts:302-324`).
- Unknown when this was written: the 2.1 s split; whether the 8.7k cache survives a reload; whether any workspace used by people is near that size; the nudge rate.

## Decision

S0 measures first (P243-1–P243-4). B's routes and planner start only when decision rule D3 holds. If B starts, its rev is `H(canonical pageRowToEntry(row))`, computed in the bridge and shared by `/all`, `/manifest` and `/rows`, with no schema change. `row_rev` (S1) is re-submitted only under D4, and only with no counter visible across tenants and no rev repeated across rollback or restore.

## Alternatives considered

- **row_rev from a global sequence (design S1)**: BLOCK. It leaks the cross-tenant write rate, and a rollback, `setval` restore or a window with the trigger off makes revs repeat, so pages stay stale with no error.
- **Per-row counter**: BLOCK. A re-created id restarts the count (the #344 class), so it would need a second tombstone.
- **A, slim projection**: BLOCK as a fix. No heavy column was measured, and gzip already removes repeated key names.
- **Archived rows out of `/all`**: BLOCK (`.out-of-scope/page-list-omits-archived-rows.md`).
- **C, lazy tree**: not ruled. It is the route under D5.

## Consequences

The conditions are acceptance criteria: P243-1–P243-22 in the full ruling. The rules most likely to be skipped:
- P243-12: `missing` comes only from a proven read.
- P243-16: a no-change sync applies and persists nothing.
- P243-17: hydrate and nudge paths stay additive.
- P243-18: a page removed locally is not re-added by a sync that was in flight.
