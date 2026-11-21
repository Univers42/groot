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
- Re-ruled 2026-11-20 (devil, `DEVIL-ME-BENCH-RERULE-VERDICT.md`): BLOCK on landing until R1–R12. A job
  timeout is not a mutant result. The guard fails fast: each first render runs in a worker thread that is
  terminated at a deadline. The metric is repaired before any threshold moves (R4c, fastest-of-k
  calibration), and T ≤ 7. An engine branch may be pushed for the 5 fresh CI runs; that is not a landing.
- Re-ruled 2026-11-20 on R5 (devil, `DEVIL-ME-BENCH-R5-VERDICT.md`): R4c failed R6 (5.72 > 5.5) and R7
  (39.86 ms), and the candidate read 15.99 on a linear shape under bench:ci. No wall-clock ratio gates
  linearity. The lift is a deterministic step counter (D1–D14) with a census tripwire. Interim: the
  guard runs as its own CI job (I1–I7, osionos develop 1619dce78, first run 44687495414 green on attempt
  1); demoting the ratio before D is raising it.
- Re-ruled 2026-11-21 on D4 (devil, `/mnt/storage/dlesieur/scratch/me-d/D4-RERULE.md`): engine ebb3358 read
  +2.39 / +4.59 / +1.59 % on `parse inline mixed 10K chars`, inside the machine's own noise. The limit stays
  3 %; the measurement changes (D4a–D4j): pinned to one fast core, load ≤ 3.0 per pair, an A/A calibration
  of 30 pairs within ±1.0 % first, then one 30-pair run whose per-case median is ≤ +3.0 %. No rerun on a
  result; one more fix commit gets one more attempt, then D is blocked and Z1 follows.
- Re-ruled 2026-11-21 on the D4 voids (devil, `/mnt/storage/dlesieur/scratch/me-d/D4-LIFT.md`, D4L1–D4L12):
  the load ≤ 3.0 gate voided three runs on host-wide load the bench cores never saw. It is replaced by a
  per-core gate (foreign time on the pinned cores ≤ 5 % per pair) and an in-run A/A arm (A, A′, B over all
  six orders). Fit: every A/A median within ±1.00 %; pass: every B-vs-A median ≤ +3.00 %. Run 1 of
  ebb3358 read PASS: worst +2.84 % (A/A −0.10 %), median of 30 pinned interleaved pairs, 0 pairs
  discarded; worst A/A +0.85 %. Harness `d4-abc.sh`/`.cjs`, sha256 in `logs/d4l-harness-freeze.sha256`;
  log `logs/d4l-ebb3358-run1.log`. D14 is unchanged and no push is granted by this lift. See
  [`load-average-as-bench-fitness`](../../.out-of-scope/load-average-as-bench-fitness.md).
