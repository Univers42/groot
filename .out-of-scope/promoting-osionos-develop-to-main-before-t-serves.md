# Promoting osionos develop to main before T serves is out of scope

- Decided: 2026-11-19 · by devil (ADR 0067, Decision 1)
- Holds while: live serves a pre-P1 image, so no post-P1 image has ever served.

## The concept

Fast-forward osionos main to the green develop tip (6e19a378f on 2026-11-19), build one image and swap it live, in one step. That ships T, H′, the fence reader, R-BR5 and the cover reader together. It is fewer deploys and gets every fix live at once.

## Why not

- The first image that serves P1 can only be rolled back forward (K7). Today live is `main-0333d796-site`, which is pre-P1, and `main-6de25733-site` never served. A single develop swap therefore has no rollback image at all. T, the test-only child of M′, gives the first post-P1 serve and makes it the rollback target (O8c-1..11).
- The develop tip adds two vacuous async `waitForFunction` predicates (`blockLayoutModes.spec.mjs:39`, `blockStyleParity.spec.mjs:54`), so its main CI would be green for the wrong reason.
- The main push publishes node-pages and cannot be undone (BR13d).

What would have to change:

- a post-P1 image has served live (T or any successor);
- that image is recorded as the rollback target in the deploy log.

## Prior requests

- 2026-11-19 (coordinator): promote develop 6e19a378f under the user's "continue until phase ultimate is done".

## Reopen when

A post-P1 image is live and recorded as the rollback target. From then on, a develop promotion is a frozen candidate under ADR 0067 RP6–RP24, not this concept.
