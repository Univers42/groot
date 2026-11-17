# Accepting the KDS first-session window (R8) and making the template e2e spec wait is out of scope

- Decided: 2026-11-17 · by devil (R8 verdict, option D; [ADR 0052](../docs/adr/0052-the-kds-indexeddb-move-still-loses-or-risks-the-edits-named-here-and-is-not-loss-free.md) R8)
- Holds while: a bounded fix for R8 exists (A2: seed write at readiness plus the J-C2 first-session rule) and the pre-P1 code passes `tests/e2e/functional/templateUse.spec.mjs`.

## The concept

Keep R8 as a named residual and change `templateUse.spec.mjs` to wait for the first IndexedDB commit before it reloads.

## Why not

- The spec is the only end-to-end coverage of a first session. Making it wait removes the one test that caught R8.
- The pre-P1 localStorage writer passes the spec as written (4b6e8fdf2, CI green), so R8 is a regression against legacy, not a limit of the platform.
- A2 closes it without changing the flush schedule or the journal apply path.

## Prior requests

- 2026-11-17 (osionos develop red, CI run 44037496549): proposed, rejected.

## Reopen when

A2 is proved unable to close R8 (a measured first-session loss under A2), and no other bounded fix is ruled.
