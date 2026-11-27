# DRAFT: #345 and drag motion land on osionos develop by rebase onto the live head, never by force

- Status: draft, untracked. Ruled by devil 2026-11-27: the plan as worded is BLOCKED. The rebased
  plan is PROCEED-WITH-CONDITIONS under D1–D9, and main must meet M1–M7.
- Date: 2026-11-27
- Deciders: devil (ruling). The owner runs the rebase and the pushes.
- Full ruling: `/mnt/storage/dlesieur/scratch/promo-5/RULING-develop-345-drag.md`.

## Context

- **The chain.** fix/theme-k1k2 6b595acbf (#345) sits on d736d3194, and feat/drag-motion-preview
  21fea21b3 sits on 6b595acbf. Neither branch has been pushed, so CI has never run on them.
- **No fast-forward.** origin/develop is f0c7a2402 (`git ls-remote` at 22:41:58Z). It contains
  feat/motion-easing d8d4e22b2 and feat/appearance-summary. `merge-base --is-ancestor` gives rc=1.
- **Conflicts.** 21fea21b3 onto f0c7a2402 conflicts in 11 files, including `index.html:58` and the
  nginx CSP hash.
- **Two K1 fixes.**
  - Develop uses `!important` dur-* (`origin/develop:src/app/styles/motion.css:12`).
  - #345 uses `--osio-motion-scale` with themeDoc `calc()` (`themeDoc.ts:180`,
    `bridge-theme-rules.mjs:57`).
  - Unioned, the #345 ratio test matches 0 durations and passes vacuously.
- **Semantic conflict.** `appearanceSummaryModel.ts` on develop has no `dragMotion`, so
  `appearance-summary.test.ts:20` goes red after integration even though the file merges cleanly.
- **CSP.** `script-src` is Report-Only (`nginx.conf:1-2,44`), so a hash mismatch cannot break first
  paint.
- **e2e coverage.** The drag e2e uses synthetic DragEvents (`tabDragMotion.spec.mjs:40,48,56`).
- **Reduced motion.** A hover preview of Motion "full" or Animated images "play"
  (`AccessibilitySettings.tsx:51,60`) lifts the reduced-motion guard (`global.css:914-925`).

## Decision

- Rebase both commits onto the live develop. Push #345 first and wait for green, then fast-forward
  to the drag commit.
- Keep exactly one K1 mechanism. The lean is develop's `!important`.
- Make the index.html boot table, `ATTRIBUTE_AXES` and the CSP hash the union. Map `dragMotion` in
  the summary model.
- Drop hover previews that increase motion.

## Alternatives considered

- **Force-push the chain as cut.** This erases two merged develop features. Refused.
- **Merge develop into the branch and push the merge.** Allowed, and it carries the same conditions.
  A rebase keeps the step-1/step-2 split testable on its own.
- **Union both K1 mechanisms.** The #345 half would be dead code behind a vacuous test, so two
  copies of one capability. Refused.

## Consequences

**Verdict: BLOCK (as worded) → PROCEED-WITH-CONDITIONS (rebased).**

| Condition | Requirement |
|---|---|
| D1 | rebase onto the live origin/develop; no force of any kind; `merge-base --is-ancestor` rc=0 right before each push |
| D2 | exactly one K1 mechanism, the other deleted in the same commit |
| D3 | if #345's mechanism is kept, the ratio test asserts 4 durations matched per speed |
| D4 | the boot table and `ATTRIBUTE_AXES` are the union, with a parity test for the motion axes; the hash is recomputed; app-csp green |
| D5 | `dragMotion` maps to the `motion` section with anchor `motion-drag`, and the test asserts it |
| D6 | no hover preview lifts reduced motion (Motion and Animated images rows), with a test |
| D7 | full gate on the integrated tree, counts recorded |
| D8 | develop's head CI is `success` before step 1 |
| D9 | push #345 alone, then CI green, then fast-forward to drag; stop on red |
| M1–M7 (main) | native drag in Chromium and Firefox; no gap flicker on dragleave; the probe hash is derived, not hardcoded; the rollback note names the three new axes; GR2 plus a tree assert; reduced-motion settle clears; bridge unchanged if (b) |
