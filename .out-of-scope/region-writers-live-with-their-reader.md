# Region and catalogue writers going live with their reader is out of scope

- Decided: 2026-11-22 · by devil (ruling `/mnt/storage/dlesieur/scratch/me-d/RULING-D-rerule.md`, RD5–RD8)
- Holds while: a live web tab can run a build whose canvas `migrate`/`unmigrate` enumerates cell fields by hand (T = 0e10ff567 and earlier)

## The concept

Re-rule TD18 so that candidate D promotes the canvas region controls, the Templates rail and the catalogue apply unflagged, in the same promotion as the reader that keeps `region`/`stackAt`/`sticky`.

## Why not

- Old tabs drop those fields silently on their next canvas save (template-dashboards ruling §5). Blocks survive and shell semantics do not.
- RP23 makes the user reload their own tabs. Nothing reloads other users' tabs, and their number at swap time is UNKNOWN.
- The gate is cheap: `osio.layout.modes` already exists, beta already bakes it =1, and two root gates (canvasReducer `setCellRegion`, pageStore.actions.ts:797) close it.
- What would have to change: a server-side view of client build versions showing 0 live tabs older than D′, or D′'s reader having been live for one full promotion. That second fact is TD18's own condition.

## Prior requests

- 2026-11-22 (ME-D lane): RP17 option 3, "re-rule TD18". Refused in favour of the flag (option 1).

## Reopen when

Client build telemetry exists and shows 0 pre-D′ tabs, or the promotion after D′ is being cut.
