# 0057. The object-database sync acts only for the latest account id, and P1 goes live only on a build that has it

- Status: accepted.
  - F-A (a stale effect run does nothing) on osionos develop: PROCEED-WITH-CONDITIONS BR1 to BR8.
  - F-A live on its own, cherry-picked onto the live main: PROCEED-WITH-CONDITIONS BR9 to BR13. It should go first.
  - P1 live: waits for F-A (BR14). F-A fires neither ADR 0054 C7.7 nor ADR 0056 LL8.
  - Changing what a legitimate account-switch reset does is not in this unit (R-BR1).
- Date: 2026-11-17
- Deciders: devil (ruling), osionos main session / builder (live with it)

## Context

Code was read at osionos develop 628f5de19 and main 9d9520959 (`git ls-remote` at ruling time). `git diff --stat 9d9520959 628f5de19 -- src/app/App.tsx src/widgets/database-view/model/objectDatabaseReconcile.ts` is empty, so the race is the same on both.

### The race

- **The effect** is at `src/app/App.tsx:226-243`. It calls `void import(".../knownDatabaseState").then(...)` on every `activeUserId` change.
  - The callback resets when `objectDbPrevUser.current && objectDbPrevUser.current !== objectDbActiveUser` (`:236`).
  - It then writes the ref (`:239`) and starts (`:240`).
  - It has no cleanup.
- **A boot runs it twice.** The store starts at `activeUserId: ''` (`src/features/auth/model/useUserStore.ts:595`). `init` then sets the one resolved id with `set(await resolveInitialState())` (`:601-613`).
- **Each run issues its own `import()`.** In the production chunk (`/mnt/storage/dlesieur/scratch/c7-e2e/dist-prod4/assets/index-U9mB6CNp.js`), the effect compiles to vite's preload helper around a fresh `import("./knownDatabaseState-DdU5gJDI.js")`.
  - Its four deps are JS chunks. No CSS is awaited, so the helper adds no asymmetry between the two runs.
  - The two promises are distinct, and nothing orders their callbacks.
- **Reversed order.** When the second promise resolves first, the real-id callback starts the sync. The stale `""` callback then sees `ref = <id>`, resets, and writes `ref = ""`.
  - Probe line: `[probe] +267ms effect callback u="" ref="user-probe-a" reset=true`.

### What the reset does

- **On main** (`objectDatabaseBridgeSync.ts:270-279`), the reset ends in `pushBaseline.reset()`. That removes `osionos.objectDb.pushed.v1` (`objectDatabasePushBaseline.ts:62`).
  - The next hydration passes an empty record.
  - With `pushed[dbKey] !== localHash`, every local database takes the union path (`objectDatabaseReconcile.ts:48`).
  - `pushDirtyObjectDatabases` then uploads it (`objectDatabaseBridgeSync.ts:240`).
  - A device holding a stale copy therefore reverts the server: newer values are overwritten and rows deleted elsewhere come back.
- **On develop** (`objectDatabaseBridgeSync.ts:247-257`), the reset does `record.replace({})` then `sink.reset()`.
  - The sink starts as the legacy one (`:76`). Only the durable copy's read replaces the record and the sink (`:68`, `:81`).
  - A reset before the read: once an IndexedDB copy exists, the read restores the record, so the reset is harmless.
  - A reset before the read on the migration load (no IndexedDB copy yet): the legacy sink removes the push key before the migration reads it, so it reverts.
  - A reset after the read: it reverts.
- **Canvas evidence** (`/mnt/storage/dlesieur/scratch/c7-e2e/probe-tree/tests/canvas/probe-boot-reset*.test.ts`):
  - **q3b.out:**
    - after-read: `"live":["x-old-1","x-old-2"]`, `"posted":[["x-old-1","x-old-2"]]`, server reverted;
    - before-read: `"posted":[]`, server kept.
  - **q3c.out**, migration with the reset before the read:
    - `"pushedKeyAtRead":"absent"`, `"recordKeysAfterRead":[]`;
    - posted x-old, server reverted.
  - q3b's own migration case read `present`, because module state was carried over from its earlier subtests. q3c runs it in a fresh process, which is what a page load is.

### Measured rates

Measured on a production-flag build: `/mnt/storage/dlesieur/scratch/c7-e2e/run-prod.sh` with `probe-tree/tests/e2e/bridge-stub/probe/prodBoot.spec.mjs`, Playwright 1.59.1, docker, `--network none`. The devil re-tallied the saved logs with `scratchpad/tally.py` over `out-prod2..4/e2e-*.log`.

| Engine / scenario | Boot loads with a reset |
|---|---|
| Chromium, all boot loads | **63/150** |
| (a) one stored session | 27/52 |
| (b) two stored accounts | 23/52 |
| (c) first load after the handoff | 3/13 |
| (d) load 1 | 10/33 |
| Firefox (a)–(c) | 0/45 |
| WebKit (a)–(c) | 0/45 |

- The coordinator reported 63/158. The saved logs give 150 boot loads; the 8 switch loads of out-prod3 (d) are not boots. The difference does not change the ruling: 42 % against 40 %.
- **All 63 resets came before the durable read.** `after_durable_read = 0` in every row, and the `idb read` line is present on every boot load.
- **Second effect.** A reversed boot leaves `ref = ""`, so the next real switch skips its reset. In out-prod4 (d), 15/25 switches reset, and the 10 that did not are exactly the 10 reversed boots.

### Unknown when this was written

- **The live rate.** The harness disables Chromium's cache over CDP and serves a patched index chunk. With the HTTP cache or the service worker serving chunks, the rate is unmeasured. The mechanism (two unordered promises) does not depend on the cache. The rate does.
- **The damage already done.** How many servers past reversed boots have reverted is unknown, and nothing here can detect or repair it (R-BR3).
- **What the skipped switch reset causes.** B then runs on A's record and A's started hydration. This is unmeasured; F-A closes it either way (BR3 c).
- **K10 with an empty record.** K10 was measured with 152 record entries present, so it does not cover this case. F-A removes the race's empty record; the other ways to an empty record remain (R-BR2).

## Decision

### F-A

The object-database effect acts only for the latest account id.

- Each run carries its own staleness mark, set by that run's cleanup.
- A stale callback does nothing: no reset, no ref write, no start.

### Questions answered

- **P1 live waits for F-A.**
  - P1 without F-A is not worse than main per boot: after migration, every measured reset fell before the read, where it is harmless.
  - But the migration load runs once per profile, and its revert writes the server. At the harness rate, about 4 in 10 Chromium migrations of a stale copy would revert.
  - F-A is small, and P1 live has other open gates anyway (ADR 0054 C7, ADR 0056 LL8). The wait therefore costs nothing.
- **F-A goes live first, on its own.** It is a cherry-pick onto the live main, under the LV-style procedure of ADR 0056.
- **F-A touches no re-run trigger.** It lives in `src/app/`, which is outside ADR 0054 C7.7's four paths and outside LL8's added `src/store/page-cache/`.
  - It changes nothing that RC9 or J-C7 measured: their resets fell before the read, which is harmless under P1.

## Conditions

### Develop unit, F-A

1. **BR1. Shape and scope.**
   - The decision becomes a pure function with the loader injected. App's effect calls it and returns its cleanup.
   - It lives outside every C7.7 path and outside `src/store/page-cache/`, for example under `src/app/`. A file named `objectDatabase*.ts` under `src/widgets/database-view/model/` would fire C7.7.
   - The diff touches only `App.tsx`, that module and `tests/canvas/`.
   - `git diff --stat 628f5de19 <head>` over the C7.7 paths and `src/store/page-cache/` is empty.
   - Where the previous id is stored keeps today's lifetime: one per App mount.
2. **BR2. The staleness mark is per run.** It is a closure local, or a generation number captured when the run starts.
   - A flag held in a ref, which the next run resets, is refused. React runs the cleanup of `""` before the id run, and the id run would then clear that flag, so the reversed `""` callback would act again.
   - The helper carries a `Caveat:` line. When several ids follow each other inside one import window, only the last acts, and the ids in between are never started (BR3 e).
3. **BR3. The canvas tests** (node:test, deferred loaders; there is no React test library in the repo).
   - **(a) Boot shape.** Run `""`, clean it up, run id; both loaders are still pending. Resolve them in order, then reversed. Each order gives 0 resets, exactly 1 start, and ref = id.
   - **(b)** `""` resolves before the id run: 0 resets, 2 starts, ref = id. This pins today's Firefox and WebKit order; a start is idempotent (`objectDatabaseBridgeSync.ts:227-229`).
   - **(c) A → B gives 1 reset and 1 start**, both after a normal boot and after a reversed one. The reversed case is the 10/10 skipped switch.
   - **(d) A → `""` → B gives exactly 1 reset in both timings.** If `""` resolves before B commits, the reset happens at `""`. Otherwise it happens at B.
   - **(e) A → B → C inside one window:** only C acts, with 1 reset against A.
   - **(f) The StrictMode double invoke**, simulated as mount(id) → cleanup → mount(id), with both loaders resolving afterwards in either order: 0 resets, 1 start.
   - **(g) Unmount:** cleanup, then resolve. Nothing happens.
4. **BR4. Mutants, each run and recorded as a command plus the failing test name.** Each of these must fail:
   - the stale check removed, which fails (a) reversed;
   - the BR2 ref-held flag, which fails (a) reversed;
   - a stale run that skips the reset but still writes the ref, which fails (c) after a reversed boot.
5. **BR5. The production-build probe.** Use the harness above, on the F-A tree:
   - Chromium (a) to (d), N ≥ 20 loads per scenario: 0 boot resets, and in (d) the switch resets equal the switches.
   - Firefox and WebKit (a) to (c), N ≥ 5: 0 boot resets.
   - `instrument.mjs`'s `check` regex will not match F-A's compiled code. The observer must be re-pointed so that it sees every reset call; on develop a reset removes no key.
   - **Vacuity arm.** The same harness and observer on the parent commit, in the same session, shows at least 1 boot reset on Chromium. Without it, a 0 proves nothing.
6. **BR6. The outcome check on Chromium, production build.**
   - The device holds a stale X_OLD with a matching record. The server holds X_NEW, with one row deleted.
   - Over N ≥ 20 boots across (a) and (b): the server keeps X_NEW, X_OLD is never posted, and the deleted row stays deleted.
   - The parent commit, on the same harness, shows at least 1 revert.
7. **BR7. Gates on the head.**
   - typecheck; lint with `--max-warnings 0`; the full canvas suite; the production build, run locally.
   - bridge-stub e2e on Chromium, Firefox and WebKit, including `refusedDatabaseSave.spec.mjs` and `importRefusedCreate.spec.mjs`. These prove the sync still starts and pushes. An F-A that never starts would leave sync silently off.
8. **BR8. No probe or devil file is committed.**

### F-A live on its own (the cherry-pick onto main)

9. **BR9. The base.**
   - The base is read at promotion time: the source commit recorded on the running web image. The live web is expected to be main 9d9520959.
   - The build is the base plus the F-A commit, and nothing else.
     - `git log <base>..<build>` shows only F-A.
     - `git diff --stat` shows only BR1's files.
10. **BR10. BR3, BR4, BR6 and BR7 run on that build tree, plus BR5's Chromium arm.**
    - On main the reset removes the push key, so the `removeItem` observer in `watchUserStore` is enough. The only remover is `objectDatabasePushBaseline.ts:62`.
    - The vacuity arm runs on the base.
11. **BR11. Before the switch:**
    - `git ls-remote` is run right before the push; the push uses an explicit refspec, never `--force`;
    - main CI is green;
    - a rollback tag of the current live web image is recorded;
    - the deploy runs under the standing go.
12. **BR12. After the switch:** the served index chunk's hashed filename equals the local build's.
13. **BR13. Before develop reaches main:** `git merge-tree` shows the cherry-pick and the develop original merge without conflict.

### P1 live

14. **BR14. P1's live candidate contains F-A.**
    - `git merge-base --is-ancestor <F-A> <candidate>` succeeds.
    - The C7.7 diff check over its paths still lists only the tombstone change.
    - If F-A slips, P1 live is re-ruled, not routed around.

## Alternatives considered

- **F-B, a serialized queue that compares each id with the last one applied.** It acts on every intermediate id, which is more code for the same outcome on every reachable sequence.
  - The two differ only when two distinct non-empty ids occur inside one import window.
  - At boot that cannot happen. `init` sets one id. `switchUser` (`useUserStore.ts:615-618`) and login (`:682`, `:695`) are interactive. `importBridgeSession` (`:870-886`) has no caller outside the store.
- **F-C, one cached import promise shared by every run.** Callbacks on a single promise run in registration order, which is FIFO by the language spec. That alone restores the Firefox and WebKit order.
  - It is smaller than F-A, but it keeps acting on superseded ids (the stale `""` run still starts).
  - Its guarantee holds only while every caller shares the one promise. A cached rejected promise would also never retry.
  - Acceptable in place of F-A only if it passes BR3 to BR6 unchanged, apart from (a)'s single start, which becomes 2. Not preferred.
- **Changing what a legitimate reset does under the durable sink.** Refused for this unit. It changes the account-switch contract, which needs its own ruling (R-BR1). Bundling it would also take away F-A's ability to go live alone, which rests on BR9's one-file scope.
- **Shipping P1 first and F-A after.** Every Chromium profile's one-shot migration would then run inside the race. A revert that lands is not undone by a later fix.

## Consequences

- Once BR1 to BR8 hold, the boot no longer wipes the push record. A reversed boot also no longer leaves the next account switch without its reset.
- The builder is on the hook for BR1 to BR13. The coordinator holds BR14 and the 0052 pointer.
- Reversing F-A means restoring the old effect. Nobody should, short of a React change that orders effect callbacks, and none exists.
- Follow-ups, each needing its own ruling:
  - the account-switch ruling (R-BR1);
  - an empty-record K10 measurement (R-BR2).

### Residuals (accepted, not closed by F-A)

- **R-BR1, a legitimate account switch.**
  - The reset clears the record but not the local databases (`objectDatabaseBridgeSync.ts:247-257`).
  - A switch whose reset lands after the durable read reverts the same way (q3b after-read).
  - Owner: the later account-switch ruling.
- **R-BR2, an empty record for any other reason.** For example: a device with a legacy copy and no record, a refused record write, or a cleared key.
  - It turns every database into ADR 0052 R5's case (a union over another device's later edit). K10 does not cover it.
- **R-BR3, damage already done.** Servers reverted by reversed boots since the effect shipped are neither counted nor repairable here.

## Risk

| Axis | The defect, unfixed | F-A | Why |
|---|---|---|---|
| Blast radius | 4 | 2 | Unfixed: every Chromium session on a stale multi-device copy. F-A: one effect. |
| Reversibility | 5 | 2 | A revert lands on the server and has no undo here. F-A is reverted by one image rollback. |
| Cost on failure | 4 | 3 | Unfixed: a silent revert, and deleted rows come back. F-A wrong: either the sync silently stops (edits stay local), or the resets come back; BR5 and BR7 catch both. |
| Confidence | 3 | 3 | The mechanism is reproduced, and the reset path is read in code. The live rate, the skipped-switch consequence and the empty-record K10 are unmeasured. |

Worst axis: reversibility of the unfixed defect (5). That is why F-A goes live alone and first.

## Re-ruled 2026-11-18: BR7 on 891d7fc52 (PROCEED-WITH-CONDITIONS BR7a–BR7f)

BR7 as written asks Firefox and WebKit to show a push. No tree shows one: the production harness is blind there on the parent too (logs under `scratch/c7-e2e/`).

- **BR7a. For develop, BR7 reads as follows.** F-A is no worse than its parent on every engine. The sync starts on all three engines, and pushes on Chromium. Met on 891d7fc52:
  - **Push code is untouched.** The diff is `App.tsx`, `objectDbAccountSync.ts` and their test. F-A reaches the push only through `startObjectDatabaseSync`. Hydrate pushes at `objectDatabaseBridgeSync.ts:194`.
  - **The sync starts on Firefox and WebKit.**
    - The patched callback is reached with `reset=false` (`out-fa5fw`): Firefox 50, WebKit 20. Its next statement is the start.
    - 0 boot resets; the switch resets 5/5 on each engine.
    - GET on every load: 20/20 on each tree and engine (`out-oc-*`).
  - **Chromium pushes.** refusedDatabaseSave's `posts.length > 0` passes 27/30 on F-A.
  - **Failures match the parent.** Firefox: 11 failing tests, the same set (`out-fa8f` vs `out-fp7f`). With the service worker blocked: 5/5 refusedDatabaseSave failures at `app.mjs:52` on all four arms.
- **BR7b. A Firefox and WebKit push is shown before F-A goes live, and again before P1 goes live.**
  - Run in BR10 on the build tree and on the base, and in BR14 on P1's candidate and its parent.
  - The probe:
    - production build, `serviceWorkers: 'block'`, one `goto` per fresh profile, no legacy pair;
    - edit one cell through the UI;
    - count POST `/api/object-databases` whose body carries the edited value;
    - count `vite:preloadError` events and aborted navigations.
  - Size: N ≥ 10 clean runs per engine per arm, plus a Chromium control. A run with any preloadError or aborted navigation is excluded and reported.
  - Outcomes:
    - the Chromium control has a run with 0 matching POSTs: the probe is vacuous, UNKNOWN, and nothing goes live;
    - on any engine, fewer F-A runs than base runs show a matching POST: BLOCK;
    - both arms show 0: F-A may go live (no worse), and P1 live is blocked on Firefox and WebKit until a push is shown.
- **BR7c. The two flakes stay as residual R-BR4.** Both are test-locator defects, at the same rate on both trees, and fail before any sync assertion:
  - handleAlignment:88: 17/30 vs 16/30. All 33/33 failures are `.osionos-page [data-database-title]` `.first()` resolving to a hidden Rename button.
  - refusedDatabaseSave: 3/30 vs 3/30. All 6/6 are `databaseHelpers.mjs:30-31` `.first()` resolving to the hidden `sys:my-tasks` home-dashboard block.
  - 0 failures at the push assertion (`:42`).

  In BR10, parity means the same failure locations, not the same rate. Every failure sits at those two lines, and refusedDatabaseSave passes ≥ 20/30 per arm.

  The locator fix is its own test-only unit. It never rides in the F-A cherry-pick (BR9).
- **BR7d. BR10's e2e evidence, on main+F-A and main.**
  - Chromium production harness:
    - the full bridge-stub suite, with the two flaky specs ×30 under BR7c;
    - BR5's Chromium arm and BR6.
  - Firefox:
    - the full suite, failing set identical to the base;
    - start evidence on (a)–(c), N ≥ 5, with 0 boot resets on the `removeItem` observer and a GET per load;
    - BR7b.
  - WebKit: start evidence and BR7b only.
  - Not run: the full WebKit suite. It joins R-BR5.
- **BR7e. Fact 7 needs no fix before P1 goes live.**
  - It is already live and affects both trees.
  - A preloadError reload is a pagehide followed by a boot, the same event as F5 during boot. P1's unload path already has to survive that (`knownDatabaseUnload.ts:30`).
  - KDS itself arrives through the dynamic import (`App.tsx:236`). An import cancelled before it evaluates holds no KDS state.

  Condition: P1's Firefox and WebKit live evidence (C7, LL8, the journal) uses one `goto` and counts preloadErrors. Only clean runs count toward N.
- **BR7f. R-BR5, its own unit.**
  - On Firefox and WebKit, a navigation during boot cancels lazy imports. `vite:preloadError` then fires, and `main.tsx:49-56` swaps the navigation for a reload, at most once per 10 s per tab.
  - Measured: Firefox 15 preloadErrors, WebKit 5, Chromium 0 (`out-diag2`).
  - User impact: the Prismatica handoff (`App.tsx:328`) or OAuth (`connectionsOAuth.ts:46`, `useAiConnections.ts:137`) can bounce once.
  - Test impact: the production e2e on Firefox and WebKit is blind, and CI runs Chromium on the dev server only. The dev server has no preload helper: Vite emits the event only from `buildImportAnalysisPlugin`.

Risk: blast 2, reversibility 2, cost 3, confidence 3. Worst: the push on Firefox and WebKit is unknown on every tree, so it is the confidence axis. BR7b closes it before anything goes live.

## Re-ruled 2026-11-18: BR10 on 0333d7966 (PROCEED-WITH-CONDITIONS BR10a, BR13a–BR13d, BR7g–BR7j)

0333d7966 is main 9d9520959 plus the F-A cherry-pick: patch-id 65fb2c9daa62, the same as 891d7fc52's. `git log 9d9520959..` shows only F-A, in 3 files.

Met: typecheck, lint, canvas 5539/5539; BR3 13/13; BR4 3/3; BR5 Chromium 0/200 boot resets vs 75/200; BR6 0 reverted lines vs 10; BR7b 12/12 per engine per arm, Chromium control positive.

- **BR10a. Each arm ran its own tree.** Checked by this ruling, because the full-suite and ×30 runs reused symlinked dists (`br7b.sh`, `br7d.sh`): main+F-A → `dist-l-smoke`, main → `dist-p-main`.
  - Every trace serves one index-chunk pair per arm: `hzb01WLo`/`BvSk039g` vs `CKY6RiEm`/`DXIH1oCj`. These are the chunks listed in `out-l-smoke/build.log` and `out-p-main/build.log`.
  - The two builds emit the same 638 (name, size) pairs except the entry chunk: 859.55 vs 859.62 kB. The develop pair 891d7fc52/628f5de19 differs the same way: 860.78 vs 860.86 kB.
  - `t-fal`/`t-main` equal `git archive` of 0333d7966/9d9520959 outside submodules, and differ only in F-A's files.
  - Caveat: a fingerprint at 0.01 kB. The l-smoke command is unlogged (`t-fal` mtime 01:11, build 01:12). BR12 checks the live build itself.
- **BR7b for F-A is met on a `--mode test` build.**
  - Its flags gate the boot (`userStore.helpers.ts:37-38`), not the push (`objectDatabaseBridgeSync.ts:67-69`).
  - The live-flag boot on Firefox and WebKit is `out-b-fw-*`: 0 boot resets and a GET per load.
- **Item 1. BR13 gates develop→main, not F-A live.** Restated as follows, and met now:
  - Merging the cherry-pick adds no conflict beyond the base's: the same two files in `mergetree.out` and `mergetree-base.out`, neither in F-A's diff.
  - `git cherry -v origin/develop 0333d7966` marks 5/5 commits `-`.

  Merging main into develop with develop's tree is PwC. Patch-ids hide what that merge drops:
  - a main hunk develop later changed or reverted;
  - a `+` commit, or a merge commit (git cherry skips merges);
  - a commit landing after the check.

  Conditions:
  - **BR13a.** No `+` from git cherry. `git rev-list --merges <mb>..main` is empty, or each merge is ruled.
  - **BR13b.** In `git diff develop main -- $(git diff --name-only <mb> main)`, every main-side hunk is ruled superseded. A gitlink needs `--is-ancestor` inside the submodule.
    - Today: 7 paths, 2 differ, 31 lines.
    - Develop is a superset: `noticingWriter` wraps the same `setItemEvictingPageCaches`, and `QuotaStorage` moved with the same members.
  - **BR13c.** `git diff develop <merge>` is empty, gates and CI run on the merge, and main fast-forwards with no `--force` after a fresh `ls-remote`. A main that moved fails the push.
  - **BR13d.** A push to main publishes the `node-pages` release (`node-pages.yml:4-6`) and carries all 51 develop commits. Main advances only when every develop unit is cleared for live, and P1 is not.
- **Item 2. BR7g. The parity bar is: the build's failing set ⊆ the base's, with the same spec:line and assertion message.**
  - Met: {connectivity:61, :90, handleAlignment:88} on both arms; settingsDeveloperAuthorizedApps:67 fails on main only.
  - The connectivity cause is not needed for F-A:
    - it fails at boot, before any cut;
    - "Offline" is only `navigator.onLine` (`connectivity.ts:46,57`);
    - the messages are identical;
    - F-A has no connectivity code.
  - But :58 is the offline-edit push, and this harness never reached it. Condition: main CI's `test-bridge-stub` job (`ci.yml:432`, runs on main) on 0333d7966 passes connectivity :58 and :84. A retry pass is reported as flaky.
  - **R-BR6.** This harness's connectivity results back no claim, P1 offline included, until `navigator.onLine` under `--network none` is shown.
- **Item 3. BR7h. BR7c's bar is amended.** Every build failure location also fails on the base, with a count ≤ the base's + 3 of 30. A build-only location blocks. The push assertion has 0 failures, and refusedDatabaseSave passes ≥ 20/30.
  - Met, build vs base: handleAlignment:88 12 vs 15; :101 1 vs 1 (handle offset, no F-A layout code); `databaseHelpers.mjs:31` 2 vs 5; refusedDatabaseSave passes 28/30 vs 25/30.
  - Caveat: +3 misses a regression under ~10 % at a shared location (binomial SD ≈ 2.7 at p = 0.5).
- **BR7i. Still binding before the main push:** BR9 (the base read from the running web image), BR11 and BR12.
- **BR7j. P1.** 891d7fc52 contains P1 and pushed 12/12 on Firefox and WebKit, as did 628f5de19. So the "never pushes there" branch is gone. Still missing:
  - (i) BR7b on the real P1 candidate, which needs the C7 tombstone and so is not 891d7fc52:
    - a live-flag build (`entry-prod-cfg.sh`);
    - N ≥ 10 clean runs per engine, plus a Chromium control;
    - the parent arm only if a run misses.
  - (ii) BR7e: C7, LL8 and the journal on Firefox and WebKit.
  - (iii) BR14's ancestry and C7.7 checks.

Risk:
- F-A to main: blast 2, reversibility 2 (a revert commit and an image rollback; node-pages rolls forward), cost 3, confidence 2. Worst: cost.
- develop→main: blast 4, reversibility 4, cost 4, confidence 3. That is why BR13d holds main.
