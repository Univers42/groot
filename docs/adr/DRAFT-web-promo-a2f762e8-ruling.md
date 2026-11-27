# DRAFT: osionos develop a2f762e8b to main merges by an asserted tree, on green CI only

- Status: **superseded** 2026-11-27 by `DRAFT-web-promo-d736d319-ruling.md` (WD-1 to WD-15). The
  a2f762e8b cut was never executed: develop CI run 46058607484 concluded `failure`
  (`settingsTab.spec.mjs:107`), so WA-1 stopped it as designed.
- Original status: draft, untracked. Ruled by devil 2026-11-27: PROCEED-WITH-CONDITIONS, WA-1 to WA-14.
  It supersedes the unexecuted 012519d6c cut (WP-1 to WP-12), whose develop CI concluded `failure`
  (run 46037813467).
- Date: 2026-11-27
- Deciders: devil (ruling); the owner runs the push, the swap and the TB21 repair.
- Full ruling: `/mnt/storage/dlesieur/scratch/promo-4/RULING-web-a2f762e8.md`.

## Context

- The range is `0dbf72901..a2f762e8b`: 65 commits, 249 files, +6778/−2010. Since the last ruled cut
  (`012519d6c..a2f762e8b`) it is 99 files, +3759/−802.
- What the delta adds:
  - appearance sections with per-row reset and JSON backup;
  - the theme gallery with JSON import/export;
  - motion preferences;
  - the phone shell (drawer focus trap, safe areas, `viewport-fit=cover`);
  - the CI-fix branch;
  - top-bar palette modes (PM1–PM17).
- The connector and bridge are identical to the ruled cut:
  `git diff --stat 012519d6c a2f762e8b -- packages/osionos-node scripts/bridge-machines.mjs 'scripts/ide-*.mjs' install.sh services docker/services/bridge`
  prints nothing. The push is still a Connector release relative to live main.
- `git merge-tree --write-tree origin/main a2f762e8b` gives rc=0 and tree
  `cf5ba1b65bcbe58063e871bbd025d586ddf0cc8f`, which equals `a2f762e8b^{tree}`. Main is not an ancestor
  of develop: `git rev-list --count a2f762e8b..0dbf72901` = 11.
- `index.html`'s boot script changed. The report-only CSP hash in `docker/services/node/nginx.conf:15`
  moved to `PtzXzBo8…`, and the computed hash of the new inline script matches.
- `uiStore.ts:196` is still persist version 3. The appearance parser is field by field (old
  `appearance.ts:113ff`), so a rollback ignores the new keys.
- No develop CI run has been green since 2eea851d0 (2026-11-26T21:14Z). Live main 0dbf72901 CI is
  `failure` (run 46020158088).
- Beta serves 58cd2908d, not a2f762e8b.
- Unknown when this was written:
  - develop CI for a2f762e8b (pending);
  - axe and quality on this exact tree (no local log covers them);
  - a beta soak on this tree;
  - closure of PM1–PM17.

## Decision

Main is promoted by a `--no-ff` merge of the exact sha a2f762e8b onto 0dbf72901, with the merge tree
asserted to be `cf5ba1b6…`. That happens only after develop CI is green on that sha. A rerun is allowed
only for a named pre-existing flake, and never for a connector, palette, axe or title-bar spec. The web
swap uses `ops/vm-scripts/deploy-web-main.sh ON=main` with the merge sha. The bridge is untouched.

## Alternatives considered

- **Execute the old 012519d6c cut**: its develop CI concluded `failure` (run 46037813467). It would
  ship a tree whose browser shards were red. It also lacks the CI-fix commits.
- **Ship a2f762e8b on the local gates alone**: the local e2e log (`e2e4.log`) never ran a11yAudit or
  a11yNewSurfaces. `quality4.log` predates the a2f762e8b commit by about 3 min. Live main is already
  red, so "local green" is the only evidence, and it does not cover this tree.
- **Accept a red CI as "pre-existing" because main is red too**: `machinePairCode.spec.mjs:7` fails on
  live main. Waving it through on a push that releases the Connector is how a pairing regression would
  ship unseen.

## Consequences

**Verdict: PROCEED-WITH-CONDITIONS.**

| Condition | Requirement | Relation to the prior ruling |
|---|---|---|
| WA-1 | develop CI success on a2f762e8b; restricted rerun rule | new sha |
| WA-2 | `--no-ff` merge of the sha; parents 0dbf72901 and a2f762e8b; tree `cf5ba1b65bcbe58063e871bbd025d586ddf0cc8f`; never a force-push | new tree |
| WA-3 | connector release record | WP-3, plus the empty 012519d6c..a2f762e8b connector diff |
| WA-4 | 30-min beta soak on `a2f762e8b43f`; signed-in pass adds palette modes, the theme gallery (no import or delete: beta shares the prod bridge) and the phone drawer; revoke after | new tree, wider pass |
| WA-5 | axe specs pass on this tree, from the CI logs or a local run | — |
| WA-6 | main CI and node-pages green; tarball verified | WP-6 |
| WA-7 | deploy script with `ON=main`, the merge sha and `SUMMARY=` | WP-7 |
| WA-8 | bridge image unchanged | WP-8 |
| WA-9 | live probe with the new CSP hash and new strings; 10-min watch | changed |
| WA-10 | web rollback; motion prefs are dropped on downgrade | WP-10, plus a caveat |
| WA-11 / WA-12 | TB21 repair and connector rollback | WP-11 / WP-12 verbatim |
| WA-13 | PM1–PM17 proof list before the push | — |
| WA-14 | CSP inline hash checked in source and in the built image | — |

- Follow-up: main has been red since at least 6f54c4c56. Each further swap on red main lowers the
  value of the WA-6 and WA-10 "main CI red" trigger. The next promotion should find main green, or it
  re-rules that trigger.
