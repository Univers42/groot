# osionos AI boost: faster first token, steadier routing (design draft)

Status: draft for the user's approval. It needs a devil ruling before any code.
Date: 2026-11-21. Recon on osionos develop 230dde4c5: `/mnt/storage/dlesieur/scratch/ai-boost/recon.md`
(every claim below carries its file:line there).

## Intent
The user asked for an "ultra boosted" AI system. That means:
- answers start fast;
- a slow or rate-limited free model does not stall a member;
- the in-app bot (design `2026-11-21-osio-bot-design.md`) can rely on the same path.

## What the code does today (facts)
- One run makes about 25 sequential awaits before the provider call. That is about 8 Redis round trips, 20–30
  Postgres queries and 1–2 HTTP calls, with no `Promise.all` (`runner.ts:214-493`).
- Membership (`liveMemberWorkspaces`) is queried up to 4 times per run and again on every tool call. It is
  deliberately uncached, so that a removed member loses access at once.
- The history read loads the whole conversation, then trims it to 24,000 chars in memory.
- Every streamed token awaits a Redis `XADD` before its SSE frame is written (`upstream.ts:88-91`).
- Failover is sequential. A stalled first model can cost up to 90 s before the next one starts.
- The model rank is a static operator number. Nothing measures live latency or health.
- The prompt puts dynamic blocks early, and there are no prompt-cache controls, so upstream prefix caching barely helps.
- No embedding cache.
- The provider catalog's in-memory copy expires after 86 s instead of 24 h. That is a ms/s unit bug at
  `connections/catalog.ts:116,125`.
- **No phase timing exists.** Mock-upstream service overhead is p50 9.1 ms. Nobody has measured where real
  time goes: pre-flight, provider TTFT, or failover.

## Goals
1. Measure first: per-run phase timings (pre-flight, provider TTFT, first-token-to-done, failovers) in the
   existing JSON log line, plus a repeatable bench baseline. Every later phase must beat this baseline.
2. Cut pre-flight wall time: independent loads run concurrently; membership is read once per run; the history
   read is bounded in SQL.
3. Take Redis off the per-token path, without breaking resume.
4. Stop a stalled free model from costing 90 s.
5. Rank models on measured latency and failure rate, not a static number.
6. Fix the catalog TTL bug.

## Non-goals
- No public local GPU (FC7 keeps `osionos-ai-llm` dev-only). No reranker, because its measured p95 is 22 s.
- No new paid provider, and no change to the no-train rule.
- No response cache: answers depend on per-user ACL context, and caching them across users would leak.

## Anti-goals
- A faster run that shows a removed member a page they lost access to.
- A resumed stream that misses or repeats tokens.
- Hedging that burns the free daily quota (the OpenRouter free cap is 50 requests a day per key) twice as fast.

## Approaches
- **A. Measure, then cheap structural wins (recommended).** Phase timing first. Then concurrency, a
  run-scoped membership read, a bounded history read, batched stream appends, prompt reorder and the TTL
  fix. Then measured rank. Hedging only if the measurements show stalls are common. Each step is small,
  reversible, and measured against the baseline.
- **B. A rewrite onto a queue/worker model:** an admission queue, worker processes, and a separate streaming
  edge. It scales further, but it is a large change with no measurement saying it is needed. The mock
  upstream knee is 140 concurrent runs, far above today's traffic. Deferred.
- **C. Local GPU as the primary engine.** It is fast for one user (TTFT 1.26 s), but it saturates at
  1 request/s and is ruled dev-only. Rejected for public use.

## Design (approach A)

### Phase 0: phase timing and baseline
- `startRun` and `runUpstream` record monotonic marks: `preflight_ms`, `provider_ttft_ms`, `stream_ms`,
  `attempts`, `failover_ms`. They go into the run's log line (`server.ts:81`) and the `ai_runs` row's existing
  metadata if it has room (no migration otherwise).
- Baseline: `scripts/bench/stream-run.mjs` against the live AI API, n ≥ 20, recorded in an artifact with the
  command. It is spent from a bench key or BYO key, never the shared free key.

### Phase 1: pre-flight
- Group the startRun loads by dependency:
  - (a) insert, rate limit and quota stay first and sequential, because they fail closed;
  - (b) history, summary, page context, skills, memories, user context, account, overview, MCP tools, hooks and
    the web flag run in one `Promise.all`, after a single membership read;
  - (c) reserve, append turn and touch stay sequential.
- Membership: read once at run start and pass to every consumer in the run. Tool calls inside the run re-read
  it, as today, so access removed mid-run still applies to tool reads.
- History: `listMessages` with a SQL `limit` (the newest N rows that can fit 24,000 chars), then trim as today.
- Pool budget: the concurrent loads must fit the pool of 10 connections at expected concurrency. This needs a
  bound, for example at most 4 concurrent queries per run, and a ruling.

### Phase 2: stream path
- The SSE frame is written first. Stream appends are buffered and flushed as one `XADD` pipeline every 50 ms or
  32 deltas, in order, plus a final flush before `done`. Citation emits go in one pipeline.
- Resume reads Redis, so a client that resumes inside the 50 ms window can miss the last unflushed deltas. On
  resume, the server flushes before it reads. This needs a ruling.

### Phase 3: prompt layout for upstream prefix caching
- Order: the system prompt and stable workspace blocks first, history next, and the per-turn dynamic blocks
  (sources, page context) last, next to the user turn. Add provider prompt-cache hints only where the wire
  supports them (Anthropic-compatible `cache_control`). Measure `provider_ttft_ms` before and after.

### Phase 4: measured rank, then optional hedging
- Measured rank: an exponentially weighted average of `provider_ttft_ms` and the failure rate per model, kept in
  Redis from Phase 0's marks. `autoChain` sorts on it, with the static rank as the prior and the tie-break.
- Hedging: build only if Phase 0 shows first-part stalls above a threshold. If the first model has no first part
  after t = measured p95 TTFT (capped at 8 s), start the next model in the chain, keep the first to answer, and
  abort the other. Bound: at most 1 hedge per run. It is never used on a route with a per-day request cap. It
  needs a ruling.

### Small fixes (any time)
- Catalog TTL: `Date.now() + CATALOG_TTL_SECONDS * 1000`, plus a unit test.
- Rate limit: the fixed window stays. A sliding window is noted, not built (YAGNI until abuse is seen).

## Left to the builder
Flush cadence within 25–100 ms, the exact `Promise.all` grouping inside the stated dependency order, and log
field names.

## Open questions for the user
None blocking. Phase 4 hedging is built only if the Phase 0 numbers justify it.
