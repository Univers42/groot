# 0061. The stale-chunk reload stands down while the page is leaving, recovers what it skipped, and never reloads without a guard that survives the reload

- Status: accepted. PROCEED-WITH-CONDITIONS PR1 to PR9 for the R-BR5 fix (ADR 0057 BR7f). The unit queues behind P1's merge M (PR8).
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
