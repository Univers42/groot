# A wall-clock ratio as the MarkEngine linearity gate is out of scope

- Decided: 2026-11-20 · by devil
- Holds while: CI runs `node --test bench/*.test.cjs` as parallel processes on shared runners

## The concept

Gate linearity on the ratio of two render times (large input over small input), tuned by
calibration until it stops flaking.

## Why not

- R4c, the best repaired statistic, failed R6 (5.72 > 5.5) and R7 (39.86 ms) at R5.
- Under `bench:ci` the candidate read 15.99 on a linear shape. The graded mutant reads 11, so no
  threshold separates them.

## Prior requests

- 2026-11-20 (ADR 0068 R5, Q1): R4c with a re-warmed calibration.

## Reopen when

A wall-clock statistic's max over idle, spin20, a verified heavy arm and 5 CI runs of `bench:ci`
stays below half the graded mutant (5.5).
