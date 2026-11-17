# Compacting the page outbox ledger (a circular buffer, dropped entries, shorter stamps) is out of scope

- Decided: 2026-11-17 · by devil ([ADR 0056](../docs/adr/0056-the-localstorage-page-cache-rotates-whole-workspace-keys-under-a-ceiling-and-never-leaves-a-durable-write-less-room-than-today.md))
- Holds while: a missing or different ledger stamp makes a page publish, and a metadata-only PATCH has no precondition

## The concept

Bound `osio:pages:outbox` (789,580 characters, 4,064 entries on the live Firefox profile, 2026-11-17).
The options are to drop the entries for pages the server already holds at the same stamp, to keep a
fixed-size ring of entries, or to hash each stamp to a few characters.

## Why not

- Every ledger entry is a stamp the server has confirmed. The ledger advances only on a confirm
  (`src/store/sync/pageFlush.ts:104`). So "the server already holds it" describes every entry.
- A dropped entry makes its page unclean (`computeSyncActions`, `packages/outbox-ledger/src/index.ts:96-109`):
  - a content page is republished, a storm across up to 4,064 pages;
  - a content-unloaded page sends stale metadata with no precondition, which the bridge accepts
    (probes P1a and P1d, `scripts/bridge-api.mjs:877-883`).
- A shorter stamp format makes every tab still on the old code read each stamp as different. That is the
  same storm, the C3b5 R5/R7 class.

## Prior requests

- 2026-11-17 (localStorage budget plan, L4 and open question 5): "byte cap + compaction for the outbox
  ledger", pending since an earlier "circular buffer" request.

## Reopen when

Both of these must hold:
- the metadata-PATCH precondition named in ADR 0056 has landed;
- a measurement after L0 shows that the ledger threatens a durable write. The ledger is about 15 % of the
  quota after L0, and grows by about 194 characters per editable page.
