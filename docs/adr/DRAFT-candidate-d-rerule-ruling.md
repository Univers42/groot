# DRAFT. Candidate D is re-cut as D′ with the TD18 writers env-gated; FF-12 and RP11 are re-specified

- Status: proposed (draft, unnumbered). devil 2026-11-22: D = 9af6d241d BLOCK; D′ = D + gate commits PwC RD1–RD22. Amends ADR 0067 RP9, RP10, RP11, RP13 and RP17.
- Date: 2026-11-22
- Full ruling: `/mnt/storage/dlesieur/scratch/me-d/RULING-D-rerule.md`

## Context

- D ships the TD18 writers with no flag:
  - CanvasInspector.tsx:108 → CellRegionControls → `setCellRegion` (canvasReducer.ts:80);
  - the Templates rail item (railItems.ts:93);
  - `template.apply` → pageStore.actions.ts:797 → `createFromCatalogue`.
- TD18 requires readers live for one promotion before writers go live. Old tabs drop `region`/`stackAt`/`sticky` silently (TD ruling §5).
- `isLayoutModesEnabled()` is overridable through localStorage and the URL (featureFlags.ts:260-261). That is the U4 hole. `isEnvOnlyFlagEnabled` already exists (featureFlags.ts:58).
- FF-12 never ran a parse in S1/S2 (`writers equal: true`, inSync=1 at every step). Its S3 compared whole content after a step that adds a paragraph by design, so it could never pass. On the code block content, D/D keeps the fixture, while old engines 674dd65 and e5253d2 drop the `[x]:` line.
- RP11's LP20–LP22 method compares HEAD against HEAD (pid-keyed bench cache, LP20). The ADR 0068 D4 harness does not have that flaw.

## Decision

- Cut D′ from develop.
- Make `osio.layout.modes` env-only when `MODE === "production"`. Use MODE, not PROD, because the e2e harness builds `--mode test`.
- Gate the region reducer case and the catalogue branch of `createPageFromTemplate` at the root, and hide their UI.
- FF-12 becomes writer equality with a mutant, plus a code-block reader oracle with old-engine positive controls.
- RP11 runs on the D4 harness with a mutant that must FAIL.
- PR14 is ported to the FF158 BiDi harness. PR15 is measured on FF158 only.
- RP13 ABBA runs against a scratch T worktree.
- Units with no risk trigger clear by gate: issue, test, ancestor, and RP15 green.

## Alternatives considered

- **TD18 re-rule (writers live with their reader):** rests on "0 stale foreign T tabs", which is UNKNOWN, and RP23 covers only the user's tabs. The cost is silent shell loss on other users' pages, against roughly 30 lines of gating. See `.out-of-scope/region-writers-live-with-their-reader.md`.
- **Re-cut D without the TD writers (revert):** reverts many develop commits, then they get re-applied. Churn, and a second RP17 for the same code.
- **Waive RP11, PR14 or ABBA:** RP11 also carries the engine-pin (#321) evidence. PR14 covers the user's own browser, against a reload mechanism. ABBA is the only boot-regression gate (PS22).

## Consequences

- RD1–RD4: FF-12 re-spec, a T-reader decode of the D′-written new keys, and an issue for the live S3 loss.
- RD5–RD10: env-only flag (MODE-keyed), root gates, hidden UI, writer census, a flag-off round-trip test, and a bundle scan with the D build as positive control.
- RD11–RD13: clearance by gate for #339, #341, #310, #315, page fonts (old reader falls back at T pageConfigStore.ts:175) and #321.
- RD14–RD19: D4 RP11 (worst ≤ +3%, |cal| ≤ 1%, mutant FAIL), FF158 PR14 (S1 ×20, b8000 ×20, base N=5 with preloadError observed), FF158 bfcache ≥ 11/12, ABBA ≤ +5% with 0 Monaco first-nav chunks, and a static graph with no catalogue.
- RD20–RD22: D′ = D + gate commits only; full re-run on D′; RP18, RP23 and bridge-later unchanged.
- The region and catalogue writers reach live in the later layout-modes promotion.
- Residual: a hand edit of `osilayout` JSON in raw mode or the IDE can still write `region` on live.
