# Removing the legacy KDS keys before the migration flag is stored is out of scope

- Decided: 2026-11-17 · by devil ([ADR 0054](../docs/adr/0054-the-kds-indexeddb-writer-reaches-develop-only-after-its-coverage-fixes-and-is-not-promoted-live-before-pagehide-survival-is-measured.md), re-ruling)
- Holds while: `decideInitialCopy` re-migrates an unretired legacy copy over a "migrated" IndexedDB copy (osionos `knownDatabaseDurableCopy.ts:128`)

## The concept

Proposed for N1b, an origin that refuses the `osionos.kds.idb` flag even after evicting the page caches:
remove `osionos.knownDatabaseState.v1` first to free about 4.6 M characters, retry the flag, then remove
`osionos.objectDb.pushed.v1`. If the flag still fails, the frozen legacy copy is gone anyway.

## Why not

- It creates, on purpose, the state that I6's flag-first order forbids: no flag and no legacy text.
  A load whose IndexedDB fails then starts in fallback-legacy from the seed. It writes the legacy key as soon as storage accepts writes again.
  The next IndexedDB load reads that key as an abandoned migration and re-migrates it over the "migrated" copy.
  The user's unpushed edits in that copy are lost. Devil test CAND (`scratch/devil-p1-2b/devil-p1-2b.test.ts:268`) passes at HEAD 6baab127e and fails under the candidate (mutation M12).
- It does not fix N1c either: the same test shape still loses the fallback session's edit.
- The residual it targets is already smaller than today's: today the frozen legacy copy is pushed on every load of such an origin.

## Prior requests

- 2026-11-17 (KDS→IDB P1, C2 re-rule): candidate raised by the main session, rejected.
- 2026-11-17 (ADR 0054 C7 re-rule): the cookie named under "Reopen when" was probed and blocked. A Chromium crash persists the removal before the cookie (`.out-of-scope/kds-migration-flag-in-a-cookie.md`). The in-place tombstone retires the state key without ever removing it first, so this candidate stays rejected.

## Reopen when

A retirement marker can be stored where a full localStorage cannot block it, and is on disk no later than the key removal, so that a fallback load is pull-only without the legacy keys. A cookie fails the second half. The in-place tombstone of ADR 0054's C7 re-rule meets both, and it makes this candidate unnecessary.
Alternatively, the redo rule no longer treats a legacy copy as newer only because it is unretired.
