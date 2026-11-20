# The minimum of pair ratios as the MarkEngine linearity statistic is out of scope

- Decided: 2026-11-20 · by devil
- Holds while: pair ratios can fall below the true ratio under load

## The concept

Assert on the smallest of the PAIRS per-pair ratios in bench/html-subset-linear.test.cjs instead of the
median, so one noisy pair cannot turn the guard red.

## Why not

- Pair ratios deflate under load as well as inflate. The idle minimum went as low as 2.67, and load-3
  plain reached 1.88, against a true ratio of about 4.45. The minimum under-reports, and under-reporting is
  the dangerous direction for a regression guard.
- What would change the answer: a measurement showing pair ratios never fall below the idle true ratio
  under load.

## Prior requests

- 2026-11-20 (ADR 0068 re-rule, doc Q3): proposed as the decision rule.

## Reopen when

Such a measurement exists.
