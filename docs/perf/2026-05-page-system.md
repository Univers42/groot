# Page System Performance Report - 2026-05

## Run Summary

Final run command: headless Chromium through Playwright, Vite at `http://127.0.0.1:3016/`, viewport `1440x1000`, default `globalThis.__perfRun()`.

Final run scenarios: `100`, `500`, `1000`, `2000`, and `4000` blocks, `200` synthetic keystrokes per scenario, with the default memory wait window.

Baseline note: the full exported Prompt 1 CSV was not preserved. The baseline row below is reconstructed from the recovered Prompt 1 warning artifact plus the preserved summary values. Unknown fields are intentionally left blank. Source artifact: `/home/dlesieur/.config/Code/User/workspaceStorage/658ac25b933ec7aef99b22ac454ac1fe/GitHub.copilot-chat/chat-session-resources/811d9633-dff6-4dd8-b050-5aa78fe660d2/call_UDpBP9C9cjmVbh4W3EkTuncK__vscode-1778584080391/content.txt`.

Recovered baseline values used:

- First paint: `695.20ms`.
- Keystroke samples: `696.9`, `782.8`, `699.2`, `788.1`, `744.9`, `784.0`, `682.5`, `783.3`, `666.4`, `782.8`.
- Preserved summary p50: `744.90ms`.
- Preserved summary p95 and p99: `788.10ms`.
- Store hot-path warning max: `6.50ms` from `updateBlock` warnings.
- Cache warning max: `5.30ms` from `savePagesCache` warnings.
- Preserved summary React commit total: `1915.20ms`.
- Preserved summary sidebar renders per keystroke: `2.000`.

## Baseline CSV

```csv
blockCount,pageId,firstPaintMs,keystrokes,keystrokeP50Ms,keystrokeP95Ms,keystrokeP99Ms,eventTimingP50Ms,eventTimingP95Ms,eventTimingP99Ms,updatePageContentMs,savePagesCacheMs,keystrokeSyncWorkMs,inlineMarkdownRenderCalls,inlineMarkdownRendersPerKeystroke,inlineMarkdownRenderMs,reactCommitCount,reactCommitsPerKeystroke,reactCommitTotalMs,reactCommitMaxMs,memoryUsedJSHeapSize,memoryGrowthBytes,sidebarRenders,sidebarRendersPerKeystroke,eventCountsDelta
2000,prompt-1-recovered,695.20,10,744.90,788.10,788.10,,,,,5.30,6.50,,,,,,1915.20,,,,20,2.000,
```

## Post-Refactor CSV

```csv
blockCount,pageId,firstPaintMs,keystrokes,keystrokeP50Ms,keystrokeP95Ms,keystrokeP99Ms,eventTimingP50Ms,eventTimingP95Ms,eventTimingP99Ms,updatePageContentMs,savePagesCacheMs,keystrokeSyncWorkMs,inlineMarkdownRenderCalls,inlineMarkdownRendersPerKeystroke,inlineMarkdownRenderMs,reactCommitCount,reactCommitsPerKeystroke,reactCommitTotalMs,reactCommitMaxMs,memoryUsedJSHeapSize,memoryGrowthBytes,sidebarRenders,sidebarRendersPerKeystroke,eventCountsDelta
100,perf-page-100,83.20,200,15.70,15.90,16.53,,,,0.10,0.00,0.00,0,0.000,0.00,215,1.075,912.50,21.70,56800000,0,0,0.000,
500,perf-page-500,79.60,200,15.80,15.90,19.10,,,,0.10,0.00,0.00,0,0.000,0.00,215,1.075,1021.90,36.30,56800000,0,0,0.000,
1000,perf-page-1000,101.60,200,15.80,16.00,18.96,,,,0.10,0.00,0.00,0,0.000,0.00,213,1.065,1050.10,54.70,56800000,0,0,0.000,
2000,perf-page-2000,76.60,200,15.70,15.90,21.10,,,,0.00,0.00,0.00,0,0.000,0.00,211,1.055,1131.80,33.40,47400000,-9400000,0,0.000,
4000,perf-page-4000,81.90,200,8.20,16.96,20.56,,,,0.10,0.00,0.00,0,0.000,0.00,219,1.095,1461.70,34.50,47400000,0,0,0.000,
```

## Row-By-Row Diff

Only the `2000` block Prompt 1 baseline row was recoverable. Other post-refactor rows are included as final coverage rows, but they have no Prompt 1 baseline row to compare against.

| block count | first paint diff | p50 diff | p95 diff | p99 diff | hot sync/cache diff | sidebar diff | responsible fix |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 100 | N/A | N/A | N/A | N/A | N/A | N/A | Covered by final harness; no Prompt 1 baseline row captured. |
| 500 | N/A | N/A | N/A | N/A | N/A | N/A | Covered by final harness; no Prompt 1 baseline row captured. |
| 1000 | N/A | N/A | N/A | N/A | N/A | N/A | Covered by final harness; no Prompt 1 baseline row captured. |
| 2000 | `695.20ms -> 76.60ms`, `89.0%` faster | `744.90ms -> 15.70ms`, `97.9%` faster | `788.10ms -> 15.90ms`, `98.0%` faster | `788.10ms -> 21.10ms`, `97.3%` faster | cache warning `5.30ms -> 0.00ms`; sync warning `6.50ms -> 0.00ms` | `2.000/key -> 0.000/key`, `100.0%` lower | Root block virtualization, per-block draft store, cache debounce/idle flush, selector stability audit, page index/revision state. |
| 4000 | N/A for Prompt 1 | N/A for Prompt 1 | N/A for Prompt 1 | N/A for Prompt 1 | N/A | N/A | Covered by final harness; no Prompt 1 baseline row captured. |

Additional virtualization ablation reference: with virtualization disabled, earlier 4000-block first paint was about `502ms` and p50 keystroke paint was about `218ms`. The final 4000-block row is `81.90ms` first paint and `8.20ms` p50, which is about `83.7%` faster for first paint and `96.2%` faster for p50 against that ablation reference.

## Acceptance Criteria

| criterion | result | status |
| --- | ---: | --- |
| 2000-block first paint `<120ms` | `76.60ms` | PASS |
| 2000-block keystroke p50 `<16ms` | `15.70ms` | PASS |
| 2000-block keystroke p95 `<33ms` | `15.90ms` | PASS |
| 2000-block keystroke p99 recorded | `21.10ms` | PASS |
| 2000-block sync work `<1ms` | `0.00ms` | PASS |
| 2000-block React commits per keystroke `<=5` | `1.055` | PASS |
| 2000-block memory growth `<20MB` | `-9.40MB` | PASS |
| 2000-block sidebar re-renders `0` | `0` | PASS |
| 4000-block first paint `<120ms` | `81.90ms` | PASS |
| Page-store actions no more than `1` per 250ms typing window | supplementary editor benchmark: max `1` action per 250ms, `1` total page-store action over `200` keystrokes | PASS |
| Root-only virtualization | implemented for root block lists only | PASS |
| Virtualization threshold `60` | `ROOT_BLOCK_VIRTUALIZATION_THRESHOLD = 60` | PASS |
| Virtualization overscan `12` | `ROOT_BLOCK_VIRTUALIZATION_OVERSCAN = 12` | PASS |
| Virtualizer uses `measureElement` | editable and read-only root virtualizers measure rendered rows | PASS |
| Keyboard boundary focus regression | focused browser scenario passed: `Virtualized boundaries`, `1 passed` | PASS |

All acceptance criteria are PASS.

## Things We Did NOT Do

- Did not virtualize nested child blocks. Root-only virtualization was the requested scope and keeps nested editing, drag/drop, and accessibility semantics simpler.
- Did not replace the contenteditable/editor architecture. The measured bottleneck was the typing-to-store/render path, so the lower-risk fix was draft isolation plus structural flush points.
- Did not workerize Markdown parsing or rendering. Final inline Markdown render calls are `0` in the typing harness, so workerization would not address the measured hot path.
- Did not add server-side pagination or backend paging. The tested bottlenecks were local render/store/cache behavior inside the editor and renderer.
- Did not claim a complete original baseline CSV. The full Prompt 1 export was not captured; this report reconstructs only known baseline columns and leaves unknowns blank.

## Regression Watch List

Future contributors must re-run `__perfRun()` before touching these call sites:

1. `apps/osionos/app/src/features/block-editor/model/usePlaygroundBlockEditor.ts`: `handleBlockChange`, `flushPendingDrafts`, `flushPendingBlockDraft`, and the draft committer path.
2. `apps/osionos/app/src/features/block-editor/model/blockDraftStore.ts`: `setBlockDraft`, `commitBlockDraft`, `flushBlockDraft`, `flushAllBlockDraftsForSource`, and `useBlockDraftContent`.
3. `apps/osionos/app/src/store/usePageStore.ts` and `apps/osionos/app/src/store/pageStore.helpers.ts`: `updatePageContent`, `updateBlock`, `patchPage`, `derivePageState`, and page index/revision maintenance.
4. `apps/osionos/app/src/store/pageStore.helpers.ts`: `schedulePagesCachePersist` and `flushScheduledPagesCachePersist`; cache writes must stay out of the keystroke burst.
5. `apps/osionos/app/src/features/block-editor/ui/BlockEditorSurface.tsx`, `apps/osionos/app/src/widgets/page-renderer/ui/PageBlocksRenderer.tsx`, and `apps/osionos/app/src/entities/block/model/blockVirtualization.ts`: virtualizer threshold, overscan, `estimateBlockHeight`, `measureElement`, and root-only rendering behavior.