# 0066. The boot views render without a Suspense reveal only once the loader re-reads the chunk after commit and every failure reaches render

- Status: accepted.
  - osionos `perf/boot-suspense` 0b01df4bf as committed: **BLOCKED** (BS-F1, proved).
  - The same change, with BS1 to BS9: **PROCEED-WITH-CONDITIONS for develop**.
  - Live: only with the next develop→main promotion, which needs the user's go and BS10 to BS12.
- Date: 2026-11-19
- Deciders: devil (ruling); osionos main session / builder (lives with it)

## Context

Facts were read on osionos 0b01df4bf (parent 0f0649901, react/react-dom 19.2.5, vite 6.4.2). The app source was read only. The probes ran on a copy of the loader in Playwright 1.59.1 (Chromium, Firefox, WebKit). Artifacts are in `/mnt/storage/dlesieur/scratch/integ/perf/bootfix-race/`: `run.cjs`, `entry.tsx`, `probe1-400ms.txt` and `probe2.txt`.

- **Scores** (1 to 5): blast 4, reversibility 2, cost on failure 3, confidence 3. Blast is the worst.
  - The loader sits on the workbench, on every page tab (`LazyOsionosPage`, used at `HomeTabView.tsx:92` and `PaneContent.tsx:70`) and on the explorer. That covers every user and every browser.
  - Reverting is one commit. No data or format is involved, and chunk names do not change.
- **The cause is real.** react-dom-client.production.js:11858 holds a reveal while `300 > now() - globalMostRecentFallbackTime`. Probe 2 shows it from outside: every `React.lazy` trial still shows its fallback 200 ms after the chunk settled, in all three browsers. The value is real too: live boots in about 875 ms, and the fix measures 211 ms cold (ABBA ×5, `perf/bootfix/`).
- **BS-F1, proved: the view can stay on its placeholder for good.**
  - Render reads the module-level `chunk.loaded` and returns the fallback.
  - The effect then returns early when `chunk.loaded || chunk.failure` is already set (`lazyWithoutSuspense.tsx`, first line of the effect).
  - React runs passive effects in a later scheduler task (`scheduleCallback$1(NormalPriority$1, …)`, react-dom-client.production.js:11497). A chunk that settles in that gap is never re-rendered.
  - `WorkbenchImpl.preload()` runs at module load (`lazyAppRegions.tsx:58`), and the editor warm now starts while the views mount. That makes the gap the normal case, not a corner case.
  - Placeholder still showing after the chunk settled:

    | Run | Browser | 0b01df4bf | Effect always subscribes | `React.lazy` |
    |---|---|---|---|---|
    | probe 1 (400 ms window, 20 per cell) | Chromium | 70/160 | (not run) | 0/160 |
    | probe 1 (400 ms window, 20 per cell) | Firefox | 123/160 | (not run) | 0/120 |
    | probe 2 (200 ms window, 10 per cell) | Chromium | 50/80 | 0/80 | throttled |
    | probe 2 (200 ms window, 10 per cell) | Firefox | 62/80 | 0/80 | throttled |
    | probe 2 (200 ms window, 10 per cell) | WebKit | 20/80 | 0/80 | throttled |

  - When the chunk settles inside the commit ("layout" mode), the view sticks in 10/10 and 20/20 trials in every browser. That case is deterministic and can serve as a regression test.
  - In the app, the view recovers only when its parent happens to re-render. That probably explains why e2e is green. No caller memoises, but nothing guarantees a re-render either.
- **BS-F2, proved for failures as well.** A rejected chunk that settles in the same gap never reaches the error boundary: "fail" rows, the same counts as above.
  - The reload path does not depend on render: `preloadRecovery.ts:79` reloads on `vite:preloadError` and never calls `preventDefault`, so Vite rethrows.
  - When the guard declines (a second failure within 10 s, or no sessionStorage, `preloadRecovery.ts:47`), the user sees a spinner forever instead of an error.
  - No error boundary sits above `LazyWorkbench` (`App.tsx:382`). A thrown workbench chunk error unmounts the root, today and with this change alike.
- **BS-F3.** `chunkLoader`'s rejection handler is the second argument of the same `.then`. If the success handler throws, `failure` is never set and the view stays on its fallback while the promise rejects. Two inputs do that:
  - a module with no `default`;
  - a future `vite:preloadError` listener that calls `preventDefault`. Vite then resolves `undefined`, and that is the common Vite recipe.
- **What matches `React.lazy`.** A rejection is cached forever, so a boundary reset rethrows and recovery is a reload (ADR 0061). Neither loader retries.
  - Unmount before resolve: the `mounted` flag guards it.
  - StrictMode double mount: the second subscription shares the one promise. In production, StrictMode is a no-op (`main.tsx:89`).
- **Duplicates.** Two hand-written copies of "keep the loaded component so a later mount skips Suspense" already exist:
  - `panelLoaders.ts:41-53` (`ready`, `readyPanel`), which deletes failures so a retry is possible;
  - `lazyViews.tsx:116-132` (`readyLibraryView`).

  `chunkLoader` is the third copy.
- **Gate state.**
  - These ran on 0f0649901 plus a dirty tree, not on the commit (`bootfix-gates-run.log`: quality, canvas 5971/5971, bridge, engine tsc). The 30/30 e2e subset and the 5/5 preloadErrorReload run are separate logs.
  - The full functional e2e had reached test 124/1119 at 17:11 (`bootfix-e2e-full.log`). **UNKNOWN.**
- **The comment does not match the code.** The loader header names "the database block". The commit replaces the explorer, not a database block.
- **Mobile is UNKNOWN.** The editor warm moved from idle to "after the workbench shell loads" (`lazyAppRegions.tsx:84`). The removed comment says eager warming had measurably pushed mobile FCP back. No throttled run exists. The code carries a Caveat for this.
- **Overlaps.**
  - `feat/raw-console` touches none of the five files (`git diff --name-only` from its merge base).
  - The branch is 2 commits behind `origin/develop` 6e48e386a, also with no shared files.
  - `sw.js` and `main.tsx` are untouched, so no `?v=3` bump is needed.

## Decision

1. Keep rendering the fallback as plain output instead of suspending. That is the measured cause, and React offers no supported way to skip the reveal throttle.
2. After commit, the loader must check what render saw against the chunk's current state, and re-render if they differ. Its rule is "render, then subscribe", never "subscribe unless already settled".
3. Any rejection anywhere in the loading chain is a failure that render throws.

### Conditions

**Before develop (PwC)**

- BS1. Close BS-F1 and BS-F2. After commit the effect re-renders whenever the chunk state differs from what render saw. Three acceptable ways:
  - drop the early return (the probe 2 variant: 0/240 stuck in three browsers);
  - compare against a snapshot taken in render;
  - use `useSyncExternalStore`.

  The view must not re-render an extra time when it already rendered the loaded view, or the builder measures that re-render on the workbench and reports it.
- BS2. A regression test in a project runner fails on 0b01df4bf and passes on the fix.
  - It needs a real DOM with `react-dom/client`. A `renderToStaticMarkup` test cannot see effects.
  - It covers the "layout" settle (deterministic) and a `setTimeout(0)` settle, for both an ok chunk and a failed one, in Chromium, Firefox and WebKit.
  - `bootfix-race/run.cjs` shows the method (an esbuild bundle and `page.addScriptTag`).
- BS3. Close BS-F3. Failures are recorded on the chain after the success handler, and a `default` that is not a component counts as a failure. A test resolves `{}` and resolves `undefined`, and both reach the boundary.
- BS4. The loader header names the three views it actually wraps and the measured numbers of this commit.
- BS5. Library-first. Either fold `readyPanel` and `readyPageLibraryView` onto the loader's settled state in this unit, keeping their retry-after-failure, or link an issue for it in the commit body. Do not add a fourth copy.
- BS6. Rebase onto current `origin/develop`. Re-run all gates on the exact commit that lands, not on a dirty tree:
  - quality, canvas, bridge and engine tsc;
  - the e2e workbench subset and preloadErrorReload 5/5 (ADR 0061 PR-series behaviour unchanged).
- BS7. The full functional e2e (1119) finishes on that commit with 0 failures. Any failure is shown to be pre-existing by the same spec failing on the `origin/develop` parent in the same harness. A run that times out counts as not run.
- BS8. The ABBA boot spec is re-run on the fixed commit. Cold median stays at or below 300 ms. If BS1 adds a mount re-render, warm must not regress beyond noise.
- BS9. The develop push follows the direct-merge practice, with green CI on develop. No live step comes with it.

**Before live, as part of the promotion (PwC, plus the user's go)**

- BS10. A mobile A/B run, main against the fix, under Playwright CPU ×4 and Slow 4G (or Lighthouse mobile), with at least 5 runs per arm.
  - FCP and LCP must not get worse beyond noise.
  - If they do, the editor warm goes back to idle for mobile and this commit's desktop gain stays. The Caveat is updated with the number either way.
- BS11. A production-build boot probe in Chromium, Firefox and WebKit shows the workbench, the Home page and the explorer all rendered with no parent re-render forced. It also shows a 404 on each of those chunks reaching the reload path, or the root when the guard declines, never a permanent spinner.
- BS12. Promotion follows the open O-series checklist. Rollback is reverting this commit and redeploying the web image.

## Alternatives considered

- **Land 0b01df4bf now and fix later.** BS-F1 is proved in all three browsers. Whether the app recovers depends on an unrelated parent re-render, so this was declined.
- **Keep `React.lazy` and only prefetch earlier.** The throttle applies even to a loaded chunk, because `React.lazy` suspends once (react-dom 11858). Prefetching cannot remove the 300 ms window.
- **Use one Suspense boundary for all three views.** Any later fallback in the root, such as a panel or the Library, restarts the throttle for every other reveal. That moves the problem around instead of removing it.
- **Retry a rejected chunk inside the loader.** This would differ from `React.lazy`, and it would race ADR 0061's reload guard. Out of scope here; `readyPanel` keeps its own retry.

## Consequences

- Live keeps its 875 ms boots until the promotion. That is a cost, not a loss.
- BS1 to BS9 are the acceptance criteria for develop, and BS10 to BS12 for live. The commit as it stands stays BLOCKED, and a resubmission must show BS2 failing on it.
- Residual, unchanged by this ADR: no error boundary sits above `LazyWorkbench` (`App.tsx:382`), so a workbench chunk failure the reload guard declines unmounts the whole app. This predates the change and is a candidate for its own unit.
