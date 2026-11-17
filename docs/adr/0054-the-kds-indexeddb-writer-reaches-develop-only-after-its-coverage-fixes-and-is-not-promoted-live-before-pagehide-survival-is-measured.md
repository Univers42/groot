# 0054. The KDS IndexedDB writer reaches develop only after its coverage fixes, and is not promoted live before pagehide survival is measured

- Status: accepted. Re-ruled 2026-11-17 on 6baab127e: C1, C2 (amended done-when) and C3 are met, so the branch may merge to develop. Live promotion waits for C4, C5 and C7. C4 measured a loss (I10, 2026-11-17); the journal it requires is ruled in [ADR 0055](0055-the-kds-unload-journal-is-per-tab-keyed-by-every-base-it-may-land-on-and-never-regresses-an-acked-record.md), whose J-C7 replaces C4 as the live gate.
- Date: 2026-11-17
- Deciders: devil (ruling), osionos main session / builder (live with it)

## Context

Branch `feat/kds-idb-p1` moves the known-database state (KDS) and its push record from localStorage into IndexedDB `osionos-kds`.
It lives in the osionos worktree osionos-net-retry, range 4b6e8fdf2..967ef2e5d. It applies the D1 conditions I1–I13 (devil memory `osionos-kds-idb-d1-verdict`).
osionos develop ships live under a standing go. ADR 0052 (P1 design) is still owed by the main session. 0053 is the service-worker ADR.

- **The IDB writer has no opt-in.** Every tab whose IDB opens runs in `idb` mode. `osionos.kds.idb` only marks that the migration finished, and it is written as the legacy keys are removed (`src/widgets/database-view/model/knownDatabaseDurableCopy.ts:72-75,82-85`).
  A merge to develop therefore migrates every live tab at the next promotion. The migration is one way: the legacy keys are gone afterwards.
- The builder suite passes: `timeout 900 bash scripts/docker-run.sh test-canvas` on the 6 KDS files gives `# pass 33 # fail 0`.
- An independent devil port drives the real `openDurableCopy`, persistence and bridge sync with its own fake bridge. Result: `# pass 7 # fail 2`.
  B1a, B1b, B5, B2, B4 (original shape, server DB edited by tab B) and B3 push nothing stale. The two failures are N1 and N2.
- **N1, revert proved.** `retireLegacy` writes the flag with a plain `setItem` (`knownDatabaseDurableCopy.ts:73`) inside a try that swallows the error.
  On a full origin the write throws, the flag stays unset, and both legacy keys stay.
  A later load where IDB fails opens in fallback-legacy and pushes the old local DB over the server's newer copy.
  The same full origin already reverts today, so this is no regression, but the cure is incomplete. The writer that evicts page caches exists at `src/store/pageStore.helpers.ts:309`.
- **N2, revert proved with a forced commit loss.** The pagehide flush pushes the live state at once (`knownDatabasePersistence.ts:91`).
  If the IDB commit is lost in unload, the server holds b-2 and the stored copy holds b-1, which reads as dirty.
  On reload the stored copy is unioned with the server copy and pushed: the user's own newer edit is reverted.
  How often a real browser drops a pagehide IDB commit is not known; that is what I10 measures.
  The localStorage writer it replaces writes synchronously at pagehide for accounts whose state fits.
- **M4 is not covered by any test.** I mutated `pushLive` to push the last-flushed state instead of the live state. That is B5's guard (`knownDatabaseState.ts:666`).
  The full canvas suite still passes: `# tests 5545 # pass 5545 # fail 0`.
  The builder's harness defines its own `pushLive` (`tests/canvas/support/kds-tab.ts`), so the real wiring is never exercised.
- Mutation results. The suite catches M1 (no stored-id check), M2 (no liveRef check), M5 (no replaceState guard), M6 (export does not await readiness) and M8 (flagged sink pushes).
  It does not catch M3 (no pending/failed check); that check is redundant with liveRef because refs are immutable.
- In flagged mode, template instantiation still calls `ensureRegistered` and `rememberDatabaseWorkspace` (`templateDatabaseInstantiate.ts:31,35`) after a `replaceState` that does nothing (`:30`).
  The result is registry entries with no state behind them. The caller already catches a throw and shows a toast (`src/store/pageStore.actions.ts:797`).
- `knownDatabaseState.ts` is 707 lines, down from 736 at 4b6e8fdf2.
- Unknown when this was written: how often Firefox and Chromium drop a pagehide IDB commit, and the cold-start readiness p50/p95 (I10). Deviations #8 and #10 were not presented to the devil.

## Decision

The design and its I1–I13 implementation stand. B1a, B1b, B2, B3, B4 and B5 are closed by the real code.
The branch merges to develop only after C1–C3. It is promoted live only after C4.
Two routes satisfy C4: I10 has passed, or live promotion of osionos develop is suspended in writing until it does.
Edits made before readiness are dropped, not queued. I9 stands, the window is bounded by the 3 s budget (I8), and I10 measures it.

## Alternatives considered

- **Queue pre-readiness writes (deviation #1 rejected)**: a queue is a second, unjournaled copy of the state that is replayed after readiness. That replay is the stale-capture class that ADR 0051 and B5 exist to close.
- **Merge now under the standing go**: there is no opt-in, so this migrates every live tab one way, with N2 open and B5's guard untested by M4.
- **Add an opt-in flag and merge it dark**: an alternative route to C4, not required. It adds a knob that exists only for rollout, and it still needs I10 before the knob flips.

## Consequences

Conditions (acceptance criteria for the builder):

1. **C1, I2 coverage (before merge).** A canvas test fails when `pushLive` pushes anything other than the live state.
   Done when mutation M4 fails at least one test.
2. **C2, N1 (before merge).** The flag is written with page-cache eviction, and the legacy keys are removed only after the flag is stored.
   Done when the devil's N1 passes, plus a test with a quota-full legacy double that ends with flag `"1"` and both legacy keys gone, or with both legacy keys kept and no retirement claimed.
3. **C3 (before merge).** Template instantiation throws when the store is not writable, and the existing toast shows.
   Done when a test shows a flagged tab creates no registry or workspace entries.
4. **C4, I10 (before live).** Pagehide IDB commit survival is measured in Firefox and Chromium, N≥20 each, together with cold-start readiness p50/p95.
   Any measured loss ships the sync journal, and N2 becomes a regression test that must pass.
5. **C5, I12 (before live).** ADR 0052 names N1, N2 and the pre-readiness drop.
6. **C6.** A tracked issue covers splitting `knownDatabaseState.ts` (707 lines). This is not a merge blocker.

Further consequences:

- Promoting this unit live before C1, C2 and C4 hold turns this verdict into BLOCK.
- Reversal after migration is not one step. Migrated tabs have no legacy keys, so a pre-P1 build loads seed state, loses local edits that were not pushed, and reopens S1 (devil memory `osionos-kds-idb-p1-verdict`).

## Re-ruling, 2026-11-17, on 967ef2e5d..6baab127e

All results come from the scratch copy `devil-p1-2b/`, reset to HEAD for each run, with the network off.
The worktree `git status` was clean before and after.

- **C1 met.** The push now lives in `knownDatabasePersistence.ts:60-62,98,102`, so `kds-tab.ts` drives the real guard.
  M4 (push the flushed `state`) fails the builder's B1b and B5 (`known-database-revert-sequences.test.ts:83,88`): `# pass 38 # fail 2`.
- **C2 met, with an amended done-when.** `retireLegacy` (`knownDatabaseDurableCopy.ts:76-85`) writes the flag through `setItemEvictingPageCaches`, reads it back, and only then removes the keys.
  N1a (a full origin with page caches) passes in both the builder port (`known-database-legacy-retirement.test.ts:89`) and the devil harness.
  N1b, the verbatim N1 (every write refused, no page cache), still reverts. No eviction can cure it, so the done-when's second branch applies: both keys are kept and no retirement is claimed (`:66-74`).
  That test catches M11 (keys removed before the flag) and M12 (the candidate).
- **N1b is an accepted residual, and the candidate is rejected** (`.out-of-scope/legacy-kds-removal-before-the-migration-flag.md`).
  A fallback-legacy session runs today's localStorage code path. Today that path runs on every load of such an origin. Under P1 it runs only on loads where IndexedDB fails, and every IndexedDB load retries the flag (`:136`).
  The candidate removes the state key before the flag is stored. That deliberately creates the state I6 forbids: no flag and no legacy text.
  Under a transient refusal, devil test CAND loses an unpushed edit that was migrated into IndexedDB. The redo rule (`:128`) re-migrates the later fallback session's seed-based copy over the migrated copy. CAND passes at HEAD and fails under M12.
- **N1c, a new narrow loss path at HEAD (proved).** The flag is refused at migration. Session 1 commits. Session 2 runs on IndexedDB fallback, offline, and its storage writes succeed again, so its edit e2 goes to the legacy key.
  At session 3 the IndexedDB copy wins (no redo) and the now-storable flag retires the legacy key that holds e2. Result: e2 is lost, `{"local":["x-1"],"server":["x-1"],"legacy":false}`.
  It needs N1b's precondition: after evicting the page caches, the origin cannot store a 15-character flag.
- **C3 met.** `templateDatabaseInstantiate.ts:31-32` throws before any write. `pageStore.actions.ts:795-799` returns before `addPage`, so no page is created.
  The test is `template-database-read-only.test.ts:42`. M13 (no throw) fails it: `# pass 38 # fail 2`.
- **Deviation #8 accepted.** Readiness is a single source: `canWrite` derives from `mode` (`knownDatabasePersistence.ts:112`), and `mode` is set only in `applyLoaded` (`:84-90`). M5 and M6 are caught.
- **Deviation #10 accepted.** Devil test B5-2H triggers a second hydrate through the production `refreshAfterRefusal` path (a 409, `objectDatabaseBridgeSync.ts:122-124,236`) during an awaited commit. It passes at HEAD and fails under M4 and M2.
- Mutations not caught: M3 (redundant, as before) and M10 (flag read-back). Neither is a condition.
- Outside this diff, found by the harness: if the server answers 409 for a dbKey its GET list omits, hydrate and push loop in microtasks and starve the tab's timers.
  Whether the bridge can do that (for example, a dbKey owned by another account) is UNKNOWN. This is triage for the main session, not a merge condition.

New condition:

7. **C7 (before live), N1b and N1c precondition.** On every browser profile that loads osionos live (Firefox and Chromium at least), measure with a read-only snippet the characters that are free once the page caches are evicted.
   Use the measured quota of 5,242,879 characters and count non-Latin-1 characters as 2.
   Done when each profile shows at least 64 characters free, recorded with the snippet. If any profile shows fewer, store the flag outside localStorage (for example a cookie) before live, so that the fallback is pull-only.
   C5's ADR 0052 also names N1b, N1c and the rejected candidate.

Merging to develop is allowed only together with the written suspension of live promotion (C4, route 2). Without it, the standing go would promote this unit live before C4, C5 and C7 hold.

