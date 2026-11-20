# Registering page shells as `SEED_PAGES` templates is out of scope

- Decided: 2026-11-19 · by devil (ADR 0064, PS18)
- Holds while: built-in templates are merged into the localStorage page cache, or POSTed as pages.

## The concept

The page-shells plan (Phase 2) adds 37 shells. Each is a `SeedPage` with `isTemplate`, registered through `src/data/templates/index.ts`, so the existing Templates gallery lists them with no extra work.

## Why not

- `SEED_PAGES` are merged into the page cache (`pageStore.actions.ts:66-69`). On the online path, an empty workspace gets them POSTed (`seedPages.ts:127-150`).
- The page cache is the ADR 0056 LRU, with a 1M-unit ceiling and 344,898 characters free measured. The byte size of 37 section-heavy shells is unmeasured. UNKNOWN = FAIL.
- A lazy code catalogue that the gallery reads directly costs 0 bytes of cache and writes no server rows.

## Prior requests

- 2026-11-19 (osionos main session): plan `delightful-dazzling-kay.md`, Phase 2.

## Reopen when

Either condition holds:

- built-in templates stop being written to the page cache and the server;
- a measured fresh-boot cache delta for the whole catalogue fits the ADR 0056/0060 budget with headroom.
