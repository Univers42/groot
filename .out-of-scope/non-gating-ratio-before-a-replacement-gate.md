# Demoting the linearity ratio to non-gating before its replacement exists is out of scope

- Decided: 2026-11-20 · by devil
- Holds while: the step counter (ADR 0068 D1–D14) is not on engine main

## The concept

Make the wall-clock ratio print-only now, and rely on the deadline worker until the step counter lands.

## Why not

- The deadline catches 0 of the 8 graded-mutant shapes, so a non-gating ratio leaves the regression
  class unguarded. That is raising the ratio, which ADR 0068 forbids.

## Prior requests

- 2026-11-20 (ADR 0068 R5, Q3).

## Reopen when

A gate catches the R2 graded mutant 3/3 while the ratio is non-gating.
