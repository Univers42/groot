# Raising the MarkEngine linearity ratio to turn CI green is out of scope

- Decided: 2026-11-20 · by devil
- Holds while: the threshold has no recorded distribution behind it

## The concept

develop is red on a 5.15 or 6.86 ratio, so raise MAX_RATIO (to 8, the midpoint between
linear 4x and quadratic 16x) in bench/html-subset-linear.test.cjs and move on.

## Why not

- The reds are a measurement flaw. Small and large are timed in separate windows (`bench/html-subset-linear.test.cjs:107-117`),
  and with the same engine b6dc3fd3 the failing case moves between runs. A bigger number keeps the flaw.
- Observed noise reached 6.86, so 8 leaves 1.14 of headroom with an unknown flake rate, and n^1.5 (8.0) passes.
- What would change the answer: a recorded distribution (local under load, idle, and fresh CI runs) whose max sits
  under the new threshold, with a quadratic mutant at least 2x above it (ADR 0068, B4/B5).

## Prior requests

- 2026-11-20 (option A in the develop-green ruling): raise to 8.

## Reopen when

The B5 distribution is recorded and 5 cannot hold under the interleaved metric.
