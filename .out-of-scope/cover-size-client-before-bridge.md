# Shipping the cover-size client writer before the bridge serves it is out of scope

- Decided: 2026-11-23 · by devil (cover writer ruling, `scratch/cover-writer/RULING.md` Q3)
- Holds while: a deployed bridge accepts `cover_height` / `cover_width` in a page write and drops them

## The concept

Land the client half of the resizable cover first (resize handle, `changeCoverSize`, outbox fields) and let the bridge half follow in a later promotion, since the client is the visible part.

## Why not

- Today's bridge handles `cover_position` only (`scripts/bridge-api.mjs:759,855,894`). It answers 200 to a write carrying the size fields and stores neither.
- The client marks the page saved on that 200, so the size the user set is gone on the next read-back, with no error and no retry.

## Prior requests

- 2026-11-23 (page-shells plan, Phase 5).

## Reopen when

Beta stops sharing the production bridge (ADR 0040), or the bridge starts answering an unknown page field with `ignored` instead of a silent 200. Until then the order is bridge unit first (validated, proven in the deployed image, probed on a page we own), then the client unit. Rollback runs the other way: client, bridge, and the manual DOWN only while both NOT NULL counts are 0.
