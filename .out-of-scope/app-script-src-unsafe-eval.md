# `script-src 'unsafe-eval'` in the osionos app CSP is out of scope

- Decided: 2026-11-22 · by devil (ADR 0076, RULING-314 §8)
- Holds while: no surface needs a live eval path

## The concept

Allow `eval` and `new Function` in the app shell so libraries that probe for them work unchanged.

## Why not

- The built bundle has no live eval path. The one the sweep found, zod 4's JIT probe, is switched off with `z.config({ jitless: true })` (osionos `src/app/zodNoEval.ts`).
- `'unsafe-eval'` turns any string an attacker controls into code.

## Reopen when

A sweep surface measures an eval that cannot be removed, or moved into a worker with its own policy.
