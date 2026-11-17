# 0052. The KDS IndexedDB move still loses or risks the edits named here, and is not loss-free

- Status: accepted as a residual register. It does not lift any condition. Live promotion of osionos develop stays suspended until J-C7 ([ADR 0055](0055-the-kds-unload-journal-is-per-tab-keyed-by-every-base-it-may-land-on-and-never-regresses-an-acked-record.md)) and C7 ([ADR 0054](0054-the-kds-indexeddb-writer-reaches-develop-only-after-its-coverage-fixes-and-is-not-promoted-live-before-pagehide-survival-is-measured.md)) pass. R7 is fixed (J-C10, osionos `38c38cf36`), confirmed by the devil's re-rule of 2026-11-17 recorded in ADR 0055; osionos develop was fast-forwarded to `38c38cf36` on 2026-11-17. On 2026-11-17 the devil's re-rule on a00b62265 (ADR 0055) also blocks live promotion until F1 lands under F-C1 to F-C9 and the RC9 re-run (F-C7) passes; see R9. F1 (osionos `cc5145417..fc0d7b408`) closed R9 on develop; the devil's note of 2026-11-17 on fc0d7b408 (ADR 0055) lifts the RC9 live block once FL1 to FL3 hold.
- Date: 2026-11-17
- Deciders: devil (rulings in 0054 and 0055), osionos main session / builder (live with it)

## Context

Branch `feat/kds-idb-p1` (osionos worktree `/mnt/storage/dlesieur/wt/osionos-net-retry`) moves the known-database state (KDS) and its push record from localStorage into IndexedDB `osionos-kds`. This is the P1 design ADR that 0054 (C5) and 0055 (J-C9, J-C5 measurement half, re-rule section) require. Their names are used as written there: N1b, N1c, N2, N2′, R1 to R8, CAND, J-C*. This ADR adds none.

It states what P1 does not do, so that nobody claims it is loss-free. The sources are 0054, 0055, `.claude/agent-memory/benchmarker/i10-pagehide-idb-survival.md` and the J-C5 artifact below.

## Decision

P1 is recorded as below. Every residual is accepted, closed, or open with the condition that governs it. None is claimed to be zero.

### N1b, N1c, N2, the rejected candidate, the pre-readiness drop

- **N1b (accepted residual).** Every write is refused, even after the page caches are evicted, so the 15-character flag `osionos.kds.idb` cannot be stored. Both legacy keys are kept and no retirement is claimed (0054 re-ruling). A later load where IndexedDB fails runs the legacy localStorage path and pushes the old local copy over a newer server copy. That path runs today on every load of such an origin. Under P1 it runs only on loads where IndexedDB fails.
- **N1c (accepted residual, proved).** The flag is refused at migration. Session 1 commits. Session 2 runs on IndexedDB fallback, offline, and its storage writes succeed again, so its edit e2 goes to the legacy key. At session 3 the IndexedDB copy wins and the now-storable flag retires the legacy key that holds e2. Result: e2 is lost (`{"local":["x-1"],"server":["x-1"],"legacy":false}`). It needs N1b's precondition. ADR 0054 C7 measures it per browser profile: at least 64 characters free after eviction, with the quota 5,242,879 characters and non-Latin-1 counted as 2.
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
- It does not close N1b or N1c. ADR 0054 C7 measures their precondition on each browser profile before live.
- It does not queue edits made before readiness.
- It does not journal over the cap, and it does not push at pagehide over the cap.
- It does not carry a `removed` field (`.out-of-scope/kds-journal-removed-databases-field.md`) and does not ship J3, the eager commit (`.out-of-scope/eager-kds-commit-debounce.md`).
- It has not been run end to end in a real browser build (J-C7).

## Consequences

- Live promotion of osionos develop stays suspended in writing until J-C7 (real app build, Chromium 147 and stock Firefox 158, N≥20 per cell, last edit on the server after reload, 0 reverts) and ADR 0054 C7 (at least 64 characters free per profile) pass. Merging to develop is allowed only with that suspension.
- F1 met F-C1 to F-C8 on fc0d7b408 (ADR 0055, note on fc0d7b408); this block is F-C9. The RC9 live block lifts with FL1 to FL3. J-C7's required cells passed in RC9 and again in RC9-F1.
- No document, release note or status line may say "no data loss" or "0 at risk" for this move. The residuals above are the accurate statement.
- Removing the journal later restores today's N2 and does not touch the stored copy.
- Caveat for the numbers: I10 and the journal harness are docker-driven (Playwright, stock Firefox over WebDriver BiDi), not a user's Ctrl+W, and N=20 bounds a rate only to about ±15 %.
- Closed 2026-11-17: the devil's ruling on `38c38cf36` (R7) is recorded in ADR 0055 and reflected above.
