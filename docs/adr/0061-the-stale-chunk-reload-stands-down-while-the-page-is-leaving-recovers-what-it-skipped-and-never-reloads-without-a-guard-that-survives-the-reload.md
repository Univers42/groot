# 0061. The stale-chunk reload stands down while the page is leaving, recovers what it skipped, and never reloads without a guard that survives the reload

- Status: accepted. PROCEED-WITH-CONDITIONS PR1 to PR9 for the R-BR5 fix (ADR 0057 BR7f). The unit queues behind P1's merge M (PR8).
  - Phase 2 re-rule, 2026-11-18 (end of this file): PROCEED-WITH-CONDITIONS. Develop needs PR10 to PR12; live needs PR13 to PR16. PR3's boot-only fallback is withdrawn.
- Date: 2026-11-18
- Deciders: devil (ruling); builder (osionos `fix/preload-reload-navigation`); coordinator (landing, PR8)

## Context

- **The defect.** `src/app/main.tsx:49-56` on 891d7fc52 reloads on every `vite:preloadError`. Firefox and WebKit fire that event for each lazy import that a starting navigation cancels, and the reload then aborts the navigation (ADR 0057 BR7f). The spec is osionos `docs/superpowers/specs/2026-11-18-preload-error-reload-navigation-design.md` (S1–S4, U1).
- **RED** on dc8a91b23 (base 891d7fc52, not pushed); logs in `/mnt/storage/dlesieur/scratch/rbr5/out-red/` and `unit-red.log`.
  - `preloadErrorReload.spec.mjs`: Firefox 6 failed / 9 passed; WebKit 4 failed / 11 passed; Chromium 15 passed. S1 is vacuous on Chromium: 0 events.
  - `preload-recovery.test.ts` is RED because its module does not exist yet.
- **The discriminator**, measured in `rbr5/disc.txt` (production build, service workers blocked, docker Playwright, localhost):
  - `beforeunload` precedes the first preloadError in all 75 interrupted runs, with a gap of 0–54 ms.
  - It comes first in 0 of the 150 should-reload runs: offline, redeploy, redeploy-html, stale-404 and stale-html200, on 3 engines × 10 each.
  - Probing the chunk URL instead gives 0/20 reloads for stale chunks on WebKit, because WebKit's payload carries no URL.
- **osionos already arms `beforeunload` only while edits are unconfirmed**, because "an armed page is kept out of the bfcache" (`src/store/sync/pendingPages.ts:132-157`). That guard asks "Leave page?", so a user can already click "Stay on page" today.
- **The current loop guard.** It reads `sessionStorage?.getItem` (`main.tsx:51`) and writes it before reloading (`:53`).
  - Storage null: the guard reads 0, never writes, and a chunk that stays missing reloads the page on every boot.
  - A getter or `setItem` that throws: the throw escapes the handler, which never reloads.
  - The worker-update reload (`main.tsx:79-84`, `appWorker.ts:60-61`) has the same null-storage guard.
- **KDS reaches the page only through a dynamic import** (`App.tsx:236`). If that import is cancelled and nothing reloads, the document stays without KDS.
- **Unknown when this was written:**
  - the gap with a slow server;
  - what happens after Stay, Stop, a download or a 204;
  - the bfcache cost on stock Firefox 158 and WebKit;
  - whether iOS Safari fires `beforeunload`;
  - a real redeploy (staleness is modelled with `page.route`).

## Decision

`src/app/preloadRecovery.ts` exports `installPreloadRecovery(target, { storage, now, reload })`, and `main.tsx` calls it once. A `beforeunload` seen first marks the document as leaving. A preloadError that arrives while it is leaving is swallowed, not answered with a reload. The mark does not last for the document's life.

- **PR1. The mark is bounded.**
  - It clears T after `beforeunload` (T = 10 s, the guard window, unless PR4 (b) needs more) and on `pageshow` with `persisted`.
  - When it clears, if a failure was swallowed and the document is still alive, the page reloads once under the guard.
  - A mark that lasts the document's life is BLOCKED. A navigation that never commits (Stop, a 204, a link that became a download) would leave its cancelled imports failed with nothing to recover them, KDS's included.
- **PR2. The guard survives the reload.**
  - The handler reloads only when the guard write reads back from `storage`, with both the get and the set inside a try/catch. Otherwise it never reloads.
  - U1 adds two tests: storage null gives 0 reloads across two simulated documents; storage that throws gives 0 reloads and no throw.
  - It lands in this unit, as its own commit.
- **PR3. The bfcache.**
  - Measure back-navigation `pageshow.persisted` on base 891d7fc52 and on the fix, N ≥ 10 per arm, on stock Firefox 158 (the RC9-F1 BiDi harness), WebKit and Chromium.
  - If the base is above 0 on an engine and the fix lowers it, the listener is armed only during boot, until the boot's lazy imports settle (as `createUnloadGuard` does), and S1 is re-run.
  - A base of 0 means the measurement is vacuous, and the boot-only form is then required.
- **PR4. Measure before landing.** Production build, workers blocked, Firefox 158 and WebKit with a Chromium control, N ≥ 20 per cell.
  - (a) Stay on page: arm `pendingPages` (an unconfirmed edit with its PATCH refused), navigate, dismiss the dialog. A stale chunk before T gives exactly 1 reload, at T. A stale chunk after T gives exactly 1 reload, at once.
  - (b) A document delayed by 3 s and by 8 s: the navigation completes in 20/20 runs with 0 reloads, and the largest beforeunload→preloadError gap is recorded and stays below T.
  - (c) One `anchor.download` export during boot (`runExport.ts:37`): record whether `beforeunload` fires. If it does, PR1 must hold: 1 reload if a failure was swallowed, otherwise 0.
- **PR5. S1–S4 and U1 pass on three engines.**
  - S1 (goto): ×20 per engine with 0 third documents. On Chromium it is labelled vacuous.
  - S2 and S3: ×10 each, exactly 1 reload.
  - Typecheck, lint and the full canvas suite pass, each cited by its own rc line. The RED commits stay before the fix.
- **PR6. S4 stays as today:** one reload when the host is unreachable. Changing that is its own unit, measured with the service worker on.
- **PR7. The module header carries a `Caveat:` naming four limits:**
  - (i) a `beforeunload` that does not unload delays recovery by up to T;
  - (ii) a navigation still pending at T whose imports were cancelled is aborted once;
  - (iii) where `beforeunload` does not fire (iOS Safari is reported not to; unmeasured) the behaviour is today's;
  - (iv) staleness is modelled, not a real redeploy.
- **PR8. Landing queues behind M.**
  - Nothing reaches osionos develop or main before main fast-forwards to M (ADR 0052 O7). A develop commit before that changes M's tree, and O1–O4 run again.
  - After that: rebase onto M, run its own CI, and go live under the standing go once PR1–PR7 hold.
- **PR9. What it unblocks.**
  - Nothing on P1's list: O2–O4 count preloadError runs and exclude them.
  - It removes the abort behind R-BR5's Firefox/WebKit blindness.
  - The `app.mjs:52` refusedDatabaseSave goto failure on Firefox/WebKit is not shown to come from R-BR5. It counts as unblocked only after a run on the fix shows it.

## Alternatives considered

- **Probe-fetch the chunk URL:** S2 fails on WebKit, where 0 of 632 preloadError payloads carry a URL (`rbr5/all.jsonl`, counted with `jq ... .hasUrl`). On Firefox, interrupted probes settled in only 4/20 goto runs and 7/20 assign runs (`disc.txt:6-7`).
- **Wait for `pagehide` or `visibilitychange`:** both arrive after the preloadError (`disc.txt`), by which time the reload has already aborted the navigation.
- **The Navigation API `navigate` event:** absent for browser-initiated navigations (measured).
- **Delay every reload by D ms:** this still aborts any navigation slower than D, whereas `beforeunload` is known at once.
- **A prompt instead of an automatic reload (UpdateButton):** it removes both failure directions at the cost of one click per stale tab. It lost because the spec keeps today's recovery, and the KDS import (`App.tsx:236`) has no button to retry it.
- **An in-memory guard:** the reload it guards resets it, so it never stops the loop (`.out-of-scope/in-memory-preload-reload-guard.md`).

## Consequences

- **Risk scores:**
  - blast radius 3: the entry module, on every load;
  - reversibility 2: a revert and an image;
  - cost on failure 2: no data path is touched; the outcomes are a bounced navigation, a lazy feature broken until refresh, or slower back navigation on Firefox;
  - confidence 3: localhost only, with PR3 and PR4 unmeasured.
  - The worst axis is confidence.
- **What remains of R-BR5:** navigations still pending at T, engines that do not fire `beforeunload`, and, under PR3's fallback, lazy imports outside the boot window.
- **Follow-up:** the worker-update reload (`main.tsx:79-84`) keeps the null-storage guard. Moving it onto PR2's guard is its own unit, under ADR 0053.
- **Owners:** the builder holds PR1–PR7; the coordinator holds PR8.

## Phase 2 re-rule, 2026-11-18: the built unit may land on develop; live waits for stock Firefox 158 and P1's lift note (devil)

**Verdict: PROCEED-WITH-CONDITIONS.**
- Develop needs PR10 to PR12. Live needs PR13 to PR16.
- PR1 to PR9 stand, except PR3's boot-only fallback, which this entry withdraws.
- Evidence paths are relative to `/mnt/storage/dlesieur/scratch/rbr5/` unless stated.

### Facts checked

- **The branch.**
  - `fix/preload-reload-navigation` is at 3d655d712 in `/mnt/storage/dlesieur/wt/osionos-rbr5`, porcelain 0, nothing pushed.
  - `git diff --shortstat 891d7fc52 HEAD` gives 5 files, +376 −12.
  - Seven commits. The RED ones (79adb954d, dc8a91b23, af828bfe4) come before the fixes: dfa831646 (PR2) and fee80e984 (PR1, PR7).
- **PR8's precondition holds.**
  - In the worktree's refs, `origin/main` and `origin/develop` are both 6de257335 (M′).
  - 891d7fc52 is an ancestor of M′.
  - M′ changes none of `main.tsx`, `pendingPages.ts` or `preloadErrorReload.spec.mjs` since 891d7fc52: `git diff --stat` on those paths prints nothing.
- **RED.**
  - e2e (`out-red/e2e-*.log`): Firefox 6 failed, WebKit 4 failed, Chromium 15 passed.
  - Unit: at dfa831646, tests 2 and 3 fail (`unit-pr2.log`). At HEAD, 11/11 pass (`unit-green.log`).
- **PR5 and the gates.**
  - e2e: 100 passed per engine (`out-pr5/e2e-*.log`).
  - On 3d655d712, lint, typecheck and canvas each give rc=0. Canvas passes 5711 and fails 0 (`final/gates.rc`, `final/canvas.log`).
- **An undeclared deviation.**
  - PR4 and PR5 ran in `mcr.microsoft.com/playwright:v1.59.1-noble` (`run.sh:9`), with Playwright's patched Firefox, not stock Firefox 158.
  - Only PR3 used stock 158 (`bfcache.mjs`, puppeteer-core over BiDi).

### Q1. PR3: the permanent listener stays

- **Stock Firefox 158.** Base 12/12 restored, fix 12/12 restored (`out-pr3/bfcache-firefox-*.jsonl`). Where bfcache can be measured, the listener does not lower it. PR3 holds on Firefox.
- **WebKit and Chromium.** Both arms restored 0/12.
  - On Chromium, the arms with `--disable-back-forward-cache` dropped (`bfcache.mjs:18`) also restored 0/12.
  - No control shows that the harness can restore any page, so the measurement is vacuous.
- **PR3's letter asks for the boot-only form here. This entry withdraws that fallback**, because its cost is now measured and its gain is not:
  - `src/` has 64 dynamic-import sites (`lazy(() => import(` or `await import(`) in 28 files. Many of them load after boot: `sectionPanels.tsx`, `DashboardView.tsx`, `ChartView.tsx`, `NotionPage.tsx`. A boot-only listener leaves every one of them with today's abort on Firefox and WebKit.
  - A fix cannot lower a base of 0. On today's app, in this harness, the listener costs nothing measurable on WebKit or Chromium.
- **What would change the answer:** a harness that restores the base app on WebKit or Chromium, with the fix restoring fewer. PR3's original rule then applies on that engine (PR15).
- **Side finding.** The comment at `pendingPages.ts:131-157` says an armed page is kept out of the bfcache. No engine measured this. Fixing that comment is not this unit's job.

### Q2. PR4(a): the model listener is accepted

- **The model matches the real guard.**
  - The model (`zz-pr4.spec.mjs:22-27`) has the same shape as `createUnloadGuard` (`pendingPages.ts:131-157`): non-capture, `preventDefault()`, `returnValue = ""`.
  - Nothing in `src/app` or `src/store/sync` stops propagation (0 matches).
  - The fix's listener is capture (`preloadRecovery.ts:68-72`), so the guard cannot hide `beforeunload` from it.
- **Results, 20 per cell:**
  - a1: 1 reload, at this many ms after the first `beforeunload`: Firefox 10 024–10 042, WebKit 10 005–10 017, Chromium 10 002–10 004.
  - a2: 1 reload, at this many ms after the late failure: Firefox 26–45, WebKit 5–17, Chromium 4–12 (`pr4-table.tsv`).
- **New finding: every a-row shows 2 dialogs (120/120).**
  - The spec dismisses the first dialog and accepts the second (`zz-pr4.spec.mjs:57`).
  - While the edit is unconfirmed, the deferred reload at T shows the leave dialog again. A user who clicked Stay gets a second dialog 10 s later, without doing anything.
  - The base shows the same dialog, but at the moment of the failure, not 10 s after a Stay.
  - PR11 puts this in the Caveat.
- **Residual.** The real PATCH-refused arming was not driven. The dialog depends only on the listener.

### Q3. PR4(b): T stays at 10 s

- **The measured gap is well inside T.**
  - `gapMs` is the time from `beforeunload` to the preloadError (`zz-pr4.spec.mjs:83-84`).
  - Firefox: max 149 ms with the 3 s delay, 194 ms with the 8 s delay.
  - WebKit: max 1971 ms and 1972 ms.
  - The gap is flat across the two delays, so it does not grow with the document's delay. The margin to T is at least 8 s.
- **T has a second bound:** the navigation must commit before T, or Caveat (ii) aborts it.
  - b8000 passed 20/20 with 0 reloads on Firefox and WebKit.
  - The rows record when the second document was requested (`zz-pr4.spec.mjs:16`), not when it committed. The 8 s hold rests on `zz-pr4.spec.mjs:78`, not on a recorded time.
  - PR14 records the commit time.
- **Chromium:** 0 preloadError events in all 40 b-rows (`gapMs` null). This is vacuous, as in S1.
- **Why T does not change.** A shorter T widens Caveat (ii). A longer T widens Caveat (i) and the second dialog.

### Q4. PR4(c): the synthetic anchor is accepted

- The probe uses the same mechanism as `downloadBlob` (`runExport.ts:32-42`): an object URL, an anchor with `download`, a click, then removal.
- c-ok: `beforeunload` fired in 0/20 runs on each engine, with 0 reloads and the download seen 20/20.
- c-stale: 1 reload. The only `beforeunload` is the reload's own.
- So the "if it does" clause of PR4(c) never triggers.

### Q5. Landing

**Before osionos develop:**

- **PR10. Rebase, not merge, onto develop's tip at landing time.**
  - That tip is 6de257335 today. If ADR 0063's H lands first (the coordinator's order), it is the commit that carries H.
  - `git diff --stat <tip> HEAD` must list the same 5 files: +376 −12 plus PR11's lines.
  - The 7 commits keep their order.
  - If the tip changed any of the 5 files, stop and re-submit.
- **PR11. Caveat (i) names the second dialog**, in `preloadRecovery.ts` and in the spec.
  - The wording: with an unconfirmed edit, the reload at T shows the leave dialog again, and a second Stay leaves the failed lazy feature broken until a refresh.
  - Evidence: 120/120 a-rows show 2 dialogs.
- **PR12. Gates on the rebased sha, each with its own rc line.**
  - Typecheck, lint, the full canvas suite, and `preload-recovery.test.ts` at 11/11.
  - S1–S4 on a production build of that sha, on 3 engines: S1 ×20, S2 and S3 ×10 each. This re-run is needed because the base is now P1's boot.
  - Its own CI green on the exact sha, `test-bridge-stub` included.
  - Develop takes it by fast-forward. Rollback is a revert commit.

**Before live (osionos main and the deploy):**

- **PR13. P1 is settled first.**
  - O8 is done and O9's lift note is written (ADR 0052).
  - R-BR5 then gets its own main fast-forward and its own deploy, never inside P1's image switch.
  - The main push publishes node-pages (BR13d) and cannot be undone. It needs the human go at that moment.
  - This entry is the ruling that 0052 Q5 requires for a commit past M′.
- **PR14. Stock Firefox 158** (the RC9-F1 BiDi harness), on the rebased production build:
  - S1 ×20 on the base and on the fix. The fix must give 0 third documents. If the base gives 0 aborts, S1 is labelled vacuous on stock 158 and that fact is recorded.
  - b8000 ×20 on the fix, with the second document's commit time recorded. Pass: 0 reloads, and a commit at least 8 s after `beforeunload` and before T.
- **PR15. bfcache controls on WebKit and Chromium** (Chromium without `--disable-back-forward-cache`).
  - Run a static page with no listener, and the same page with a no-op capture `beforeunload` listener, N ≥ 10 each.
  - On Chromium, also log `notRestoredReasons` for the base app.
  - The result sets a Caveat (v):
    - The static page restores 0/N: the harness cannot see bfcache on that engine, and the Caveat says "unmeasured".
    - The static page restores but the listener page does not: the listener costs bfcache on that engine. Record it. Arming the listener only while an import is pending becomes a follow-up unit.
    - The base app restores > 0 on any engine: PR3's original rule applies before live.
- **PR16. Deploy as O8 did.**
  - Re-verify the target. Run BR12: the served index chunk equals the local build of the deployed sha. Update the groot pin.
  - Rollback is the image that was live just before, which is post-P1. Never a pre-P1 image (O8, K7).

### Accepted without a new condition

- **Unit test `:87`** passed at dfa831646, before the mark existed. By inspection, it still guards the `pageshow` branch: if that branch is removed, its first assert (`reloads() === 1` right after `restore()`) gets 0.
- **PR2** is its own commit (dfa831646).
- **PR6:** S4 passes unchanged, inside PR5's 100/100.

### Risk scores

- **Develop:** blast radius 3 (the entry module, on every load), reversibility 1 (a revert; develop publishes nothing), cost on failure 2, confidence 2. The worst axis is blast radius.
- **Live:** blast radius 3, reversibility 3 (the node-pages publish), cost on failure 2, confidence 3. Confidence is low because stock Firefox 158 S1 and WebKit/Chromium bfcache are unmeasured, and no real redeploy was tried. The worst axes are reversibility and confidence.

### Not verified (UNKNOWN or SKIP)

- **WebKit and Chromium bfcache:** vacuous (PR15).
- **Stock Firefox 158 for S1–S4 and PR4:** not run (PR14).
- **Chromium S1 and b:** 0 events, vacuous by design.
- **The b8000 commit time:** not recorded (PR14).
- **iOS Safari `beforeunload`:** Caveat (iii), unmeasured.
- **A real redeploy:** Caveat (iv); only modelled.
- **The bfcache claim in the `pendingPages.ts` comment:** unmeasured.
- **PR9's `app.mjs:52` goto failure on Firefox and WebKit:** not re-run on the fix, so it does not count as unblocked.
- **O7's push time (11:54Z):** this is the coordinator's report. The refs show the sha, not the time.
- **Q7b's numbers:** read from `p1-cand/q7b/RESULT.md`, not re-tallied.
