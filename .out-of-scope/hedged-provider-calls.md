# Hedged provider calls in osionos-ai are out of scope

- Decided: 2026-11-21 · by devil (ruling `/mnt/storage/dlesieur/scratch/ai-boost/VERDICT.md`, AB31–AB32)
- Holds while: a run row holds one reservation and every public route is a `:free` model on the shared platform key

## The concept

When the first model of a run has not produced its first part within about its measured p95 time to first token, start the next model in the chain in parallel. Keep whichever answers first and abort the other, with at most one hedge per run. The goal is that a stalled free model never makes a member wait 90 s.

## Why not

- The ledger has one reservation per run. `ai_runs` holds one `reserved_microusd` and one `model`. Rotation is a compare-and-set on that value (`services/osionos-ai/src/runs/rotate.ts:54-60`), and loop extensions add to it (`runs/extend.ts:37`). Two live attempts force a choice between two failures:
  - the second reservation is unrecorded, and a crash leaks it past the sweep, which returns only what the row holds (`runs/repo.ts:163-182`);
  - or one attempt's extension breaks the other's rotation CAS, and the run ends.
- No public route qualifies. The design's own bound is "never on a route with a per-day request cap". Every public route today is an OpenRouter `:free` model on the shared platform key (`runs/quota.ts:36-43`), so that bound excludes them all.
- The aborted loser still spends a request upstream. On a user's own connection, it spends the user's money.
- The same goal is reached with one attempt at a time: an adaptive first-part clock with the existing sequential failover (AB33).

## Prior requests

- 2026-11-21 (AI boost design, Phase 4): hedge after measured p95 TTFT, capped at 8 s, at most 1 per run.

## Reopen when

All of the following hold:
- a ledger design records every concurrent reservation on the run, and keeps rotation, extension and the sweep correct with two live attempts;
- a declared per-route field proves that a route has no per-day cap and is off the shared key;
- user connections are excluded;
- Phase 0 timing shows first-content-part stalls over 8 s on at least 5 % of runs over at least 7 days.
