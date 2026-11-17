# 0055. The KDS unload journal is per tab, keyed by every base it may land on, and never regresses an acked record

- Status: accepted. Design J as worded is BLOCKED. Corrected J is PROCEED-WITH-CONDITIONS J-C1 to J-C9.
  Re-ruled 2026-11-17 on 2caf348fb (below): J-C1 to J-C4, J-C6 and J-C8 are met, and J-C5 is met in code. The merge to develop is PROCEED-WITH-CONDITIONS JM1 and JM2, with live still suspended. J-C1's base list is amended, and J-C10 is added before live.
  Re-ruled 2026-11-17 on a00b62265 (RC9 boundary, below): live promotion is BLOCKED by a pre-existing inline-embed fill that inflates the first-session journal past the cap at a 600,000-character edit. The adapter-side fix F1 is PROCEED-WITH-CONDITIONS F-C1 to F-C9.
  Noted 2026-11-17 on fc0d7b408 (F1 built): landing on develop is PROCEED-WITH-CONDITIONS FL1 to FL3, F-C8 clause 3 corrected; the RC9 live BLOCK lifts once FL1 to FL3 hold.
- Date: 2026-11-17
- Deciders: devil (ruling), osionos main session / builder (live with it)

## Context

ADR 0054 C4 required I10. I10 measured a loss, so the sync journal now has to ship (0054, consequence 4). This ADR rules on the design `scratchpad/contracts/p1-journal-design.md`, parts J1 to J6.

Code is osionos worktree osionos-net-retry, `feat/kds-idb-p1` at 6baab127e. It was read only, and `git status` was clean before and after.
All paths below are relative to `src/widgets/database-view/model/`.

- **I10, re-tallied from the raw jsonl** (`/mnt/storage/dlesieur/scratch/i10/out/*.jsonl`). An IndexedDB commit started in pagehide is lost on navigation in every row: 20/20 in Chromium 147, Firefox 148 and stock Firefox 158, at both 4.6 M and 50 K.
  Two corrections to the benchmarker's summary:
  - Chromium headed close-plain at 4.6 M is 16/20 survived, not 19/20.
  - Firefox 148 at 4.6 M does NOT survive a commit started at visibilitychange: 0/20 on navigation, and on close 2/20 headless and 0/20 headed.
- **The journal medium was measured by the devil** with harness `/mnt/storage/dlesieur/scratch/devil-j-ls/` (`./run.sh <browser> <scenario> <size> 20 "" "ls=1"`). Each test is one synchronous `localStorage.setItem` per unload event. N=20 per row unless stated.
  - Chromium 147 survived 20/20 on nav, close-plain and ctx-close at both 50 K and 2 M characters.
  - Stock Firefox 158 survived 20/20 on nav and ctx-close. **Close-plain with a pagehide-only write was missing 20/20.** With the write also made at visibilitychange→hidden it survived 20/20 (`firefox-stock-both-close-plain-*-ls1.jsonl`).
  - **The read race.** Chromium both-nav at about 2.26 M characters, 40 runs per arm:
    - two writes: the next document read the old value 3/40;
    - a single write: 1/40 (`chromium-both-nav-2000000-ls1lsonce1.jsonl`, seq 31, `lateId` = the new id, so the value was late, not lost);
    - a read delayed 150 ms: 0/40;
    - at 1 M characters: 0/40.
  - Chromium's two-write runs at 2 M: the re-read only checked the new id in the last of three runs. There it matched 3/3.
  - `setItem` time at about 2.3 M characters: Chromium p50 4.8 ms, p95 6.0 ms, max 7.5 ms. Firefox 158 p50 3.0 ms, p95 4.0 ms. At 1 M, Chromium p50 2.4 ms.
- Code facts the design relies on:
  - The commit id is assigned synchronously, `${tabId}:${++session.seq}` (`knownDatabaseDurableCopy.ts:192`).
  - `committedId` starts null (`:225`).
  - The migrated copy's id is the constant `"migrated"`, and the redo rule re-migrates over it (`:27,115,128`).
  - The pagehide flush pushes before the commit resolves (`knownDatabasePersistence.ts:97-98`).
  - Every resolved commit pushes the **live** state, not the committed one (`:102`, I2).
  - A push is skipped while another is in flight or before hydration (`objectDatabaseBridgeSync.ts:145`).
- The J model, `/mnt/storage/dlesieur/scratch/devil-p1-2b/devil-j.test.ts`:
  - The commit wrapper is an observer only; it runs over the real `openDurableCopy`, persistence, bridge sync and reconcile.
  - Run: `./reset-mut.sh && cp devil-j*.test.ts mut/tests/canvas/ && ./run-mut.sh tests/canvas/devil-j-ack.test.ts`.
  - Last result: `# pass 10 # fail 7`. All 7 failures are defeated variants. Every row of the corrected J passes.
  - The variants: J as designed, J-literal (base = `committedId`), Jpend (pending ids only) and Jfix (the corrected J):

| Test | Sequence | J as designed | Corrected J |
|---|---|---|---|
| T1 | N2: pagehide push lands, commit lost | `server ["a","b-2"]`, pass | pass |
| T2 | an earlier commit is in flight at unload and **survives**; the unload commit is lost | `discarded (stored tab-a:1)`, `server ["a","b-1"]`: **own edit reverted** | pass |
| T3 | as T2, but the user undid b-1 before leaving | Jpend: `journaled []`, `server ["a","b-1"]`: **undo resurrected** | pass |
| T4 | db-y's record moved without its slice (catch-up refused), then another device edits db-y | `y ["y-2"]`: **other device reverted** | `y ["y-OTHER"]` |
| T5 | no commit this session, offline | J-literal: `discarded`, `server ["a","b"]`: **edit lost** | `["a","b-1"]` |
| T6 | flag refused, S1 journal over `"migrated"`, S2 fallback edit e2, redo re-migrates under the same id | `applied 1 over migrated`, `server ["e1","x-1"]`: **e2 reverted** | the migrated guard keeps e2 |
| T7 | two tabs unload offline on different databases | one key: `x ["a","b"]`: **tab A's edit lost** | per-tab keys keep both |
| T8 | journal at visibilitychange→hidden; the hidden tab lives on, its commit lands, the push is acked, catch-up stores the acked record; the tab is then discarded; another device edits | the stale record overrides the ack: `server ["a","b-1"]`: **other device reverted** (no journal: `["a","b-OTHER"]`) | ack wins: `["a","b-OTHER"]` |

- Unknown when this was written:
  - the largest single-database slice in the live account. The cap's residual depends on it.
  - whether the bridge's GET returns a slice whose hash equals the pushed slice's hash. Alternative B depends on it, and the fake bridge is identity.

## Decision

The journal ships in the corrected form J-C1 to J-C5. J as worded does not ship, because T2, T5, T6, T7 and T8 each defeat it.

- **Keys.** There is one key per tab, `osionos.kds.journal.v1.<tabId>` (J4).
- **Bases.** A journal carries every id it may legitimately land on:
  - the id loaded at readiness;
  - every commit id this tab resolved;
  - every commit id still pending when the journal is written.
- **Contents.** A database is journaled when its live slice or its live record entry differs from **any** base.
- **When written.** At visibilitychange→hidden and at pagehide.
- **When applied.** Inside the readiness transaction, before memory is replaced. At that point:
  - every per-tab journal whose bases hold the stored id is applied;
  - a stored record entry that already equals the hash of the journal's slice is kept;
  - the result is committed under an ordinary `tabId:seq` id.
- **J3 (eager commit) does not ship.** The `removed` field does not exist.

## Alternatives considered

Ranked by the loss sequences each leaves open (e2 is the edit made in the last ≤ 3 s before leaving):

1. **Corrected J (chosen).** It passes T1 to T8 in the model. These stay open:
   - R1, the read race above the cap;
   - R2, the same database edited in two tabs that both unload inside the window (the earlier journal's slice is dropped, the same as two devices);
   - R3, a crash with no visibilitychange;
   - R4, over the cap (see J-C5);
   - R5, a dirty database unioned over another device's later edit, which the legacy writer does today as well;
   - R6, two live tabs overwriting each other's whole-state commits, which P1 already does.
2. **B: push at pagehide, and treat as clean on reload a database whose server hash equals the hash pushed at pagehide** (a tiny journal that always fits).
   - e2 is lost whenever the pagehide push was not sent: one in flight (`objectDatabaseBridgeSync.ts:145`), before hydration, or offline. That is a regression against the legacy writer, which keeps offline unload edits (T5's shape).
   - It still reverts if the round-trip hash differs. That is UNKNOWN, so it counts as FAIL.
   - It does not cover T2, T4 or N2′.
3. **A: no push at pagehide.**
   - e2 is lost on every edit-then-leave whose unload commit dies: Firefox nav and close 20/20, Chromium nav 20/20.
   - Offline unload edits are lost too.
   - N2′ still reverts: the post-commit live push sends an edit made during the commit await (`knownDatabasePersistence.ts:102`).
   - It never reverts from the pagehide push itself.
4. **Status quo / J as worded.** N2 is the common case. J as worded adds the T2, T5, T6, T7 and T8 reverts or losses.
- **J4 with one key and last writer wins**: T7 loses the older tab's offline unload edit.

## Consequences

Conditions (acceptance criteria for the builder). Each test is ported from `devil-j.test.ts` into the canvas suite against the real J, not a model.

1. **J-C1, bases.** `bases` holds the readiness-loaded id, the resolved commit ids, and every pending commit id (ids are assigned synchronously, `knownDatabaseDurableCopy.ts:192`). It is never null.
   The `"migrated"` id becomes unique (`migrated:<tabId>`, with the redo rule matching on the prefix). Failing that, a journal whose matched base is a migrated id is discarded.
   The commit that applies a journal uses an ordinary `tabId:seq` id.
   Done when T2, T5 and T6 pass. The mutations "bases = committedId", "null base before the first commit" and "no migrated guard" each fail one of them.
2. **J-C2, contents.** A dbKey is journaled when its slice or its record entry differs from any base. Its record entry is captured in the same synchronous task as the slices.
   There is no `removed` field (`.out-of-scope/kds-journal-removed-databases-field.md`).
   Done when T3 and T4 pass. The mutations "diff against the last resolved commit only" and "slices only" each fail one of them.
3. **J-C3, apply.** Apply runs inside the readiness `update` (or as a compare-and-set on the stored id). It applies every matching per-tab journal before `load`.
   Per dbKey, a stored record entry equal to `hashSlice(journal slice)` is kept. Otherwise the journal's entry is taken.
   Where two journals hold the same dbKey, the later `writtenAt` wins. `writtenAt` is `Date.now()`, never `performance.now()`, which is per document.
   A journal is removed only after the apply commit resolved true. Journals that do not match are removed.
   Done when T7 (per tab) and T8 pass, and the mutation "the journal record always wins" fails T8.
4. **J-C4, lifecycle.** The journal is written at visibilitychange→hidden and again at pagehide, deduplicated on (state ref, record version). A tab deletes its own key when it becomes visible again.
   Done when three tests pass:
   - a pagehide-only writer fails a test that models Firefox close (the vis write is the one that survives);
   - after visible, the key is gone;
   - hidden, then visible, then an edit whose commit fails while its push lands, then a reload: nothing older is applied.
5. **J-C5, size.** The cap is 1,000,000 characters, counting non-Latin-1 characters as 2. The measured read race is 0/40 at 1 M and 1/40 at 2.26 M.
   Over the cap, or when `setItem` is refused after page-cache eviction, no journal is written and **no pagehide push is sent** for that unload (alternative A for that unload only). N2′ stays a named residual.
   Done when a test shows that an over-cap unload sends no push and writes no key, and when the largest live single-database slice is measured read-only and recorded in ADR 0052.
6. **J-C6.** J3 is not shipped (`.out-of-scope/eager-kds-commit-debounce.md`). Done when `knownDatabaseFlushSchedule.ts` is unchanged in the journal diff.
7. **J-C7, end to end (replaces C4 for live).** In the real app build, on Chromium 147 and stock Firefox 158, test navigation and tab close, with N≥20 per cell.
   Each run edits a database less than 1 s before leaving, with the journal at the cap, then reloads.
   Done when every cell's jsonl shows the last edit on the server after the reload and 0 reverts.
8. **J-C8.** The devil's N2 (`devil-p1-2b.test.ts:205`), driven through the real journal writer, passes. B1a to B5, N1a, B5-2H and CAND stay green. N1b and N1c remain accepted residuals.
9. **J-C9.** ADR 0052 names R1 to R6, N2′ and the cap.

Further consequences:

- Live promotion still waits for J-C7, plus ADR 0054's C5 and C7.
- The journal is additive. Removing it later restores today's N2 and does not touch the stored copy.
- Shipping J as worded, or with a single key, turns this verdict into BLOCK.

## Re-rule 2026-11-17 on 2caf348fb (range 6baab127e..2caf348fb, 7 commits)

The osionos worktree osionos-net-retry was read only, and `git status --short` was empty before and after. Paths are relative to `src/widgets/database-view/model/`. The harness is `/mnt/storage/dlesieur/scratch/devil-p1-2b/`: `run-gates.sh`, `j-muts.py` / `j-muts.sh` and `devil-j-dev.test.ts`.

### Evidence

- **Gates, re-run by the devil on a scratch copy of HEAD** (`run-gates.sh`): full canvas `# tests 5595 # pass 5595 # fail 0`, typecheck rc=0, lint rc=0 (`--max-warnings=0`). `knownDatabaseFlushSchedule.ts` is unchanged in the range (`git diff --quiet`).
- **Targeted run** (the 5 journal files, durable-copy and `devil-p1-2b.test.ts`): `# pass 71 # fail 4`.
  - T1 to T8 and B1a, B1b, B2, B3, B4, B5, N1a and B5-2H pass.
  - The 4 failures are N1b and N1c (accepted residuals), N2 in the devil's own harness (its tabs wire no journal, so N2 there is the no-journal baseline), and CAND line 277 (re-ruled below). With line 277 re-ruled, CAND passes: `local ["x-local-1","x-local-2"]`.
- **The devil's own mutations** (`j-muts.sh`). At HEAD, the probes D6a and D6c fail and every other test passes. Each mutation below is shown with the tests it fails beyond those two:

| Mutation | Fails |
|---|---|
| JA: bases = the last resolved id only | T2, T3 |
| JB: the bare `"migrated"` id | T6 and 2 ledger tests |
| JC: slices only | T4 and the journal-build T4 |
| JD: the journal's record always wins | T8 and apply-T8 |
| JE: pagehide-only writer | 3 lifecycle tests, T8 and D4 |
| JF: push with no journal | the over-cap and refused lifecycle tests |
| JG: no pending ids in the landable bases | T3 |
| JH: the dedupe ignores a removed key | nothing: **survives** |
| JI: a throwing writer allows the push | nothing: **survives** |

### Rulings on the builder's deviations

1. **The content is compared only against the bases that can still land, while `bases` lists every id. UPHELD.**
   - One tab's commits are serialised (`knownDatabaseDurableCopy.ts:213-217`), and each overwrites `state` under a fresh id: `${tabId}:${++seq}` (`:222`), the merge id (`readFound`), and `migrated:<tabId>`. The tab id is 12 random bytes per document (`objectDatabaseRealtime.ts:52-60`).
   - A commit fails only on a transaction error or abort (`indexedKeyValueStore.ts:61-63`), so a failed commit never landed.
   - Once this tab resolved commit k, the store holds k or another writer's later id. Another tab's commit (the T2/T6 class) carries an id the journal does not name, so the journal is removed unapplied (R6).
   - The same argument makes every resolved id older than the last one dead weight in `bases`. Measured: 3600 resolved commits hold 114,094 characters of ids (31.7 per id, through the real `openDurableCopy`). At about 31,500 commits, which is about 8.75 h at one flush per second, the ids alone pass the cap. Past that point no journal is written and no pagehide push is sent, so e2 is lost on navigation. Hence JM2.
2. **`migrated:<tabId>` instead of `"migrated"`. UPHELD.** It is the form J-C1 named. The devil's CAND line 277 is re-ruled to `assert.match(id, /^migrated:/)`.
   Rollback note: builds before 1edca24b9 do not recognise `migrated:<id>` as migrated. Reverting below that commit disables the redo rule for copies migrated after it. This is forward-only, like K7 A.
3. **The loaded id comes from `DurableCopy.ledger()`, not from `LoadedCopy`. UPHELD.** `ledger.loaded()` is set inside the readiness callback before `ready` resolves. When the merge commit fails, `ready` falls back (`settle(null)`), so an unlanded merged id is never used in idb mode.
4. **The dedupe rewrites a journal that another tab's readiness removed. SAFE, BUT UNTESTED AND DEAD IN PRACTICE.**
   - D4 shows the rewrite cannot land over the consumer's newer copy. Tab A's journal is consumed by tab B (`tab-b:1`), B commits `tab-b:2`, and A rewrites at pagehide with bases `["earlier:1","tab-a:2"]`. The reload keeps `["a","b-B2"]`, and the rewritten journal is removed unapplied.
   - D4b shows the apply is a slice replacement, so applying twice is idempotent.
   - The rewrite cannot help either. A's hidden commit transaction is created before B's readiness transaction, so B reads A's id and consumes the journal. A rewritten journal can then only name ids that the store no longer holds.
   - JH survives. Deleting the branch is recommended; it is not a condition.
5. **A writer that throws counts as refused: no pagehide push. UPHELD.** That is alternative A for that unload: a loss, never a revert. JI survives, so the branch has no test. Hence JM1.
6. **Deletes in the window, and no copy at all.**
   - **D6a (a row deleted in the window, push not landed, IDB commit lost).** The reload gives `local ["a","b","c"]` and `server ["a","b","c"]`: the deleted row comes back and is pushed. The journal does not carry the tombstones (`deletedPages`). The reload reads the database as dirty and unions it with the server's copy, which still holds the row.
     - Control D6b (the commit lands): `["a","b"]`.
     - P1 without a journal gives the same resurrection. The pre-P1 legacy writer stores the tombstones synchronously, so against today's production this is a regression in the resurrect direction, never a loss.
     - It is R7, and J-C10 below.
   - **D6c (empty store, no commit resolved, offline unload).** No journal is written (`stored false`), and the edit is lost: `server ["a","b"]`. This happens only in a session whose store held no copy, such as the first session or after IndexedDB eviction, and only until its first commit resolves (at least a 1 s debounce, `knownDatabaseFlushSchedule.ts:16`). P1 without a journal behaves the same. It is R8, and is named, not fixed.

### Conditions

Merge to develop, in addition to ADR 0054's written live suspension:

- **JM1.** A canvas test makes the journal writer throw at pagehide (for example a `live()` that throws). It asserts that no push is sent and no key is written. Mutation JI must turn it RED.
- **JM2 (amends J-C1).** `bases` = the readiness-loaded id + the last resolved commit id + every pending id. Resolved ids older than the last one are dropped.
  A test runs N≥1000 resolved commits and asserts that the journal's `bases` length is at most 2 + pending. T2, T3, T5 and T6 stay green, and JA stays RED.

Before live (in addition to J-C7, J-C9, and ADR 0054 C5/C7):

- **J-C5, measurement half.** The largest live single-database slice is measured read-only and recorded in ADR 0052, together with J-C9. ADR 0052 does not exist on 2026-11-17.
- **J-C10, tombstones.** Either the journal carries the tombstones of its journaled databases and the apply unions them into the stored `deletedPages`, with D6a ported and passing, or the user accepts R7 in writing in ADR 0052.
- **J-C9, extended.** ADR 0052 also names R7 (D6a), R8 (D6c) and the forward-only `migrated:<tabId>` id.

## Re-rule 2026-11-17 on 38c38cf36 (range 2caf348fb..38c38cf36, 5 commits)

The osionos worktree osionos-net-retry was read only, and `git status --short` was empty before and after, at HEAD 38c38cf36. Paths are relative to `src/widgets/database-view/model/`. The harness is `/mnt/storage/dlesieur/scratch/devil-p1-2b/`: `rerule-38c38cf36.sh`, `run-gates.sh` (now 900 s per gate), `j-muts.py` / `j-muts.sh` (updated for the new code; the 2caf348fb copies are kept as `*.2caf348fb.*.bak`), `devil-j-dev.test.ts` (verbatim) and the new `devil-j-tomb.test.ts`.

Verdict: JM1 and JM2 are MET. J-C10 is MET in code, and its whole-set deviation is UPHELD. The develop merge is PROCEED. Live stays suspended.

### Evidence

- **Gates, re-run by the devil on a scratch copy of HEAD:** full canvas `# tests 5605 # pass 5605 # fail 0`, typecheck rc=0, lint rc=0.
- **Targeted run** (the 7 journal files, durable-copy, `devil-j-dev` and `devil-p1-2b`): `# pass 86 # fail 4`. The failures are D6c (R8, expected), N1b and N1c (accepted residuals), and N2 in the devil's no-journal harness. D4, D4b, D6a, D6b and CAND pass.
- **Mutations.** At HEAD only D6c fails. Each mutation below is shown with the tests it fails beyond D6c:

| Mutation | Fails |
|---|---|
| JA: bases = the last resolved id only | the 1000-commit ledger test, T2, T3 |
| JB: the bare `"migrated"` id | 2 ledger tests, T6 |
| JC: slices only | the journal-build T4, T4 |
| JD: the journal's record always wins | apply-T8, T8 |
| JE: pagehide-only writer | 3 D4 tests, 3 lifecycle tests, T8 |
| JF: push with no journal | over-cap, refused and **throwing-writer** lifecycle tests |
| JG: no pending ids in the landable bases | T3 |
| JI: a throwing writer allows the push | the throwing-writer lifecycle test (**JM1 MET**) |
| JK: the journal carries no tombstones | D6a (both copies), the carry test, the cap test |
| JL: the apply ignores the journal's tombstones | D6a (both copies), the union test; devil D10 |
| JN: a journal without `deletedPages` is accepted | the "removed unapplied" test |
| JO: the apply replaces the stored tombstones instead of unioning | nothing: **survives** |
| JP: the cap ignores the tombstones | the cap test |

- JH is retired: the branch it mutated was deleted in a58610881, as recommended.
- **JM2:** `baseIds` (`knownDatabaseJournal.ts:151-154`) is the loaded id, `lastResolved.id` and the pending ids. The ledger test runs 1000 resolved commits and asserts `["earlier:1","tabA:1000","tabA:1001"]`.

### Ruling on the J-C10 deviation: the whole live set, unioned

The question was whether unioning a tombstone that no journaled database can attribute can hide or delete a row that should be live. No such sequence exists in this code. The proof follows.

1. **Tombstones only grow, with two exceptions.** They are added by `deletePage` (`knownDatabaseState.ts:307`) and by the `persistState` diff (`:393`). They are removed only by the server prune (`:618-626`, which keeps an id only while some server slice holds it, or when it is a seed page) and by `resetState` (`:90-93`). `resetState` has no caller in `src/`.
   Nothing un-tombstones a row on restore:
   - there is no row undelete (`useUndoRedo.ts` covers block content only);
   - trash restore (`pageStore.actions.ts:982`) is for workspace pages, not KDS rows;
   - `insertPage` mints `createId("page")`, which is a `randomUUID` (`knownDatabaseState.ts:278`, `:671-674`), so an id is never reissued.
2. **The bases gate fixes what the stored copy can be.** A journal applies only when the stored id is in its `bases` (`knownDatabaseJournalApply.ts:119`). That id is one of the tab's own copies:
   - the readiness copy, whose tombstones seeded the tab's live set (`knownDatabaseState.ts:167`);
   - or one of its commits, which serialised the tab's live set at that moment.
   So the stored set S is the tab's set at some earlier time, and the journal's set L is that set later. L ⊇ S minus what the tab pruned.
3. **What the union adds.** S ∪ L adds nothing outside S (what no journal leaves) and L (what the lost commit would have stored). The only tombstones it keeps beyond the lost commit are ones this tab pruned in the window. The server lacked those ids at prune time, and the stored copy without a journal keeps them too.
   With two matching journals the same holds per tab. Devil D10 shows the union is what makes cross-tab correct: A deletes c, and B's later slice wins while still holding c. The reload gives `{"local":["a-B","b"],"server":["a-B","b"],"tomb":["db-x-r2"]}`. Under JL, c comes back: `["a-B","b","c"]`.
4. **Unattributed ids.** D11 shows a tombstone that no base holds (`never-held`) changes nothing visible: `{"local":["a-1","b","c"],"server":["a-1","b","c"]}`.
5. **The dedupe.** It can keep a superset set after a prune, because a prune changes neither the live ref nor the version. The journal it keeps predates the prune commit, so that commit's id is not in its bases. If the prune commit landed, the journal is removed unapplied. If it was lost, the stored copy holds the pruned id anyway.

Named, not caused by J-C10:

- A tombstone hides an id that a stale device pushes back (`tombstonesStillNeeded` cannot tell "my delete not yet pushed" from "re-pushed"). This is the existing ADR 0051 model.
- The union delays the prune of an id pruned in a lost window until the next sync. The no-journal path behaves the same.

JO survives because union and replace differ only on ids pruned in the window. That is not a safety property. Union is the conservative direction (ADR 0051: never a removal). No test is required.

**The cap:** `storeUnloadJournal` measures `storedLength(JSON.stringify(journal))`, which includes `deletedPages` (`knownDatabaseJournal.ts:112-115`). JP turns the cap test RED.
- Each tombstone costs about 44 characters, so roughly 22k live tombstones alone reach 1 M.
- Over the cap the unload takes alternative A: no journal and no pagehide push. That is a loss, never a revert.

**A journal without `deletedPages`** is rejected by `parseJournal` (`knownDatabaseJournalApply.ts:68`). It is then removed by `discard`, which compare-and-deletes every read key.
- No such journal exists outside develop testing: the journal has never reached develop.
- A rollback to 2caf348fb..a58610881 would write journals that 38c38cf36 discards. That is a loss of one window, never a revert.

### Conditions

Merge to develop: none new. JM1 and JM2 are met. ADR 0054's written live suspension still binds.

Before live, unchanged: J-C7, the measurement half of J-C5, and J-C9, extended. ADR 0052 must name:
- R7, closed by J-C10: name it as closed;
- R8 (D6c);
- the forward-only `migrated:<tabId>`;
- N2′;
- the cap, now including the tombstones;
- the prune-delay residual above.

ADR 0054's C5 and C7 still apply. J-C10 is satisfied.

## Re-rule 2026-11-17 on a00b62265: the first-session window (R8), A2

osionos develop went red on 38c38cf36: `tests/e2e/functional/templateUse.spec.mjs:52-80` lost a row title typed less than about 3 s before a reload (CI run 44037496549, shard 6/6). Its cause is R8 (ADR 0052): an empty store gave the journal no base. The devil ruled options R (revert), A, B, C, D and E; it ruled A2 PROCEED-WITH-CONDITIONS (RC1–RC10) and blocked the rest. D and E are recorded in `.out-of-scope/`.

### Decision (A2)

- **Seed at readiness.** An empty store with no legacy text, in a session that was not abandoned, stores `serializeKnownDatabaseState(seedSnapshot(), new Set())` under `migrated:<tabId>`, with record `{}`, and records it as loaded. The redo rule covers an abandoned seed put, as it covers a migration (`knownDatabaseDurableCopy.ts`).
- **J-C2, one case changed.** When a base holds neither a slice nor a record entry for a database (a hydrate added it after the copy was read), that database is journaled only if its live copy is dirty against the push record. Every other case is unchanged. Plain A (seed write without this rule) put a large account's first-session journal over the cap, so J-C5 sent no pagehide push where 38c38cf36 sent one; the probe proved it.

### What changes for a user

- **I7 flag earlier.** The `osionos.kds.idb` flag is set at a new browser's first readiness, not at its second IndexedDB session, so a later fallback session in that browser is pull-only.
- **Wiki seed dates freeze at the first stored copy.** The wiki seed pages (ms1–ms6, wiki-f01–f26) are dated from `new Date()` (`wikiSeedPages.ts:25`) and nothing re-anchors them on load. Any browser that saved anything already had them frozen at its first save; since A2 that includes the first load of a browser that never saved. A re-anchor (`rebaseWikiSeedDates`, modelled on `rebaseHomeDemoDates`) is a separate unit and not a precondition for live.

### Evidence (a00b62265, branch `fix/kds-template-reload`)

- Canvas 5614/5614; typecheck and lint rc=0; `templateUse.spec.mjs` unchanged and 10/10 with `--repeat-each=10 --retries=0`; `knownDatabaseFlushSchedule.ts` unchanged.
- The devil's harness: only N1b, N1c and N2 fail (as at 38c38cf36); D6c and R8-1 to R8-4 pass.
- RC2: (a) restore equality under a frozen `Date`; (c) the stored seed text equals the single producer call exactly. The five omission mutants (noWiki, noHome, noGrades, jsonOnly, emptyState) are equivalent for every read path, because each path merges the stored text over the seed before reading it; RC2(c) kills them anyway, with changedPage and tombstone.
- RC8, fresh-profile cold readiness with the seed write, N=20, production build: Chromium 147 p50 19.6 ms, p95 25.1 ms; Firefox 158 p50 31.0 ms, p95 365.0 ms; 0/20 over the 3 s budget in each.
- Evidence: `/mnt/storage/dlesieur/scratch/p1-r8-a2/`, `/mnt/storage/dlesieur/scratch/devil-r8/`.

### Conditions

Before live, added to J-C7: RC9, a J-C7 re-run on the fix commit with first-session cells (fresh profile, edit less than 1 s before leaving, with no bridge and online, navigation and close, N≥20 per cell): 0 losses, 0 reverts. ADR 0054's live suspension, C5 and C7 still bind.

## Re-rule 2026-11-17 on a00b62265 (RC9 boundary: the inline-embed fill in the first-session journal)

The osionos worktree osionos-p1-fix (`fix/kds-template-reload`, HEAD a00b62265) was read only. Its `src/` was not modified; the probes ran on a copy. Harness: `/mnt/storage/dlesieur/scratch/devil-rc9/`, two runners:
- `./run.sh tests/canvas/devil-rc9-leak.test.ts`: the canvas runner in docker, on a copy of the worktree. Log: `leak.log`.
- `./leak.sh`: the RC9 production build `rc9/dist`, Chromium 1.59.1, `--network none`. Results: `leak-e2e.log` and `leak.json`.

Gap in the record: the R8 ruling's RC1 to RC10 were never written into this ADR. The devil's memory `osionos-kds-r8-verdict.md` holds them only as a summary. This section rules on the RC9 outcome. It does not restate RC1 to RC10.

Verdict:
- **Live promotion of P1: BLOCK.**
- **The root fix F1 below: PROCEED-WITH-CONDITIONS F-C1 to F-C9.** Live promotion is re-ruled once these conditions are met.
- RC9's required cells are accepted as measured:
  - 160/160 regression cells kept;
  - first-session cells: 564 OK, 0 lost, 0 reverts;
  - `rc9/out/summary-first.md`, `summary-regression.md`.

### Evidence

- **RC9 boundary, verified in `rc9/out/summary-first.md`.** These are the online server-title cells in the first session.
  - Padded to 500,000: 80/80 kept, and the Chromium nav journal is 946,546 to 946,549 characters.
  - Padded to 600,000: 41/80 lost (Chromium nav 20, Firefox close 20, Chromium close 1, Firefox nav 0), with no journal set and no unload push.
  - A seed-only edit journals 8,134 characters (`chromium-nav-offline-seed-title`).
- **The cause, corrected.** The engine's save of a user edit does not do this. The host's own post-load persist does, and no user edit is involved:
  1. `loadAdapterState` sets the loaded state together with `activeDbmsSource: 'adapter'` in one `setState` (`object_database.tsx:590-597`, engine submodule 77892faa).
  2. The persistence subscriber treats any such change as an edit (`:552-557`). Its baseline is the store before the load, which on a first mount holds the engine store's initial empty maps (`useDatabaseStore.ts:45-47`). After 150 ms it calls `persistState(projected, empty)` (`:541-546`).
  3. `KnownDatabaseAdapter.persistState` (`knownDatabaseState.ts:385-399`) runs `mergeChangedRecords`, which compares by reference (`:451`). Against an empty baseline, every view of the projection is written into `useKnownDatabaseStateStore`.
  4. For an inline embed, that projection is `applyAdapterOptions` (`:424-442`): it gives every table, list and timeline view of the whole state a `loadLimit`.
- **The cause, proved:**
  - L3 (control): a full-page mount writes 0 views.
  - L1: an inline mount fills 19 of the 45 seed views, across all 10 seed databases. A later full-page mount then reads `resolvePageSize(8)` = 8 rows per page instead of 50 (`viewPagerMath.ts:15-20`).
  - L2: an embed with `recordLimit` 3 overwrites an explicit user Limit of 100 on an unrelated database (`v-crm-table`) with 3 (`:436`).
  - e2e (`leak.json`): a fresh profile inserts one new inline database and edits no seed database. The IndexedDB copy `…:1` then holds `loadLimit: 8` on 19 views in 10 databases. The control profile (full page only) holds 0.
  - The seed `db-tasks` has 8 rows, so the row cap cannot show on it. L1 shows it for any database with more than 8 rows.
- **Pre-existing, independent of P1.**
  - `applyAdapterOptions` dates from c98affa1b (2026-07-09), an ancestor of P1.
  - The engine pin is 77892faa both before P1 (ce74ab157) and at a00b62265.
  - The P1 diff does not touch `applyAdapterOptions`, `persistState` or `mergeChangedRecords`.
  - The legacy writer serialized and pushed the same store (`ce74ab157:knownDatabaseState.ts:184-212`). Its push excludes only the seed databases, so user databases with a filled view were pushed: the 8 reached the server and every other device. It is live today. The data is view settings only: no row is lost.
- **Amplification beyond 447k (L4, new).** A database added by a hydrate holds no base entry and has a record equal to its server hash, so A2 counts it clean (`knownDatabaseJournal.ts:79-82`).
  - Once an inline mount fills its view, it is dirty. Hydrate → `notifyStateReplaced` (`knownDatabaseState.ts:590-594`) → the embed reloads → the projection runs again.
  - L4 measured this with the real `buildUnloadJournal`. Before the mount: `null`. After it: 11 slices, 683,197 characters, made of the seed's 446,788 plus the whole 236,409-character hydrated database.
  - So the first-session headroom is not 553k. It is 1,000,000 − 447k − every hydrated database whose server copy lacks the fill.
  - The window closes only after the first commit resolves and its record catch-up lands (`knownDatabaseJournal.ts:150-153`, `knownDatabaseCommitLedger.ts:68`).
  - UNKNOWN: how many live server databases already carry the fill (from the live legacy push) and how many do not.
- **Legacy comparison.** Pre-P1, the pagehide flush writes the whole state synchronously to localStorage (quota 5,242,879 characters, page caches evicted) and pushes it.
  - A 600k account's whole state is about 1.05M characters, which fits. So a 600k first-session edit is kept on legacy and lost on P1.
  - **This is a regression.** It belongs to R4's class (over the cap), with the threshold lowered by a pre-existing bug.

### Ranking of the fix candidates

| | Behaviour change | Loss paths | Ruling |
|---|---|---|---|
| **F1** (adapter-side root fix) | The known adapter's write path stops persisting its own projection. A view whose only difference from the store is the projection is not written. When the user edits a view, its stored `loadLimit` is kept unless the user changed the Limit. The default stays render-time only. | It closes the boundary loss (the journal is back to the 8k seed-only size, plus the edited databases) and L4's amplification. It also closes the live setting corruption (L1, L2), and does nothing to K1–K12, I1–I13, J-C1–J-C10 or RC1–RC10: the journal, bases and readiness are untouched. It opens one residual: an explicit Limit equal to the inline default (8), set on an inline view that had none, is indistinguishable from the fill. A view setting, never a row. | **PROCEED-WITH-CONDITIONS, first** |
| F0 (host-side: the engine stops persisting its own load) | `useAdapterStatePersistence` ignores the change that `loadAdapterState` makes. | It drops the database, view and starter row that `withRequestedDatabase` creates inside the load (`requestedDatabase.ts:13-34`): a new inline database would not persist. It changes the contract for every adapter (the guard at `sysDatabaseState.ts:240-242` assumes it, but it is dead today). The blast radius is the shared engine. | **BLOCK** for this unit; it needs its own ruling |
| F2 (journal skips differences in view settings only) | The diff ignores views. | A user's own view edit in the unload window is pushed at pagehide while its commit is lost. The reload pushes the older stored view back over it: N2 for views, the revert class J exists to close. It leaves the setting corruption live. | **BLOCK**; `.out-of-scope/kds-journal-view-settings-only-exclusion.md` |
| F3 (seed base after the projection) | Readiness stores the projected seed. | Which fill applies depends on which embeds mount (8, `recordCap`, or none). A session without an inline embed then differs on all 10 seed databases: the same 447k, inverted. It does not cover L4 (no base holds a hydrated database). It breaks RC2(b) and RC2(c) (exact stored text = `serialize(seedSnapshot(), new Set())`). It writes the bug into the durable copy. | **BLOCK**; `.out-of-scope/kds-projected-seed-base.md` |
| F4 (accept and register only) | None. | It rests on an UNKNOWN: the share of live server databases without the fill bounds L4. It also leaves a live setting corruption whose fix is local and cheap. | **BLOCK** as the only route. After F1 lands, the residual from F1 is registered in ADR 0052. |

### Conditions F-C1 to F-C9 (F1; acceptance criteria for the builder)

1. **F-C1, no projection is written.** The ported L1 test: after an inline mount (`defaultLoadLimit` 8) and the host's post-load persist replayed with an empty baseline, 0 store views gain or change `loadLimit`, and a full-page `v-tasks-table` resolves to 50. In the e2e inline arm (`devil-rc9/leak.sh`), the IndexedDB copy has `limited: 0`.
2. **F-C2, the cap is never written.** The ported L2 test: with `recordCap` 3, an explicit 100 on `v-crm-table` stays 100 in the store, and no view without a Limit gains one.
3. **F-C3, explicit choices still persist.** In an inline embed:
   - Limit 25 persists as 25, and "All" persists as 0, in both the store and a full-page load. This is the "Limit that didn't persist" fix at `knownDatabaseState.ts:433-435`.
   - A sort or filter edit on the embed's view persists the sort, and the stored `loadLimit` stays absent.
   - Each of these mutations must turn a test RED: (m1) skipping only the empty-baseline persist; (m2) stripping every `loadLimit` from writes; (m3) un-projecting the fill but not the cap.
4. **F-C4, a new inline database still persists.** After `/database` inline, the store and IndexedDB hold its database, view and starter row (`withRequestedDatabase`). Both the e2e inline arm (46 views) and a canvas test show it.
5. **F-C5, no amplification.** The ported L4 test: after an inline mount, the journal against the seed base is `null`, and a clean hydrated database is not journaled.
6. **F-C6, scope.**
   - The engine submodule (`src/shared/notion-database-sys`) is unchanged; F0 is not shipped.
   - Existing stored or server `loadLimit: 8` values are not scrubbed, because they cannot be told apart from an explicit 8. A cleanup needs its own ruling.
   - `applyAdapterOptions`' read-side projection stays.
7. **F-C7, RC9 re-run on the F1 build.**
   - The 8 regression cells and the 28 first-session cells: 0 lost and 0 reverts.
   - `pad.sh 600000 20` and `pad.sh 900000 20` on all 4 browser/scenario pairs: 0 lost, 0 reverts, and every journal ≤ pad + 20,000 characters.
8. **F-C8, gates.**
   - The full canvas suite, typecheck and lint pass with 0 warnings.
   - In the devil-r8 harness, R8-1 to R8-4, the RC2 tests and the JA to JP mutation table hold as recorded above.
   - N1b, N1c and test 16 "N2" of `devil-p1-2b` (no journal wired) stay the only failures; the journal-wired N2, T1 in `devil-j-dev`, passes. (Corrected 2026-11-17; the first wording omitted test 16, see the note on fc0d7b408.)
9. **F-C9, the register.** ADR 0052 is updated once F1 lands:
   - the pre-F1 boundary (553k, L4) is marked closed;
   - F1's residual (an explicit 8 equal to the inline default) is named;
   - the leaked 8s on live copies are named and left in place.

Live promotion still also waits for ADR 0054 C7 and the conditions already listed above.

### Note 2026-11-17 on fc0d7b408: F1 built (cc5145417, 7520d20c3, fc0d7b408)

The F1 commits are on osionos `fix/kds-template-reload` (`fc0d7b408`, not pushed). The worktree was read only; the devil's probes ran on copies.

**Verdict:**
- **Landing `fc0d7b408` on osionos develop: PROCEED-WITH-CONDITIONS FL1 to FL3.**
- F-C1 to F-C8 are met, with F-C8 as corrected below. F-C9 is the ADR 0052 block applied on landing (FL3).
- Once FL1 to FL3 hold, the RC9 BLOCK on live promotion is lifted. Live promotion still waits for ADR 0054 C7 and the live suspension.

**F-C8, corrected.** Clause 3 now reads: "N1b, N1c and test 16 'N2' of `devil-p1-2b` stay the only failures in the devil's harness, and the journal-wired N2 (T1 in `devil-j-dev`) passes."
- Why the change: test 16 runs in the devil's own tabs, which wire no journal. It is the no-journal baseline, and it was recorded as an expected failure at 2caf348fb, at 38c38cf36 and in the A2 section above ("only N1b, N1c and N2 fail").
- Clause 3 as first worded contradicted that record. The mistake is the devil's.
- N2 needs no fix of its own: the journal closes it, and T1 is the test that proves it.

**Evidence the devil verified:**
- **The devil's harness, on the builder's logs** (`/mnt/storage/dlesieur/scratch/rc9-f1/devil/`):
  - `base-a00b62265.log` and `head.log` both show `# pass 104 # fail 3`, failing the same tests: 15 (N1b), 16 (N2) and 20 (N1c).
  - In `head.log`, line 739 reads `ok 100 - T1 (N2) … the journal keeps b-2 on the server`.
- **JA to JP on head** (`summary.txt`): the same table as at 38c38cf36. JO still survives, as it did there.
- **Gates, rerun by the devil on its own copy of the fc0d7b408 tree** (`/mnt/storage/dlesieur/scratch/devil-rc9/gate-head-*.log`):
  - typecheck rc=0 and lint rc=0;
  - canvas 5627/5627, against 5614/5614 on a00b62265.
- **The RC9-F1 build is fc0d7b408.**
  - `diff -rq` between `rc9-f1/src/src` and the worktree's `src` is empty.
  - `dist/index.html` was written at 11:58:26, after the commit at 11:57:03.
- **RC9-F1 results** (`rc9-f1/out/`):
  - First-session table: 50 cells, 740 runs, 0 lost, 0 reverts. The 12 harness errors were topped up.
  - Regression table: 8 cells, 160/160 on the server, 0 reverts.
  - `pad-journals.md`: 600,230 to 600,232 and 900,229 to 900,232 characters, 0 over the bound. The seed's 447k is gone from the journal.
- **Mutants** (`mutants/summary-fix.txt`): m1, m2 and m3 are RED, as F-C3 requires, and so is m4.
- **Browser inline arm** (`leak/leak.json`): `limited: 0` after the mount, after the full page and after the reload; 46 views.
- **The unbound call:**
  - `7520d20c3` alone throws `Cannot read properties of undefined (reading 'options')` from `persistState`, called by the host's `flush` (`rc9-f1/logs/diag-f1-err.log`).
  - `templateUse` fails 10/10 there (`e2e-templateUse-x10.log`) and passes 10/10 on `fc0d7b408` (`e2e-templateUse-x10-fix.log`).
- **The devil's attack probes**, `devil-rc9/devil-f1-attack.test.ts`, run by `./runf1.sh head|base`:

| Probe | a00b62265 | fc0d7b408 |
|---|---|---|
| A1: an inline embed turns a table into a board | board stored with `loadLimit` 8 | the same: board stored with 8 |
| A2: a capped embed (3) duplicates a view stored at 100 | source 3, copy 3 | source 100, copy without a Limit |
| A3: two mounts. A full page sets Limit 25, then a stale inline embed edits the sort | 25, then 8 | the same: 25, then 8 |
| A4: the cap half. The embed shows 3 over a view stored at 100; the user picks 3, then 2 | 3, then 2 | 100, then 2 |
| A5: the host re-creates every view with equal values but new references | 19 views filled; 10 databases journaled | 0 filled; journal `null` |
| A6: a sort edit in an inline embed | sort kept, `loadLimit` 8 written | sort kept, no Limit |
| A7: persist with no previous state (fill 8 + cap 3) | 19 views at 3 | only the explicit `v-crm-table=100` |

**Ruling on the cap half of the residual: accepted under F-C3 and F-C9.**
- The `withoutProjectedLimits` Caveat is exact. Its two halves are one case: the user re-selects the Limit the embed already shows (A4: shown 3).
- In a capped embed, every value at or above the cap renders as the cap. So inside the embed the dropped pick changes nothing visible.
- The difference shows only on a full page, and picking the Limit there writes it.
- On a00b62265 the same embed wrote 3 over every paged view of the account (A7).
- F-C3's own cases persist: 25, 0 and 2 (A4).
- The duplicate case (A2) belongs to the same family: a copy made inside an embed, whose Limit equals the projection, is stored without a Limit. On a00b62265 it got the cap. These are view settings, never rows.

**Ruling on the `unprojectView` identity rule: sound.**
- `sameFields` only chooses between two unprojected objects: the stored view, or the restored copy. So no projection can slip through it.
- A real edit is swallowed only when every top-level field and every `settings` field is reference-identical to the stored view. That requires a nested field mutated in place, which this code base rules out:
  - The engine's view edits spread and never mutate (`viewSlice.ts:47-60`, `propertyVisibility.ts:22-29`; the page splices act on copies, `pageSlice.ts:200,221`).
  - Outside production builds, the loaded state is deep-frozen (`knownDatabaseState.ts:666-669`), so an in-place write throws.
  - A host that re-creates a view with equal values writes nothing and journals nothing (A5).
- Projections do slip through the two gates before that rule:
  - **A1, non-paged type.** `unprojectView` returns any view whose current type is not paged.
  - **A3, stale store.** It compares with the store's current Limit, not the one the embed loaded.
- Both are pre-existing: each reproduces byte for byte on a00b62265. They are registered as R10 and are not a condition.
- A follow-up would close both without a new ruling, if probes A1 and A3 turn and F-C1 to F-C5 stay green:
  - keep the store's Limit when the view's Limit is unchanged against the baseline view `previous[viewId]`;
  - also unproject when the stored view's type is paged.

**Ruling on the no-previous-state branch: correct, and unreachable from the host.**
- The only production caller is `object_database.tsx:551`, and it always passes the window's baseline.
- On that branch, A7 writes no projection.
- Like a00b62265's `replaceState(state)`, it replaces the whole state, including dropping views the caller left out. That behaviour is unchanged by F1.

**Conditions:**
1. **FL1, one unit.** `cc5145417..fc0d7b408` reach develop together, by fast-forward or by one merge.
   - `7520d20c3` is never a branch tip, a cherry-pick or a revert target on its own.
   - Reverting F1 reverts `fc0d7b408` and `7520d20c3` together.
2. **FL2, the unbound shape stays tested.** Every test in `known-database-embed-limit-write.test.ts` keeps calling `persistState` destructured (`persistAsHost`). If `persistState` turns back into a method that reads `this`, they go RED.
3. **FL3, the register.** The F-C9 block (devil record `/mnt/storage/dlesieur/scratch/devil-rc9/fc9-adr0052-block.md`) is applied to ADR 0052 in the groot commit that records F1 on develop.

Correction to "Gap in the record" above: the A2 section does record RC2, RC8, RC9 and the harness failures. RC1, RC3 to RC7 and RC10 remain unwritten.
