# DRAFT: Promotion 2, osionos develop → main, bridge then web

- Status: proposed (devil ruling PROCEED-WITH-CONDITIONS, 2026-11-24)
- Full ruling: /mnt/storage/dlesieur/scratch/promo-2/RULING.md

## Context

- The range runs from main d2db43733 to develop 0e85b24fd: 100 commits, fast-forward possible.
- CI is green on the first attempt on 0e85b24fd (run 45264988087) and on 138636638 (run 45253460536).
- Beta has served `0e85b24fdf49` against the production bridge for about 3 h (ADR 0040).
- No DDL is in the range. The `cover_height` and `cover_width` columns and their CHECKs already exist, are validated in production, and both counts are 0/0.
- On main, `pageRowToEntry` (`scripts/bridge-api.mjs:746`) has no cover-size field, so an older bridge ignores sized rows.
- On develop, `PAGE_LIST_SELECT` (`bridge-api.mjs:1765`) adds sizes. `readFullPageList` (`:1936`) is gate → read → proof, which adds 2 BaaS round trips.
- Live bridge → BaaS round trip, measured 2026-11-24: 40 kept-alive calls answered 401 at Kong, p50 0.87 ms, p90 1.22 ms. This is a transport-only lower bound.
- Session cut-offs default on (`bridge-api.mjs:250`). Neither cut-off variable is set live.
- The live AI `mode` and `applied` routes return 404 unauthenticated, so the server flag is off.
- The web CSP comes from osionos `docker/services/node/nginx.conf` (enforced header at `:42`).

## Alternatives

| Option | Cost |
|---|---|
| Joint bridge + web swap | One failure becomes unattributable, and recovery needs a double rollback. |
| Wait for #240 | Holds back the 5xx-leak fix and the #296/#343 F7 close. #240 has open BLOCK conditions (S1-9, M240). |
| Cut at 138636638 always (no #243) | Gives up −137 ms on the largest workspace for a risk measured at under 1 ms per call. This cut stays the fallback. |
| **Bridge first, watch, then web; cut 0e85b24fd if PR2-4 holds** | Two windows. Each rollback lands on a pairing that has already run. |

## Decision

Promote in two swaps, bridge first, with a 10-minute watch before the web swap. Include #243 only when the cut-day round trip is p50 ≤ 2.0 ms and p90 ≤ 3.0 ms. Otherwise cut at 138636638. Do not wait for #240. S1 rides only if it is cleared before the cut; otherwise it ships alone by 2026-11-30.

## Consequences

The conditions PR2-1 to PR2-22 are the acceptance criteria. They cover:

- the cut:
  - fresh ls-remote and CI on the exact sha;
  - the PR2-4 measurement;
  - S1/#240 scope;
- image builds and the rollback images, kept for 7 days;
- a value-digest env diff with 0 added, 0 removed, 0 changed;
- rollback scripts written before the swap;
- CS16 counts;
- the bridge watch;
- probes, all with probe accounts:
  - sign-in;
  - page list before/after, with the F243-23 kill and member/non-member checks;
  - cover item 12;
  - non-destructive demote checks;
- web headers:
  - enforced CSP byte-identical;
  - Report-Only adds only frame-src, img-src and style-src;
- bundle flags off, and the served chunk equals the build;
- `?osio.ai.modes=1` degrades to 404 with no write;
- zero console errors;
- the web watch;
- the rollback triggers, web first then bridge;
- a session revoke after every sign-in;
- DEPLOY-NOTES records;
- the groot pin moved last.

A bridge rollback reopens the #296 F7 gap and leaves cover sizes in place, invisible. Both are safe. A cleared admin flag is never re-set by hand (D343-8).
