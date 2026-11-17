# Evicting inside a workspace page cache (content first, or a page subset) is out of scope

- Decided: 2026-11-17 · by devil ([ADR 0056](../docs/adr/0056-the-localstorage-page-cache-rotates-whole-workspace-keys-under-a-ceiling-and-never-leaves-a-durable-write-less-room-than-today.md))
- Holds while: a metadata-only page PATCH carries no precondition and the bridge accepts a past `updatedAt`

## The concept

Make the osionos page cache rotate at a finer grain than one workspace: drop page bodies before page
metadata, or keep only the most recently used pages of a workspace, so that a large active workspace
still fits in localStorage.

## Why not

- A cached page whose body is stripped gets a new stamp (`∅` instead of the content hash,
  `src/store/sync/pageStamp.ts:74-88`). So it is no longer the stamp the ledger confirmed, and the page reads as unclean.
- An unclean page refuses a newer metadata-only row from another device (`mergeServerPages.ts:53-61`).
  The outbox then PATCHes its stale title, parent and properties without `baseVersion` (`pageOutbox.ts:102-108`).
- The bridge writes that PATCH as the legacy request and accepts the past `updatedAt`
  (`scripts/bridge-api.mjs:877-883,4586-4595`). The server row moves back in time, and the two devices diverge silently.
- Probe P1a in `/mnt/storage/dlesieur/scratch/devil-ls-budget/` shows the client half end to end.
  Whole-key eviction (P1b) does not have the problem.

## Prior requests

- 2026-11-17 (localStorage budget plan, open question 1): "ordering inside the active workspace (content
  bodies before metadata?)".

## Reopen when

A page with no user edit can no longer publish metadata without a precondition the bridge checks. That
means the bridge refuses a metadata-only PATCH that is older than the stored row, or the client sends a
version for metadata writes. That change needs its own ruling.
