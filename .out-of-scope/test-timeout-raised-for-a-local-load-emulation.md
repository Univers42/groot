# Raising a test's timeout because a local load emulation fails it is out of scope

- Decided: 2026-11-20 · by devil (O8 T₂ re-ruling, option 1)
- Holds while: CI times the same tests well under the limit (run 44592134152: the five 1440 reload cases took 17.4–20.8 s against a 60 s timeout).

## The concept

Shard 1/6 of T₂ (osionos 0e10ff567) failed locally at `cpus: 1.0`: blockResize 1440 reload cases hit the 60 s
test timeout. The proposal was to add `test.slow()` (or a longer `setTimeout`) to those tests so the local run passes.

## Why not

- The one-CPU emulation ran about 3× slower than CI, which gives each shard a 4-vCPU runner. The failure measured the emulation, not the test.
- A timeout raised to pass a gate bends the gate. The test would then hide a real slowdown the day CI produces one.
- What would change the answer: a CI run, or a run calibrated to CI load or harsher (T2-9: shard time ≥ 1124 s and the median 1440 reload case ≥ 23 s), times the test out. Then the timeout is a measured harness fact.

## Prior requests

- 2026-11-20 (osionos T₂ evidence (e)): proposed, rejected; (e) re-run under T2-8..T2-14 instead.
