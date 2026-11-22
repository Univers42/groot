# `script-src 'unsafe-inline'` in the osionos app CSP is out of scope

- Decided: 2026-11-22 · by devil (ADR 0076, RULING-314 §8)
- Holds while: the shell's inline scripts are static

## The concept

Allow inline scripts in the app shell's `script-src` so `index.html` needs no hashes.

## Why not

- It voids the policy: an injected inline script runs as if it were the app's.
- The two inline scripts are static, and their hashes cost nothing. `tests/canvas/app-csp.test.ts` in osionos fails when a hash drifts.

## Reopen when

The inline scripts change per response. Then use nonces, not `'unsafe-inline'`.
