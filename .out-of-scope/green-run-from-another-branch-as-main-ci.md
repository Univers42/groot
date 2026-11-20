# A green CI run on the same sha from another branch, or a re-run, standing in for a red main run, is out of scope

- Decided: 2026-11-18, by the devil (ADR 0052 O8 ruling).
- Holds while: CI on a single sha can disagree with itself (a flaky gate) and the house rule is "repaired, never
  skipped".

## The concept

M′'s main push run was red on a proven test defect, and its develop push run on the same sha was green. The
request: count the green run as "green CI on the served sha", or re-run the red job until it passes.

## Why not

- When two runs on one sha disagree, choosing the green one selects an outcome; it repairs nothing. It is a
  re-run by another door.
- Main-green is written down three times: 0057 BR11, ADR 0043:22, 0063 LP10.
- The defect stays on main, and every main push re-runs it.
- What would have to change: CI is shown deterministic for the sha (no test outcome differs between two runs of
  one tree), or the rule drops "green on main".

## Reopen when

A recorded, deterministic CI (the same results on repeat runs of one sha) replaces the retries=1 browser shards.

