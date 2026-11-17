# 0054. The KDS IndexedDB writer reaches develop only after its coverage fixes, and is not promoted live before pagehide survival is measured

- Status: accepted. Re-ruled 2026-11-17 on 6baab127e: C1, C2 (amended done-when) and C3 are met, so the branch may merge to develop. Live promotion waits for C4, C5 and C7. C4 measured a loss (I10, 2026-11-17); the journal it requires is ruled in [ADR 0055](0055-the-kds-unload-journal-is-per-tab-keyed-by-every-base-it-may-land-on-and-never-regresses-an-acked-record.md), whose J-C7 replaces C4 as the live gate. C7 re-ruled 2026-11-17 (section below): the cookie flag is BLOCKED, and the in-place tombstone meets C7 by construction under C7.1 to C7.8, with no per-profile measurement.
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


## C7 re-rule, 2026-11-17: the flag in a cookie is blocked, an in-place tombstone meets C7

The request was to meet C7 without measuring the Mac Chrome profile, through "F-cookie".
Under F-cookie an origin counts as retired when the flag is set in localStorage or the cookie `osionos_kds_idb_<port>=1` is set (400 days, `Secure`, `SameSite=Strict`).
When the flag is refused, `retireLegacy` writes the cookie instead and removes the legacy keys once either marker reads back.

The ruling was made on osionos `fix/outbox-storage-full-visible` 63c376994 in the worktree osionos-p1-fix, read only.
- The retirement code is at `knownDatabaseDurableCopy.ts:88-97`, `fallbackCopy` at `:99`, `snapshotLegacy` at `:117`, the redo rule at `:156` and the retire call at `:173`. `canWrite` is in `knownDatabasePersistence.ts:142`.
- The probes ran in Docker with the network off, in `/mnt/storage/dlesieur/scratch/devil-c7/`: `probe.mjs` with the output files `out-*.txt`, and `proto/` with its test file, its mutants and `mut-summary.txt`.
- The browsers were headless Playwright 1.59.1 builds: Chromium 147, Firefox 148 and WebKit 26.4. Mac Chrome 153 was not probed.

### Evidence

- **A crash can leave the cookie unwritten and the legacy keys removed (`out-crash.txt`).** A 1M-character legacy pair was retired, then every profile process was SIGKILLed t seconds later, with N=3 per cell.
  - Chromium at t=12 s: 3 of 3 runs came back with no cookie, no flag and no legacy keys. The localStorage removal persisted and the cookie did not.
  - Firefox at t=2 s left the reverse, a cookie next to the legacy keys, which is harmless.
  - No other cell was inverted: 3 inverted of 27 in total. The armed cookie was not `Secure`; that attribute does not change when a cookie is persisted.
  - The same run tested an in-place tombstone: overwrite the state key, read it back, remove the push key, set the flag, remove the state key. It left a marker or the legacy text in 27 of 27 runs.
- **A full origin accepts a shrinking write (`out-s1.txt`).** On all three engines, a 3.35M-character legacy key sat on an origin filled to quota. The 15-character flag threw `QuotaExceededError`, and overwriting the legacy key with `{"kdsRetired":"idb"}` succeeded and read back. After that the flag fit. This matches the M1 delta-quota result of ADR 0056: only growth is refused.
- **Cookies are scoped to the host, not the port (`out-scope.txt`).** Port 18444 reads cookies set on 18443.
- **A `Secure` cookie is not stored on the dev and e2e http origins (`out-scope.txt`).**
  - On a non-loopback http host it is not stored in Chromium or Firefox (`osionos.test`, `isSecureContext:false`).
  - WebKit does not store it even on 127.0.0.1 or localhost, which are secure contexts.
  - So the cookie branch silently does nothing in dev, and no WebKit e2e can cover it.
- **Blocking cookies blocks storage too (`out-blocked.txt`).** In Firefox `cookieBehavior=2`, and in full Chromium the policy `DefaultCookiesSetting=2`, make `localStorage` and `indexedDB` throw too. The only way to block cookies while localStorage keeps working is an extension.
- **Prototype of the alternative (`proto/apply-fshrink.py`, `proto/devil-c7.test.ts`).** I built it as about 25 lines in `knownDatabaseDurableCopy.ts` on a scratch copy and tested it against a quota double that refuses only growth.
  - All 9 devil tests and the 3 builder retirement tests pass (`# pass 12 # fail 0`).
  - At HEAD, 4 fail: C7-N1b, C7-N1c, C7-prefix with growth refused, and C7-tomb-no-copy.
  - Mutants caught: Ma (fallback ignores the tombstone, 3 fail), Mc (a tombstone read as legacy text), Md (push key removed before the tombstone, 3 fail), Me (legacy record kept next to a tombstone) and Mg (state key removed instead of tombstoned, 6 fail).
  - Mb (`isRetired` ignores the tombstone) is equivalent: the snapshot text is already null, so the redo rule at `:156` cannot fire.
- **A tombstone loads as seed in the pre-P1 reader.** `loadPersistedKnownDatabaseState` is unchanged since 4b6e8fdf2 (empty `git diff`). It reads the tombstone as no databases, which merge with the seed (test C7-old-reader). A pre-P1 build therefore sees a tombstoned origin the same way it sees a flagged origin with its keys removed.

### Answers

**a. F-cookie does not close N1b and N1c; it moves them.** On the steady path a cookie origin falls back read-only. But the two stores persist on different timers.
The state the Chromium crash leaves is the CAND state (no marker and no legacy text). That is the state `.out-of-scope/legacy-kds-removal-before-the-migration-flag.md` rejects: a later fallback session writes from the seed, and the redo rule re-migrates that copy over an unpushed migrated edit.

| State | Outcome under F-cookie |
| --- | --- |
| Cookie set, legacy keys present, no IDB copy | A fallback session is read-only. An IDB load re-migrates the legacy pair, as today. Firefox's crash order produces this state, and it is harmless. |
| Cookie cleared, localStorage kept (a Chromium crash, or an extension that clears only cookies) | The CAND state, and the CAND loss. |
| localStorage cleared, cookie kept | Read-only with no local copy. No loss. |
| Cookies blocked | Through the browser setting, every store is blocked. Through an extension, the result degrades to today's N1b and N1c. |
| Another port on the same host | It sees the cookie unless the port is in the name. Both schemes on the default port share the name `default`. |
| `Secure` on https://baas.tail10f2ea.ts.net:8443 | Stored, by inference: it is a secure context and the measured secure contexts store it. Not probed, because live URLs were off-limits. |
| Dev and e2e http origins | Not stored. The branch silently does nothing and cannot be tested in WebKit. |

**b. "Built unconditionally, Mac Chrome unmeasured" is not valid for F-cookie**, because of the crash path above and the branch that cannot be tested. It is valid for the tombstone.
- C7 measured free room only because the old marker had to grow the origin. The tombstone never grows it while legacy text exists, and that held on all three engines.
- The Mac Chrome quota code is UNKNOWN; I infer it from the same Chromium source and carry that as a Caveat. If a Mac Chrome build did refuse a shrinking write, the tombstone write would fail and leave both keys byte-identical (test C7-short-state). That is today's N1b and N1c, not a new loss.
- No cookie is involved, so blocked cookies leave no residual.

**c. Yes, there is a simpler shape: the in-place tombstone.** The marker is written into the key it retires, as one write in one store, so no ordering across stores exists.
- A flag in IndexedDB is useless to a fallback session, which by definition could not use IndexedDB.
- `sessionStorage` dies with the tab. The Cache API and OPFS are asynchronous and share IndexedDB's storage bucket.
- The cookie is the only synchronous store outside localStorage, but nothing outside localStorage is needed.

**d.** The builder conditions are C7.1 to C7.7 below. No J-C7 or RC9 re-run is needed if C7.7's diff check holds.

**e.** The live gates are listed after the conditions. They are K7 (A) forward-only, green CI and the deploy procedure, plus C7.8 and the C7.7 diff check.

### Verdict

- **F-cookie as proposed: BLOCK.** Proved: a Chromium crash 12 s after retirement leaves the CAND state in 3 of 3 runs.
  Nothing short of a durability barrier across the two stores lifts it, and the page cannot issue one. The record is `.out-of-scope/kds-migration-flag-in-a-cookie.md`.
- **The in-place tombstone: PROCEED-WITH-CONDITIONS, C7.1 to C7.8.** C7 is met by construction when they hold. The per-profile 64-character measurement is withdrawn.

Risk scores for the tombstone:

| Axis | Score | Why |
| --- | --- | --- |
| Blast radius | 2 | One module's retirement branch. |
| Reversibility | 4 | A write in users' storage. It is forward-only like K7 (A). A pre-P1 reader sees seed, as it does on a flagged origin. |
| Cost on failure | 3 | An offline edit lost in stacked rare states. |
| Confidence | 2 | Measured on three engines, prototype green, mutants killed. |

The worst axis is reversibility. It adds no constraint beyond K7 (A).

### Conditions (acceptance criteria for the builder)

1. **C7.1, shape.** The common path stays as it is: the flag goes through `setItemEvictingPageCaches`, is read back, and then both keys are removed.
   Only when the flag is refused or does not read back, and the state key holds legacy text:
   - overwrite the state key with the fixed tombstone `{"kdsRetired":"idb"}` through `setItemEvictingPageCaches`;
   - read it back;
   - only then remove the push key.

   Never remove the state key without a stored flag.

   Done when the diff adds no cookie, no IndexedDB flag and no other store, and the devil test C7-common still sees exactly `set flag, remove state, remove pushed`.
2. **C7.2, one retired predicate.** A single function answers "retired": the flag is `"1"`, or the state key equals the tombstone. Both `fallbackCopy` and `snapshotLegacy` use it.
   A tombstoned snapshot has `text: null` and `map: {}`. A flagged snapshot keeps its text and map, which is today's behaviour.
   Done when mutants Ma, Mc and Me each fail at least one builder test.
3. **C7.3, the builder's own tests.** Port `proto/devil-c7.test.ts` into the builder suite, over a delta-quota fixture that refuses only growth and names in a `Caveat:` line what it does not model. The ported tests are:
   - C7-N1b and C7-N1c, where the fallback is `fallback-flagged`, cannot write, and pushes nothing;
   - C7-CAND;
   - C7-prefix with both arms: every prefix of the logged writes keeps a marker or the intact legacy pair;
   - C7-common;
   - C7-tomb-no-copy, with `seedText`;
   - C7-short-state;
   - C7-old-reader.

   Done when they are green, mutants Md and Mg each fail at least one test, and the existing test "an origin that refuses every write keeps both legacy keys and no flag" stays green.
4. **C7.4, gates.** Typecheck, lint with `--max-warnings 0` and the full canvas suite are green.
   That includes `storage-write-guard.test.ts` (72700579b) with no new allowlist entry: the tombstone goes through the room-maker, never through a bare `setItem`.
5. **C7.5, e2e.** One Playwright test runs against the real app build, locally in Docker (no live URL), on Chromium and Firefox. WebKit is welcome, since nothing here depends on cookies. It does three loads:
   1. Fill the origin to quota with a key that is not a page cache, beside a legacy pair holding a user database, and load. The state key now holds the tombstone, the push key is gone, and there is no flag.
   2. Reload with `indexedDB.open` failing. The read-only toast shows and the bridge receives no POST for that database.
   3. Remove the filler and reload. The flag is `"1"` and the state key is gone.

   Done when it is green on each engine in the local Docker gate or in CI.
6. **C7.6, the predicate's comment.** The comment above the retired predicate states why the tombstone works and where it fails:
   - why: only growth is refused, measured on Chromium 147, Firefox 148 and WebKit 26.4, and Mac Chrome is inferred;
   - where it fails: an origin with no legacy text, or text shorter than the tombstone, gets no marker (R-C7b).
7. **C7.7, re-run scope.** No J-C7 or RC9 re-run is required while `git diff --stat fc0d7b408 <live candidate>` over these paths lists only the tombstone change:
   - `src/widgets/database-view/model/knownDatabase*.ts`;
   - `src/widgets/database-view/model/objectDatabase*.ts`;
   - `src/shared/lib/key-value-store/`;
   - the definition of `setItemEvictingPageCaches`.

   At 63c376994 those paths are unchanged since fc0d7b408. The only change in `pageStore.helpers.ts` is comments and two `noticingWriter` call sites.
   Any other change in those paths requires a re-run before live: the RC9 first-session cells and the J-C7 close cells, on Chromium and Firefox, N≥20 per cell, with 0 lost and 0 reverts.
8. **C7.8, register.** ADR 0052 (C5/J-C9) names N1b and N1c as closed for every origin that holds legacy text. It also names R-C7a and R-C7b, and replaces its "C7 measures it per profile" lines with this re-rule.

### Residuals (accepted)

- **R-C7a, unchanged.** N1b and N1c under a browser that refuses every write, shrinking writes included. No engine measured here does that.
- **R-C7b.** A first-session origin with no legacy text (or text under 20 characters) and non-evictable keys alone filling it gets no marker.
  Only then can a later offline fallback session write a legacy copy that the next load's retirement orphans. Nothing is removed in this case, so it never reaches the CAND state.
- **Unchanged, not new.** These existed before the tombstone:
  - A budget-abandoned tab, or a pre-P1 tab open across the deploy, can still overwrite the marker with its own legacy write.
  - The next retirement then orphans that tab's unpushed edits, exactly as it does after a stored flag today (`:171-173`).

### Live gates once C7.1 to C7.8 hold with green CI

P1 goes live when all of the following hold:
- C7 is met.
- J-C7 and RC9 have passed on fc0d7b408 (ADR 0052, R9 note), kept valid by C7.7.
- FL1 holds: the F1 commits land as one unit.
- C5 and J-C9 hold through C7.8.
- K7 (A) is forward-only, and the rollback target is never below `1edca24b9` or a pre-P1 image.
- CI is green on the exact commit promoted, and the deploy procedure is followed: re-verify the target, then tag the rollback image.
- The written live suspension is lifted by a dated note recording these.

If the same promotion carries other units, for example the ADR 0056 page-cache LRU, their own gates bind as well.
