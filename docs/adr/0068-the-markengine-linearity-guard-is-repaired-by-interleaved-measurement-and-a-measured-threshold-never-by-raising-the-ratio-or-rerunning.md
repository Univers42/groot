# 0068. Repair the MarkEngine linearity guard: interleave the measurement and measure the threshold; never raise the ratio or rerun it green

- Status: accepted
- Date: 2026-11-20
- Deciders: devil (PROCEED-WITH-CONDITIONS); osionos develop owners live with it

## Context

- Two red osionos develop runs (44665301830, 44667218460) both pin engine b6dc3fd3
  (`git ls-tree a88232322|0f6f39dd4 packages/markdown-engine`). A different case fails in each:
  link brackets (plain) 6.86, then 4.13; underline half-closed (plain) 4.47, then 5.15. This is noise.
- Twelve span shapes sit at 4.13-5.15 against MAX_RATIO 5
  (`grep -a '# .*ratio' /mnt/storage/dlesieur/scratch/integ/logs/t1a-dev-markengine.log`).
- All 50 KB runs finish before the 200 KB runs start (`bench/html-subset-linear.test.cjs:107-117`).
  A contention window can therefore land on one side only.
- The file's Caveat (lines 16-18) prescribes "re-run once", which is rerun-to-green.
- Unknown when this was written: the guard's flake rate at any threshold, and whether a mutant is caught at the new metric.

## Decision

The guard alternates 50 KB and 200 KB batches and asserts on the median per-pair ratio, or on a
three-size exponent. Its threshold comes from a recorded distribution plus a quadratic mutant that
must fail. Conditions B1-B9 and the pin-bump rules are in
/mnt/storage/dlesieur/scratch/ci-main-shard2/DEVIL-ME-BENCH.md, tracked on Univers42/osionos#332.

## Alternatives considered

- **MAX_RATIO 8**: n^1.5 = 8.0 passes, and observed noise already reached 6.86, so the headroom is
  1.14 with an unknown flake rate. The sequential-window flaw stays.
- **Leave develop red**: Browser shards are skipped on every push, and red stops meaning anything.
- **Deterministic step counter**: exact, but needs engine instrumentation. It is a follow-up, not this fix.

## Consequences

- The guard's threshold now cites runs (local under load, idle, and 5 fresh CI runs) plus a mutant result.
- The pin bump may land on develop alone only if it is gitlink-only, bench/-only in the engine, and reachable on GitHub.
- Reverse this only by re-measuring. A new red is read from the per-pair spread, never re-run.
