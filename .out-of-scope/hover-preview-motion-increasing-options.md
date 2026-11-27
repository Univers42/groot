# A hover preview that turns motion on is out of scope

- Decided: 2026-11-27 · by devil (ruling `/mnt/storage/dlesieur/scratch/promo-5/RULING-develop-345-drag.md` D6, draft `docs/adr/DRAFT-develop-345-drag-ruling.md`)
- Holds while: the reduced-motion guard is `:root:not([data-motion="full"])` in osionos `global.css:914-925`

## The concept

Settings rows can preview an option on mouse hover after 150 ms (`Segmented` `previewAxis`). The
request applied this to every row, including Motion ("full") and Animated images ("play").

## Why not

- Previewing Motion "full" writes `data-motion="full"` on `<html>`. That disables the
  prefers-reduced-motion reset app-wide, because of a hover and not a choice
  (`AccessibilitySettings.tsx:51,60` at osionos 21fea21b3).
- The setting exists for the people this harms. Moving a mouse across the row is not consent.
- What would change the answer: a preview scoped to a sample element rather than `<html>`, or a
  preview that never lifts a restriction that is in force (reduce → full, still → play).

## Prior requests

- 2026-11-27 (builder, 21fea21b3): previewAxis on all 13 rows. Refused for Motion and Animated
  images only.

## Reopen when

The preview renders into a local sample, not the document root.
