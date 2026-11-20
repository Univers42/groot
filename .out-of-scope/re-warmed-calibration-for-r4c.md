# A re-warmed calibration for the R4c ratio is out of scope

- Decided: 2026-11-20 · by devil
- Holds while: the failing R6 case's shortest batch is above 50 ms

## The concept

Re-run R4c's fastest-of-k calibration after an extra warm-up so its R6 failure (5.72 > 5.5) clears.

## Why not

- The failing case's shortest batch is 104.71 ms: too long for warm-up noise to explain, so a
  re-warm would hide load, not remove it.

## Prior requests

- 2026-11-20 (ADR 0068 R5, Q1, option 2).

## Reopen when

An R6 failure's shortest batch is under 50 ms.
