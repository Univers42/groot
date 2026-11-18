# 0052. The KDS IndexedDB move still loses or risks the edits named here, and is not loss-free

- Status: accepted as a residual register. It does not lift any condition. Live promotion of osionos develop stays suspended until J-C7 ([ADR 0055](0055-the-kds-unload-journal-is-per-tab-keyed-by-every-base-it-may-land-on-and-never-regresses-an-acked-record.md)) and C7 ([ADR 0054](0054-the-kds-indexeddb-writer-reaches-develop-only-after-its-coverage-fixes-and-is-not-promoted-live-before-pagehide-survival-is-measured.md)) pass. C7 was re-ruled on 2026-11-17 (ADR 0054, C7.1 to C7.8): the per-profile measurement is withdrawn and an in-place tombstone meets C7 by construction; it is on osionos develop as `fdb2b6162..628f5de19` (note of 2026-11-17 below). R7 is fixed (J-C10, osionos `38c38cf36`), confirmed by the devil's re-rule of 2026-11-17 recorded in ADR 0055; osionos develop was fast-forwarded to `38c38cf36` on 2026-11-17. On 2026-11-17 the devil's re-rule on a00b62265 (ADR 0055) also blocks live promotion until F1 lands under F-C1 to F-C9 and the RC9 re-run (F-C7) passes; see R9. F1 (osionos `cc5145417..fc0d7b408`) closed R9 on develop; the devil's note of 2026-11-17 on fc0d7b408 (ADR 0055) lifts the RC9 live block once FL1 to FL3 hold.
- Date: 2026-11-17
- Deciders: devil (rulings in 0054 and 0055), osionos main session / builder (live with it)

## Context

Branch `feat/kds-idb-p1` (osionos worktree `/mnt/storage/dlesieur/wt/osionos-net-retry`) moves the known-database state (KDS) and its push record from localStorage into IndexedDB `osionos-kds`. This is the P1 design ADR that 0054 (C5) and 0055 (J-C9, J-C5 measurement half, re-rule section) require. Their names are used as written there: N1b, N1c, N2, N2′, R1 to R8, CAND, J-C*. This ADR adds none.

It states what P1 does not do, so that nobody claims it is loss-free. The sources are 0054, 0055, `.claude/agent-memory/benchmarker/i10-pagehide-idb-survival.md` and the J-C5 artifact below.

## Decision

P1 is recorded as below. Every residual is accepted, closed, or open with the condition that governs it. None is claimed to be zero.

### N1b, N1c, N2, the rejected candidate, the pre-readiness drop

- **N1b (closed for every origin that holds legacy text, osionos `fdb2b6162`; residuals R-C7a and R-C7b below).** Every growing write is refused, even after the page caches are evicted, so the 15-character flag `osionos.kds.idb` cannot be stored. Since `fdb2b6162` the legacy state key is then overwritten in place with the 20-character tombstone `{"kdsRetired":"idb"}`, read back, and only then the push record is removed; a tombstoned origin is read pull-only, exactly as a flagged one (ADR 0054 C7.1, C7.2). Before that commit both legacy keys were kept and no retirement was claimed (0054 re-ruling), with this consequence: A later load where IndexedDB fails runs the legacy localStorage path and pushes the old local copy over a newer server copy. That path runs today on every load of such an origin. Under P1 it runs only on loads where IndexedDB fails.
- **N1c (accepted residual, proved).** The flag is refused at migration. Session 1 commits. Session 2 runs on IndexedDB fallback, offline, and its storage writes succeed again, so its edit e2 goes to the legacy key. At session 3 the IndexedDB copy wins and the now-storable flag retires the legacy key that holds e2. Result: e2 is lost (`{"local":["x-1"],"server":["x-1"],"legacy":false}`). It needs N1b's precondition. Closed for every origin that holds legacy text by the same tombstone: session 2's fallback is read-only, so e2 is never written to the legacy key (canvas test C7-N1c; e2e `kdsRetireTombstone.spec.mjs`, Chromium and Firefox). The per-profile measurement of 64 free characters is withdrawn (ADR 0054 C7 re-rule).
- **R-C7a (accepted residual, unchanged).** N1b and N1c under a browser that refuses every write, shrinking writes included. No engine measured does that (Chromium 147, Firefox 148, WebKit 26.4; Mac Chrome is inferred from the same source, not measured). The tombstone write then fails and both keys stay byte-identical, which is the N1b and N1c above, not a new loss.
- **R-C7b (accepted residual).** A first-session origin with no legacy text, or text under 20 characters, that non-evictable keys alone fill gets no marker. Only then can a later offline fallback session write a legacy copy that the next load's retirement orphans. Nothing is removed in this case.
- **Unchanged by the tombstone.** A budget-abandoned tab, or a pre-P1 tab open across the deploy, can overwrite the marker with its own legacy write once the origin has room; the next retirement then orphans that tab's unpushed edits, as it does after a stored flag.
- **N2 (closed by the per-tab unload journal, ADR 0055).** The pagehide flush pushes the live state before the IndexedDB commit resolves. When the commit is lost in unload, the server holds b-2 and the stored copy holds b-1, and the reload reverted the user's own newer edit. I10 measured the loss (below), so the journal ships: one key per tab `osionos.kds.journal.v1.<tabId>`, written at visibilitychange→hidden and at pagehide, applied inside the readiness transaction. In the devil's model T1 to T8 pass and the 7 failures are defeated variants. The journal fixes N2 only inside the cap (see "The cap"). It does not fix N2′, R1 to R6 or R8.
- **CAND, rejected.** The candidate removes `osionos.knownDatabaseState.v1` before the flag is stored, to cure N1b. It deliberately creates the state I6 forbids, no flag and no legacy text. Under a transient refusal, test CAND loses an unpushed edit that was migrated into IndexedDB, because the redo rule re-migrates a later fallback session's seed-based copy over the migrated copy. It does not fix N1c either. CAND passes at HEAD and fails under mutation M12. Record: `.out-of-scope/legacy-kds-removal-before-the-migration-flag.md`. Reopen when the flag can be stored where a full localStorage cannot block it (a cookie), or when the redo rule stops treating an unretired legacy copy as newer.
- **The pre-readiness drop.** Writes before readiness are no-ops. Edits made before readiness are dropped, not queued. A queue would be a second, unjournaled copy replayed after readiness, which is the stale-capture class that ADR 0051 and B5 exist to close. The window is bounded by the 3 s budget (I8). Measured readiness (I10, cold relaunch, 4.6 M characters): Chromium p50 12.1 ms, p95 15.3 ms; stock Firefox 158 p50 21 ms, p95 25 ms (max 381 ms); 0/20 over the 3 s budget. A user who types inside that window loses the edit; nothing reverts.

### I10 numbers (0054 C4, 0055 re-tally, benchmarker memory)

Harness `/mnt/storage/dlesieur/scratch/i10`, N=20 per row, docker headless and xvfb headed, fresh profile on NVMe. Raw jsonl: `/mnt/storage/dlesieur/scratch/i10/out/*.jsonl`.

- An IndexedDB commit started in pagehide is lost on navigation in every row: 20/20 in Chromium 147, Firefox 148 and stock Firefox 158, at 4.6 M and 50 K characters.
- Firefox tab close loses 20/20, also with the visibilitychange handler armed.
- Chromium headed close-plain at 4.6 M survives 16/20 (the benchmarker's summary said 19/20; 0055 corrected it). Chromium headless close at 4.6 M survives 5/20.
- Firefox 148 at 4.6 M does not survive a commit started at visibilitychange: 0/20 on navigation, 2/20 headless and 0/20 headed on close.
- Explicit `tx.commit()` is not a fix: Chromium navigation 0/20 at 4.6 M, Firefox tab close 0/20.
- A commit started earlier, with a millisecond-scale lead, survives 18 to 20 of 20 everywhere.

### localStorage survival numbers (0055, the journal medium)

Harness `/mnt/storage/dlesieur/scratch/devil-j-ls/`, one synchronous `localStorage.setItem` per unload event, N=20 per row unless stated.

- Chromium 147: 20/20 on navigation, close-plain and ctx-close, at 50 K and 2 M characters.
- Stock Firefox 158: 20/20 on navigation and ctx-close. Close-plain with a pagehide-only write: 0 of 20 present (missing 20/20). With the write also at visibilitychange→hidden: 20/20. This is why the journal writes at both events.
- Read race, Chromium navigation at about 2.26 M characters, 40 runs per arm: two writes 3/40 old value read by the next document; one write 1/40 (late, not lost); a read delayed 150 ms 0/40. At 1 M characters: 0/40.
- `setItem` time at about 2.3 M characters: Chromium p50 4.8 ms, p95 6.0 ms, max 7.5 ms; Firefox 158 p50 3.0 ms, p95 4.0 ms. At 1 M, Chromium p50 2.4 ms.

### Open residuals

| Name | What is lost or reverted | Direction |
|---|---|---|
| R1 | The read race above the cap: the next document reads the old journal value (1/40 at about 2.26 M characters, 0/40 at 1 M). | revert risk |
| R2 | The same database edited in two tabs that both unload inside the window: the earlier journal's slice is dropped, as with two devices. | loss |
| R3 | A crash with no visibilitychange: no journal is written. | loss |
| R4 | Over the cap (below). | loss |
| R5 | A dirty database is unioned over another device's later edit. The legacy writer does this today. | revert of the other device |
| R6 | Two live tabs overwrite each other's whole-state commits. P1 already does this. | loss |
| N2′ | The post-commit live push sends an edit made during the commit await (`knownDatabasePersistence.ts:102`). | revert risk |
| R8 | First-session window. When the store held no copy at readiness (a new browser, cleared site data, or IndexedDB eviction), readiness writes nothing (`knownDatabaseDurableCopy.ts:161`), so the session has no base until its first commit resolves. That commit waits for a 1 s debounce that every edit restarts (`knownDatabaseFlushSchedule.ts:16,58`), then an idle period of up to 2 s. Steady editing therefore keeps the window open for the whole burst, not for 1 s. At pagehide the unload commit is the only base and equals the live state, so no journal is written (`knownDatabaseJournal.ts:89,147-148`; outcome "unneeded" at `:164`) and the push is still sent (`:184`, `knownDatabasePersistence.ts:111`). That commit is lost on navigation (I10). Online, the edit survives only if the non-keepalive pagehide push lands. Offline, without a bridge, or in a seed database (never pushed), it is lost. Reproduced end to end: `tests/e2e/functional/templateUse.spec.mjs:52-80` (use a template, type a row title, reload within about 3 s) fails on 38c38cf36 and passes on 4b6e8fdf2 (CI run 44037496549, shard 6/6). In the canvas suite, D6c, `zz-r8-first-session-reload.test.ts`, and devil-r8 R8-1 and R8-4 fail at 38c38cf36. The pre-P1 localStorage writer stored synchronously and did not lose this edit, so R8 is a regression against legacy. The earlier sentence "P1 without a journal behaves the same" compared P1 only with itself. Closed on develop by a00b62265 (A2, ADR 0055 re-rule 2026-11-17); live waits for RC9. | loss |
| R9 | First-session inflation over the cap, measured on a00b62265 by RC9. An inline embed's mount writes `loadLimit` 8 into every table, list and timeline view of the whole store. No user edit is involved; the host's own post-load persist does it, against an empty baseline (ADR 0055, re-rule on a00b62265). All 10 seed databases then differ from the seed base, which adds about 447,000 characters to the journal, plus every hydrated database whose server copy lacks the fill (L4: one 236,409-character database made a 683,197-character journal). A first-session edit of 600,000 characters is lost in 41 of 80 runs; at 500,000 it is 0 of 80. Legacy keeps it, so this is a regression from legacy in R4's class. It is open until the first commit resolves and its record catch-up lands. Closed on develop by F1 (osionos cc5145417..fc0d7b408, ADR 0055 note on fc0d7b408): the inline embed's projection is no longer written, so the first-session journal is the edit plus a few hundred characters (RC9-F1 pad runs: 600,230 to 600,232 and 900,229 to 900,232 characters, 0 lost in 160 runs). | loss (closed) |
| R10 | The inline embed's view Limit, after F1. Nothing is lost; a view setting is wrong in one of four ways. **(a)** In an inline embed, re-selecting the Limit it already shows is not written: 8 on a view that had none, or the cap on a view stored above it (probe A4: shown 3 over a stored 100, the user picks 3, 100 stays; picking 2 writes 2). Inside the embed nothing differs, because the cap clamps the display anyway; on a full page the pick is written. **(b)** A view duplicated inside an embed, whose Limit equals the projection, is stored with no Limit (A2: source 100, copy none). **(c)** Pre-existing, unchanged by F1: a table, list or timeline turned into a board inside an inline embed is stored with `loadLimit` 8 (A1). **(d)** Pre-existing, unchanged by F1: with two mounts, a stale embed's edit writes its projected 8 over a Limit another mount stored (A3: 25, then 8). This is the record-level last-writer-wins that already applies to every view field. (c) and (d) reproduce identically on a00b62265. The `loadLimit: 8` values the legacy writer pushed to server copies before F1 are left in place (F-C6), because they cannot be told apart from an explicit 8; a scrub needs its own ruling. Probes: `/mnt/storage/dlesieur/scratch/devil-rc9/devil-f1-attack.test.ts`. Closing (c) and (d) does not need a new ruling: keep the store's Limit when the view's Limit is unchanged against the window's baseline view, and gate on the stored view's type. | view setting, never a row |
| R11 | The boot race ([ADR 0057](0057-the-object-database-sync-acts-only-for-the-latest-account-id-and-p1-goes-live-only-on-a-build-that-has-it.md)): a reversed ""/id effect callback wipes the push record, so every database takes R5's union path and a stale device reverts the server. Live on main; under P1 it hits the migration load and any reset after the read. Closed by F-A (0057 BR1–BR8). | revert of the other device |

R1 to R6 and N2′ are the residuals of corrected J as ranked in 0055 (alternatives considered). N2′ is not closed by the journal.

### R9's cause outside P1: the inline fill is live today

The fill is not a P1 bug. `applyAdapterOptions` dates from c98affa1b (2026-07-09). The legacy writer pushes every non-seed database, so a user database whose view was filled reached the server: on every device, a full-page view shows 8 rows per page instead of 50. An embed with `recordLimit` N also overwrites an explicit Limit on unrelated databases with N (probe L2). It affects view settings, never rows. F1 stops new writes. F-C6 deliberately leaves the existing stored or server 8s in place, because they cannot be told apart from a user's explicit 8; a scrub needs its own ruling. F1's own residuals are R10 (a) and (b).

Observed and not ruled: the sys adapter's "No baseline, no diff" guard (`sysDatabaseState.ts:240-242`) is dead, because the host always passes a baseline (the empty initial store on the first load).

### R7, deletes in the unload window

R7 (D6a): a row deleted in the unload window, the push not landed, the IndexedDB commit lost. The reload gave `local ["a","b","c"]` and `server ["a","b","c"]`: the deleted row came back and was pushed, because the journal did not carry `deletedPages`. The pre-P1 legacy writer stores tombstones synchronously, so this was a regression in the resurrect direction, never a loss.

**Fixed by J-C10 at osionos commit `38c38cf36`, confirmed by the devil on 2026-11-17** (ADR 0055, "Re-rule 2026-11-17 on 38c38cf36"). The journal carries the whole live tombstone set and the readiness unions it into the stored one; the bases gate limits the union to ids the stored copy or the lost commit would hold (probes D10, D11; mutations JK, JL, JN, JP red). The tombstones count toward the 1,000,000-character cap: about 22,000 tombstones (about 44 characters each) reach it alone. Residual: an id the tab pruned during a lost unload window stays tombstoned until the next sync, as on the no-journal path. This ADR does not use the user-acceptance branch of J-C10.

### The cap, and what happens over it

- The journal cap is 1,000,000 characters, non-Latin-1 counted as 2 (J-C5).
- Over the cap, or when `setItem` is refused after page-cache eviction: no journal is written and no pagehide push is sent for that unload. The last edit (made in the last 3 s or less before leaving) is lost. It is never reverted.
- The ids in `bases` (JM2) are bounded to the readiness id, the last resolved id and the pending ids. Before JM2, 3600 resolved commits held 114,094 characters of ids and the ids alone passed the cap at about 31,500 commits (about 8.75 h at one flush per second).

### J-C5 measurement: the largest live single database

Measured 2026-11-17 07:00Z, read-only, on `osionos_object_databases` on the server.

- Artifact: `/mnt/storage/dlesieur/scratch/jc5/slice-size-20261117T0700Z.txt`. Script: `/tmp/claude-1000/-home-dlesieur-Documents-groot/35cacb48-6680-4c18-82bf-39404e5fc5a2/scratchpad/jc5-slice-size.sh`.
- Largest single database: 285,168 characters. Worst case about 570,000 if every character cost 2.
- p95 per account: 173,082 to 226,310 characters (10 accounts listed).
- Largest account: 178 databases, 4,554,902 characters (`max_chars` 273,466 for that account).
- One database fits under the cap with margin. Arithmetic, not measured: 3 databases of 285,168 characters (855,504) fit; 4 (1,140,672) pass the cap; at 2 characters each, 2 databases (1,140,672) pass it.

Caveat: this is the server copy. A local slice with unpushed edits can be larger. Editing several of the largest databases within one unload window can pass the cap, and then the R4 rule applies. A 10-row sample of accounts is not every account.

### Forward-only `migrated:<tabId>`

The migrated copy's id is `migrated:<tabId>`, unique per tab, and the redo rule matches on the prefix (J-C1; upheld in 0055 re-rule, deviation 2). Builds before osionos commit `1edca24b9` do not recognise it as migrated. Reverting below that commit disables the redo rule for copies migrated after it. Rollback never goes past `1edca24b9`. Like K7 A, this is forward-only.

The migration itself is also one way (0054): migrated tabs have no legacy keys, so a pre-P1 build loads seed state, loses local edits that were not pushed, and reopens S1.

## What P1 does not do

- It does not make the unload edit loss-free. R2, R3, R4, R6 and R9 lose edits.
- N2′, R1 and R5 can revert one. R9 lost a first-session edit that legacy keeps until F1 landed (a00b62265: 600,000 characters, 41 of 80 runs lost; fc0d7b408: 0 of 160 at 600,000 and 900,000).
- It closes N1b and N1c only for an origin that holds legacy text of 20 characters or more, in a browser that accepts a shrinking write on a full origin. R-C7a and R-C7b remain.
- It does not queue edits made before readiness.
- It does not journal over the cap, and it does not push at pagehide over the cap.
- It does not carry a `removed` field (`.out-of-scope/kds-journal-removed-databases-field.md`) and does not ship J3, the eager commit (`.out-of-scope/eager-kds-commit-debounce.md`).
- It has not been run end to end in a real browser build (J-C7).

## Consequences

- Live promotion of osionos develop stays suspended in writing until J-C7 (real app build, Chromium 147 and stock Firefox 158, N≥20 per cell, last edit on the server after reload, 0 reverts) and ADR 0054 C7 pass. C7 is met through C7.1 to C7.8 (re-rule of 2026-11-17), not through a per-profile measurement. Merging to develop is allowed only with that suspension, which only a dated note in this ADR lifts.
- F1 met F-C1 to F-C8 on fc0d7b408 (ADR 0055, note on fc0d7b408); this block is F-C9. The RC9 live block lifts with FL1 to FL3. J-C7's required cells passed in RC9 and again in RC9-F1.
- No document, release note or status line may say "no data loss" or "0 at risk" for this move. The residuals above are the accurate statement.
- Removing the journal later restores today's N2 and does not touch the stored copy.
- Caveat for the numbers: I10 and the journal harness are docker-driven (Playwright, stock Firefox over WebDriver BiDi), not a user's Ctrl+W, and N=20 bounds a rate only to about ±15 %.
- Closed 2026-11-17: the devil's ruling on `38c38cf36` (R7) is recorded in ADR 0055 and reflected above.
- Note of 2026-11-17 (C7, suspension NOT lifted). The tombstone is osionos develop `fdb2b6162..628f5de19`, CI green on `628f5de19`. C7.1 to C7.6: `gates.sh c7-review-628f5de19` gives typecheck rc=0, lint rc=0, test-canvas rc=0 (5687 of 5687, canvas tests C7-N1b, C7-N1c, C7-CAND, C7-prefix, C7-common, C7-tomb-no-copy, C7-short-state, C7-old-reader); `kdsRetireTombstone.spec.mjs` passes 3 of 3 on Chromium 147 and Firefox in the main session's run and 30 of 30 on Chromium, Firefox and WebKit in the builder's, and fails 9 of 9 at load 1 before the fix; mutants Ma, Mc, Md, Me, Mg are killed and Mb is equivalent. C7.7: `git diff --stat fc0d7b408 628f5de19` over the C7.7 paths lists only the tombstone in `knownDatabaseDurableCopy.ts` and the 63c376994 write-notice change in `pageStore.helpers.ts` (the room-making definition is unchanged), so J-C7 and RC9 on fc0d7b408 stay valid. C7.8 is this register. Live promotion stays suspended: ADR 0057 BR14 requires the promoted commit to contain the boot-race fix F-A, and a later dated note here lifts the suspension once BR1 to BR8 are met.

## P1 live checklist, 2026-11-18 (devil; the suspension is NOT lifted)

The candidate is M, ADR 0057 BR13c's merge of main into develop with `git diff develop M` empty. Evidence on a build of 891d7fc52's tree counts for M only when `git rev-parse M^{tree}` = `be127dd815c28474e8c37ba95060164a12858a4b`. That hash covers the 8 gitlinks and `pnpm-lock.yaml`, which is unchanged since 4b6e8fdf2. M still needs its own CI run and BR12. The harness builds a directory, not a commit. A run counts only on a detached worktree at 891d7fc52 with `git status --porcelain` empty and every `git submodule status` line starting with a space, both saved in the out dir. An export such as `c7-e2e/t-fa` counts only with a file-for-file `git hash-object` match against `git ls-tree -r`.

Met (pointer only):
- C7.1–C7.8: the note of 2026-11-17 above, CI green on 628f5de19. J-C7 and RC9 on fc0d7b408: ADR 0055, fc0d7b408 note (RC9-F1 740 runs, 0 lost, 0 reverts).
- C7.7 on 891d7fc52, run over the C7.7 paths (0054:219-226): `git diff --stat fc0d7b408 891d7fc52` = `knownDatabaseDurableCopy.ts` 41 and `pageStore.helpers.ts` 22, "2 files changed, 48 insertions(+), 15 deletions(-)". The room-maker body is unchanged (`pageStore.helpers.ts:315`). `git diff --stat 628f5de19 891d7fc52` = F-A's 3 files.
- FL1–FL3: the F1 commits are ancestors of develop and no remote tip sits at 7520d20c3; `persistAsHost` 7× in `known-database-embed-limit-write.test.ts`; groot 637ee597. C5/J-C9 hold through C7.8 (this register); J-C10 through 38c38cf36 (0055).
- BR14 ancestry: develop's tip 891d7fc52 is F-A. BR13a today: `git cherry -v origin/develop origin/main` = 5 `-`, 0 `+`, and `git rev-list --merges 4b6e8fdf2..origin/main` = 0. BR13b today: 10 main paths, 2 differ (`useUserStore.ts`, `tests/canvas/user-store-fixtures.ts`, 31+/15−), develop the superset.
- BR7e, journal, Firefox, J-C7 and online server-title cells: recounted in `devil-br10/recount-rc9f1.txt`. Every J-C7 Firefox cell has 22 `GET /api/object-databases` for 20 trials (setup, first boot, one per trial). Every server-title cell has 41 for 20. No trial shows a surplus boot.
- LL8 does not apply. `git ls-tree -r --name-only origin/develop -- src/store/page-cache` = 0 files. `knownDatabaseJournal.ts` has 0 diff lines fc0d7b408..891d7fc52 and defines `storedLength` itself (:104). Both of LL8's triggers are L1a's (0056 LL8). It fires again if L1a or any page-cache path joins.
- R-BR6 binds no item. `navigator.onLine` is read only by `useConnectivityNotices.ts`, `WorkbenchStatusBar.tsx:140` and `usePageSync.ts:280-281`. `connectivityAwareFetch` (`connectivity.ts:22-35`) gates nothing. No KDS code reads it.

Open. Run them in this order. O1–O4 run now on 891d7fc52's tree; O5–O9 need F-A live (main CI green with connectivity :58/:84 under BR7g, the F-A deploy, and BR9/BR11/BR12 on it).
- **O1. ADR 0056 A5/A6** (b7a5e1264..63c376994, carried by M). There is no record of a check: a grep of docs/adr and devil memory finds only design text; A1–A4 were met at 0056:376.
  - The builder maps each A5 and A6 clause to its canvas test.
  - Then run `gates.sh` on the tree: typecheck, lint, full canvas. Cite each gate's rc line.
  - BLOCK: a clause with no test, or any rc ≠ 0.
- **O2. BR7e, the remaining Firefox journal cells (RC9-F1).**
  - (a) online-new-db (37/38 GETs per 20, plus top-ups): a per-trial GET count from the bridge jsonl. A trial above its expected boots is excluded.
  - (b) Offline close cells: no preloadError can occur, because the leave is `page.close` and no booting document navigates (`run.mjs`). Ruled clean.
  - (c) The 5 offline nav cells have no bridge log, and `run.mjs:231` records `pageerror` only. Re-run them with a `vite:preloadError` listener in the init script (as `push.spec.mjs:44`), using the `rc9-f1` production offline build and stock Firefox 158.
  - Bar: N ≥ 20 clean per cell, 0 lost, 0 reverts. BLOCK: any loss or revert in a clean run, or < 20 clean.
- **O3. C7.5 on Firefox and WebKit.** `kdsRetireTombstone.spec.mjs` loads 4 times plus a reload by design (:113-140) and counts no preloadError. A reload between loads changes what the negative assertion at :136 sees.
  - Run `REPEAT=10 bash /mnt/storage/dlesieur/scratch/c7-e2e/run-x.sh c75 chromium,firefox,webkit <counting copy under probes-fal> <tree> test`. The counting copy logs `vite:preloadError`; it is a scratch copy, never a repo edit. `--mode test` is acceptable because its assertions read storage and stub POSTs, not auth.
  - Bar: N ≥ 10 clean per engine, 0 failures in clean runs. BLOCK otherwise.
- **O4. BR7j(i), the BR7b push probe with the live flags.**
  - Run `PW_CONFIG=/cfg/pw-sw-block.config.ts REPEAT=12 bash run-x.sh br7j chromium,firefox,webkit tests/e2e/bridge-stub/probe/push.spec.mjs <tree> prod`. The `prod` argument selects `entry-prod-cfg.sh` (`VITE_REQUIRE_BRIDGE_SESSION=true`, `VITE_ALLOW_OFFLINE_MODE=false`, `NODE_ENV=production`).
  - The existing 12/12 on 891d7fc52 was a `--mode test` build (`out-p-fa/build.log`).
  - Bar: ≥ 10 clean runs per engine (0 preloadError, 0 aborted, 1 navigation), each with a matching POST.
  - BLOCK in any of these cases:
    - a Chromium control run with 0 matching POSTs (the probe is vacuous);
    - after a miss, the parent arm (main 0333d7966's tree, same flags) shows more pushing runs than the candidate;
    - both arms show 0 on an engine.
- **O5. Build M after a fresh `ls-remote`.** Re-check BR13a and BR13b; any new main commit is ruled first. Then check `git diff origin/develop M` is empty and `git rev-parse M^{tree}` = the hash above.
  - BLOCK: a tree mismatch (re-run O1–O4 on M), or develop past 891d7fc52 (a new unit, re-ruled).
- **O6. BR14 and C7.7 on M.** All three must hold:
  - `git merge-base --is-ancestor 891d7fc52 M` returns rc 0;
  - the C7.7 `git diff --stat fc0d7b408 M` prints exactly the 2-file line above;
  - `git ls-tree -r --name-only M -- src/store/page-cache` is empty.
  - Any other output fires J-C7/RC9 again (N ≥ 20), and LL8 too for page-cache.
- **O7. CI green on M's exact sha**, `test-bridge-stub` included. Main then fast-forwards to M with no `--force` (BR13c). That push publishes a `node-pages` release, which cannot be undone (BR13d).
- **O8. Deploy M.** Re-verify the target and run BR12 (the served index chunk equals the local build of M).
  - Rollback is forward only (K7 (A)): a new build of a commit that contains 1edca24b9 and F-A. Never below 1edca24b9, never a pre-P1 image once P1 is live.
  - The image tagged before the switch is the F-A image, which is pre-P1. Once M has served any request, that image is forensic only and is labelled "not a rollback target".
- **O9. The dated lift note in this ADR** records O1–O8 and states to the user the residuals they accept:
  - R1–R6, R8, R9 and N2′; R10 (a)–(d) and F-C6;
  - N1b/N1c are closed only for an origin with ≥ 20 characters of legacy text; R-C7a and R-C7b remain;
  - no queue before readiness; no journal or pagehide push over the 1,000,000-character cap;
  - a budget-abandoned or pre-P1 tab can overwrite the marker;
  - the migration is one way, including `migrated:<tabId>`;
  - the journal is unmeasured on WebKit (J-C7 ran on Chromium and Firefox only);
  - the numbers are docker-driven, about ±15 % at N = 20;
  - R11 is closed by F-A.
  - The note never says "no data loss".
