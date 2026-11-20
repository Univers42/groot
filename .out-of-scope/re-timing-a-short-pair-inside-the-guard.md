# Re-timing or skipping a short pair inside the linearity guard is out of scope

- Decided: 2026-11-20 · by devil
- Holds while: ADR 0068 forbids reruns

## The concept

When a timed batch in bench/html-subset-linear.test.cjs comes out under SAMPLE_MS, time that pair again
or skip it, so short batches cannot decide the ratio.

## Why not

- Re-timing a pair is an in-process rerun, and ADR 0068 forbids rerunning the guard green.
- A skipped pair is not a passing pair.
- The batch floor is reached by construction instead (R4c: size each doubling step from the fastest of
  k timings, plus headroom; R7 checks the shortest batch over every recorded run).

## Prior requests

- 2026-11-20 (ADR 0068 re-rule, doc Q2 option b).

## Reopen when

Never while ADR 0068 forbids reruns.
