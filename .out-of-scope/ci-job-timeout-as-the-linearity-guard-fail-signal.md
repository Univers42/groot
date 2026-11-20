# A CI job timeout as the linearity guard's fail signal is out of scope

- Decided: 2026-11-20 · by devil
- Holds while: the osionos quality job has no timeout-minutes

## The concept

Accept that a quadratic or endless engine regression hangs bench/html-subset-linear.test.cjs, and let the
CI job's timeout be the red that catches it.

## Why not

- The osionos `quality (markengine-submodule)` job has no `timeout-minutes`, so a hang runs GitHub's
  default 360 min and ends as a timeout. The timeout names no input, size or ratio.
- People read a bare timeout as infra and re-run it, which ADR 0068 forbids. The only mutant evidence
  (an injected hang, rc 124 with an empty TAP) shows no ratio at all.
- What would change the answer: the job fails within minutes of a hang with a message that names it.

## Prior requests

- 2026-11-20 (ADR 0068 re-rule, Q1): offered as satisfying B4.

## Reopen when

Never as the guard's only signal; the guard fails fast by its own deadline (R1).
