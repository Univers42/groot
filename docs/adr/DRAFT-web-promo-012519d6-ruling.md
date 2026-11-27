# DRAFT: osionos develop 012519d6c to main is a web swap and a Connector release

- Status: draft, untracked. Ruled by devil 2026-11-27: PROCEED-WITH-CONDITIONS, WP-1 to WP-12.
- Full ruling: `/mnt/storage/dlesieur/scratch/promo-3/RULING-web-012519d6.md`.

## Context

- The range is `0dbf72901..012519d6c`: 16 first-parent commits, 166 files, +3091/−1280. It brings the
  sidebar rail, Welcome, the AI Hub folded into Settings (AS1–AS12), the dock and auto-hide title bar,
  and the trusted-browser Connector (TB1–TB25).
- Pushing main releases the Connector:
  - `packages/osionos-node/install.sh:52` clones `--branch main`;
  - `src/features/machines/model/machineChoice.ts:90` serves install.sh from raw main;
  - `.github/workflows/node-pages.yml:5-7` rebuilds the pages release on every main push.
- Main is not an ancestor of develop. Main holds 11 `merge(develop)` commits with no content of their own.
  The merged tree is `1c0ec9d00…`, the same as develop's.
- The bridge half is already live: `bridge-machines.mjs` and `ide-machine-protocol.mjs` have an empty
  diff against `016fa51d0`.
- TB17's probe exercised connector code identical to the cut.
- The on-disk formats are unchanged. The remember windows shrink to 12 h / 30 d.
- `ui-storage` stays at persist version 3. An `assistant` panel id therefore reaches the old web raw on
  rollback and renders an empty panel (old `SidebarPanel.tsx`).

## Alternatives

| Option | Cost |
|---|---|
| Treat it as UI-only (the standing recipe) | Releases the Connector to every installer with no release record, and builds with the build-ahead mode on a non-fast-forward |
| Hold the connector half back (revert the packages/ changes on main) | Splits the trees: main ≠ develop, beta's evidence no longer applies, and the next promotion re-litigates. The connector evidence is already complete |
| Merge commit + release record + conditions (chosen) | One axe pass, a 30-min beta soak, the node-pages verification, and a guarded owner repair |

## Consequences

**Verdict: PROCEED-WITH-CONDITIONS.**

- WP-1: develop CI green.
- WP-2: `--no-ff` merge with an asserted tree, never a force-push.
- WP-3: the connector release record (TB17, SG12-2 by 69cda7f4a equivalence, SG13).
- WP-4: beta soak with a signed-in smoke.
- WP-5: axe on four new surfaces.
- WP-6: main CI and node-pages verified.
- WP-7: `ops/vm-scripts/deploy-web-main.sh` with `ON=main` and the merge sha.
- WP-8: bridge image unchanged, no bridge build from app-main.
- WP-9: live probe and watch.
- WP-10: web rollback and the downgrade caveat.
- WP-11: guarded TB21 repair after node-pages; the owner's start.sh lists beta only today.
- WP-12: connector rollback by revert only.
