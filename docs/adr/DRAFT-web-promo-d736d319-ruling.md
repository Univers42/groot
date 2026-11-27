# DRAFT: osionos develop d736d3194 to main merges by an asserted tree, on green CI only

- Status: draft, untracked. Ruled by devil 2026-11-27: PROCEED-WITH-CONDITIONS, WD-1 to WD-15.
- Supersedes `DRAFT-web-promo-a2f762e8-ruling.md` (WA-1 to WA-14). That cut's develop CI concluded
  `failure` (run 46058607484, `settingsTab.spec.mjs:107` only), so it was never executed.
- Date: 2026-11-27
- Deciders: devil (ruling). The owner runs the push, the swap and the TB21 repair.
- Full ruling: `/mnt/storage/dlesieur/scratch/promo-5/RULING-web-d736d319.md`.

## Context

The delta a2f762e8b..d736d3194 is 12 files, +280 −14 (`git diff --stat`). It contains:

- motion keys for the last five shipped themes (bcc4b5694);
- a Settings › Preferences "Theme tokens" reference (d83fc53d0, merged as 0c45b2d5e);
- a test-only fix (d736d3194). The Mode control is now measured against its `<section>`, because the
  appearance redesign removed the card.

The facts this decision rests on:

- **Merge tree.** `git merge-tree --write-tree origin/main d736d3194` = `71acac827fc80c63778893432ec7cdc0c3feb46a`
  = `d736d3194^{tree}`. origin/main is still 0dbf72901.
- **Untouched paths.**
  - `index.html`, nginx and the build config are unchanged, so the report-only CSP hash set
    (`zFs8nWGv…`, `PtzXzBo8…`) is the same as WA-9.
  - Connector and bridge paths are unchanged (0-line diff).
  - No palette or top-bar file changed.
- **Beta.** Beta runs 0c45b2d5e. Its tree differs from d736d3194 only under `tests/`.
- **Reduced motion.** It covers the new theme motion: `global.css:914-937` applies `!important`
  durations, and no JS reads a duration token for timing.
- **Motion speed (defect K1).** The motion-speed setting does nothing under any shipped theme.
  - `themeApply.ts:41` writes theme tokens inline on `<html>`, and the inline value beats
    `motion.css:8-20` `:root[data-motion-speed]`.
  - 25 of 25 themes now set `dur-*` (20 before this delta).
  - Live main has no motion speed yet, so this push is the first time users see the control.
- **Copy JSON (defect K2).** The token reference copies invalid JSON for any value containing `"`,
  which covers every font token (`ThemeTokenReference.tsx:45`; value at `global.css:215`).
- **Unknown when written:** develop CI run 46062726615 on d736d3194 (`pending`).

## Decision

- Main is promoted by a `--no-ff` merge of the exact sha d736d3194 onto 0dbf72901, with tree `71acac82…`
  asserted. That happens only after develop CI is green on that sha.
- The beta soak counts on 0c45b2d5e or d736d3194, because their shipped trees are identical.
- PM14 is not rebuilt. Its invariant ("Set by your theme" absent from the entry) is re-checked on the
  built image.
- K1 and K2 ship as filed known defects. They are not blockers.

## Alternatives considered

- **Execute a2f762e8b with a rerun**: settingsTab:107 failed on retry too, and its cause is a real
  selector removal, not a flake. WA-1's rerun rule forbids it.
- **Fix K1/K2 before promoting**: this is the better product, and it costs one more ruling cycle
  (WD-1, WD-2 and WD-4 recomputed). Allowed, not required: K1 loses no data and has no security or
  reduced-motion impact, and K2 fails loudly when the JSON is parsed.
- **Rebuild PM14 on the new cut**: about 6 GB heap and a full prod build, to re-prove a number this
  delta cannot move materially. The delta adds one `sections.ts` row to the entry chunk.

## Consequences

**Verdict: PROCEED-WITH-CONDITIONS.**

| Condition | Requirement | vs WA |
|---|---|---|
| WD-1 | develop CI `success` on d736d319486c79c14193a2f61e0aee7a6874c04e. The never-rerun list adds settingsTab, themeTokenReference, motionPrefs, paletteCompleteness and theme-shipped | sha |
| WD-2 | `--no-ff` merge; parents 0dbf72901 and d736d3194; tree `71acac827fc80c63778893432ec7cdc0c3feb46a` | parent, tree |
| WD-3 | connector record, plus the empty connector-path diff a2f762e8b..d736d3194 | +1 line |
| WD-4 | 30-min soak on beta tag `0c45b2d5e02c` or `d736d319486c`; WA-4 pass plus a Theme tokens step; revoke | tag, step |
| WD-5 | CI log shows the axe specs, themeTokenReference, settingsTab:107 and motionPrefs passing | +specs |
| WD-6 to WD-8 | WA-6 to WA-8 verbatim (merge sha) | same |
| WD-9 | live probe: the same CSP hash set as WA-9; strings add `Filter tokens` | +string |
| WD-10 | WA-10, plus: the downgrade drops the Theme tokens section, with no state lost | +line |
| WD-11 / WD-12 | WA-11 / WA-12 verbatim | same |
| WD-13 | the PM1–PM17 evidence stands, re-anchored by an empty `src/widgets` diff | re-anchor |
| WD-14 | CSP checked in source (no diff) and in the image. The image's entry chunk has 0 `Set by your theme` and 0 `Filter tokens` | +entry check |
| WD-15 | one issue filed for K1 and K2 and linked in DEPLOY-NOTES as a known defect, before the push | new |

- Follow-up: main is still red live (run 46020158088). The WA follow-up on swaps over red main
  stands.
