# DRAFT. The AI boost measures first, then runs the pre-flight loads in bounded parallel stages behind one membership read per run; frames stay durable before they are sent, the prompt keeps its layout, the rank is measured, and hedged calls are not built

- Status: proposed (devil ruling, 2026-11-21). Per part:
  - **Approach A**: PROCEED-WITH-CONDITIONS.
  - **Phase 0** (timing + baseline): PROCEED-WITH-CONDITIONS.
  - **Phase 1** (pre-flight concurrency, membership read once per run, bounded history): PROCEED-WITH-CONDITIONS.
  - **Phase 2** (batched stream appends): BLOCK as written. The AB16–AB21 lift turns it into PROCEED-WITH-CONDITIONS.
  - **Phase 3** (prompt reorder + cache hints): BLOCK as written, because its premise is false. Lift: AB22–AB24.
  - **Phase 4a** (measured rank): PROCEED-WITH-CONDITIONS.
  - **Phase 4b** (hedged provider calls): BLOCK. Reopen conditions: AB32.
  - **Phase 4b′** (adaptive first-part clock; not in the design, named as the alternative): PROCEED-WITH-CONDITIONS if chosen.
  - **Small fixes**: catalog TTL PROCEED-WITH-CONDITIONS. The rate limit is not changed, so there is nothing to rule.
  - **Approach B** (queue/worker rewrite): deferral PROCEED. **Approach C** (local GPU primary): rejected for public. FC7 already binds.
- Date: 2026-11-21
- Deciders: devil (ruling); the osionos-ai builder and the operator (live with it)
- Design: `groot/docs/superpowers/specs/2026-11-21-ai-boost-design.md`. Recon: `/mnt/storage/dlesieur/scratch/ai-boost/recon.md`
- Code read: `/mnt/storage/dlesieur/wt/osionos-more-free-ai/services/osionos-ai/src` at `230dde4c5`. Paths below are relative to that `src/` unless they say otherwise.

## Context

### Steel-man
The strongest case for the design: on live, the database sits behind the VM's tailnet TCP serve (`groot/docker-compose.public.yml:131-137`). Each of the roughly 25 sequential pre-flight awaits therefore pays a network round trip (`runs/runner.ts:225-446`). Running the independent loads together is the cheapest real latency win available. The design measures before it optimises (Phase 0), keeps the fail-closed checks sequential, keeps tool-time membership live, and defers the rewrite (B) and the GPU (C) for measured reasons. That is the right shape. The verdicts below rule on that best version.

### Facts that decide the rulings
- **Membership.** `liveMemberWorkspaces` is uncached by design. C98 was about the **token's** member list, which lives about an hour, being unioned in (`retrieval/acl.ts:64-72,88-102`). "Live" means read at query time.
  - A run-scoped read moves "query time" back by the pre-flight duration. That window is milliseconds to seconds, and it is bounded by the pg timeouts of 5 s (`db.ts:63-69`).
  - The pages read in pre-flight are then quoted to the model for the whole run: up to 120 s, or 8 min for research. So the run-start read is not a new class of staleness.
  - The pattern already exists: the route reads membership once and passes `memberWorkspaceIds` into `loadPageContext` (`routes/runs.ts:217,259`, `runs/runner.ts:320-324`).
  - Today's pre-flight readers all pass `(db, user)` and take the scope from `user.scope`: `retrieval/search.ts:497,591`, `skills/runSkills.ts:117`, `memory/runMemories.ts:20`, `context/runContext.ts:115`, `runs/workspace.ts:136`.
- **Dependencies the design's group (b) misses:**
  - The edit-and-resend delete must precede the history read (`runner.ts:297-307`).
  - The summary needs the window's `oldestKeptId` and `dropped` (`runner.ts:311-312`).
  - `userContextForRun` takes `skillIndex` (`runner.ts:332-352`).
  - The C340 refusal needs `skillIndex` before any money moves (`runner.ts:338-341`).
  - `recordMemoryPins` writes after the memories load (`runner.ts:346-347`).
  - Attachments are a bridge HTTP call between the quota check and the history read (`runner.ts:287`).
  - `findSources` is not in the design's list at all.
- **FA26 gates.** Every workspace load carries a `mayTrain ?` gate: `runner.ts:287,311,323,329,334,346,362,364`. A refactor that drops one of them sends workspace data to a may-train model.
- **Pool.**
  - One pool of 10 serves every HTTP route of the process (`server.ts:157`, `db.ts:56`). The wait for a connection is capped at 5 s, then it throws (`db.ts:63`).
  - `fuse` holds a client for 4 statements (`retrieval/search.ts:286-298`). The embed runs before the connect (`search.ts:116-117`). No pre-flight loader holds a client across an HTTP call, and none acquires a second connection while holding one (checked: `budget.ts:71,142`, `rotate.ts:44`, `mcpClient/repo.ts:52`).
- **A throw in pre-flight leaves the run `running`.** The route's catch only releases the research slot (`routes/runs.ts:272-277`). The one-running-per-conversation index then answers 409 (`runner.ts:237-241`) until the 10-min sweep (`runner.ts:67`). This is pre-existing, and concurrency makes it more frequent.
- **History.** `pickHistoryWindow` skips rows that have no text without spending the budget (`runs/prompt.ts:108-119`). A row `LIMIT` is therefore not a character bound, and a cut there would set `dropped` wrong, which feeds the summary path (C384).
- **Stream ids and resume.**
  - The SSE frame id **is** the Redis stream id that XADD `*` returns (`runs/runStore.ts:40-55`, `runs/upstream.ts:88-91`). `writeSseFrame` requires an id (`http.ts:118-123`).
  - The client dedupes only frames that carry an id. A frame without one is appended to the text with no dedupe (`apps/osionos src/features/ai/model/runStream.ts:87-95`).
  - Resume reads Redis from any replica (`runStore.ts:6-8`), and `follow` already picks up entries that land later (`runStore.ts:120-148`).
  - So "frame first, flush later": the frame either has no id, and a resume replays text the client already appended (repeated tokens), or it needs an id from somewhere. "Flush before read on resume" cannot reach the process that runs the model from another replica.
- **The prompt layout is already cache-shaped.**
  - The system prompt is static and first, and is kept byte-stable on purpose (`runs/prompt.ts:32-50`, C389).
  - History comes next. Past user turns are replayed as their text parts only (`prompt.ts:68-76`).
  - **Every** dynamic block (account, view, workspace, summary, memories, pages, files, sources) already sits in the final user turn (`prompt.ts:435-458`, `upstream.ts:221-236`).
  - The recon's gap 5 ("dynamic blocks come before the stable ones", `prompt.ts:46-47`) points at the comment that says the opposite.
- **Ledger.**
  - A run row holds one `reserved_microusd` and one `model`.
  - Rotation is one transaction with a compare-and-set on `reserved_microusd = from.reserved` (`runs/rotate.ts:42-66`).
  - Loop extensions add to the same row (`runs/extend.ts:37`).
  - The sweep gives back only what the row records (`runs/repo.ts:163-182`).
  - Every public route today is an OpenRouter `:free` model on the shared platform key (`runs/quota.ts:36-43`, `groot/docker-compose.public.yml:159-162`).
- **Phase 0 storage.** `ai_runs.usage` is `jsonb`, nullable, with no check constraint (`groot/models/osionos-ai-migration.sql:62`). `markRun` replaces it whole with `coalesce($4::jsonb, usage)` (`runs/repo.ts:140-153`). It already carries `attempts` (C261, `runs/attempt.ts:140-150`). It is not returned to clients: the only owned-run reads are the owner check and the cancel (`routes/runs.ts:316,345`).
- **Catalog.** `expiresAt: Date.now() + CATALOG_TTL_SECONDS` puts seconds into a millisecond field, so the copy lives 86 s (`connections/catalog.ts:34,116,125`). The Redis copy lives 86,400 s (`catalog.ts:101`). If the copy taken from Redis lived a full day in memory, the maximum age would be 48 h, not 24 h.
- **Unknown when this was written:**
  - Where real run time goes. No phase timing exists (recon §5).
  - Live pg round-trip time from the host to the VM serve.
  - Redis append time per token (local container, unmeasured).
  - Whether any platform model reports cached input tokens.
  - Which routes, if any, have no per-day request cap. The OpenRouter free cap of 50/day per key is the design's figure, not verified here.

Each unknown is gated by a condition below, not assumed.

## Decision

### Scores (1–5; worst named)

| Part | Blast | Reversibility | Cost on failure | Confidence | Worst |
| --- | --- | --- | --- | --- | --- |
| Phase 0 | 2 | 1 | 2 (log privacy, quota spent by a bench) | 3 | — |
| Phase 1 | 4 (every run) | 1 | 4 (ACL bypass, FA26 leak, blocked conversations) | 3 | cost |
| Phase 2 | 3 | 1 | 3 (repeated/missing text on resume, silent stream holes) | 2 | conf |
| Phase 3 | 3 | 1 | 3 (injection posture, cache loss) | 1 (false premise) | conf |
| Phase 4a | 3 | 1 | 2 | 3 | — |
| Phase 4b hedging | 3 | 5 (a spent free request cannot be returned) | 4 (ledger leak, shared quota) | 1 | rev |
| Catalog TTL | 1 | 1 | 1 | 4 | — |

### Phase 0: PROCEED-WITH-CONDITIONS
- **AB1.** Marks use the monotonic clock and are integer ms:
  - `preflight_ms`;
  - `provider_ttft_ms`, the first **content** part as FA15 defines it, never `start`/`start-step`;
  - `stream_ms`, `attempts`, `failover_ms`;
  - `append_ms_total`, the summed awaited stream-append time. It gates Phase 2 (AB21);
  - `retrieval_failed` (boolean). It keeps Phase 1 from "winning" by losing retrieval, since `runner.ts:200-204` swallows the error.
- **AB2.** The marks live under one key `timing` inside `ai_runs.usage`, written by the **same** `markRun` call that writes `attempts`. Never a second UPDATE: it would race the coalesce replace. No migration. Test: a succeeded and a failed-over run keep `inputTokens`, `outputTokens`, `costMicroUsd` and `attempts` byte-identical, plus `timing`.
- **AB3.** The log gets a separate `run_timing` event. The request line at `server.ts:81` stays as it is. The event carries only:
  - the model menu id;
  - `platform` or `user`;
  - the outcome code;
  - the integers.

  It carries no user id, conversation id, run id, text, key or base URL (FA6, FA27). Test: the stdout of a test run contains neither the user id nor the run id.
- **AB4.** The baseline artifact records `preflight_ms` p50/p95, n ≥ 20, the stack, the commit and the command. `provider_ttft_ms` per platform model comes from **passive** live marks of real traffic, never from a bench on the platform key (`quota.ts:41`). A bench that sends prompts uses a BYO key with a spend cap (FB1), and its sign-in ends with `scripts/revoke-automation-sessions.sh --apply` (FB2).
- **AB5.** "Beats the baseline" is fixed before each phase ships: the same metric, the same stack, n ≥ 20 on both sides, paired, and a gain ≥ 3 %. A phase that does not beat it is reverted, not kept for later. Phase 0 lands alone and first.

### Phase 1: PROCEED-WITH-CONDITIONS
Membership read once per run is **acceptable**. The reason it was left uncached (C98: an hour-long token list) is not reopened by a read that is at most one pre-flight old and dies with the run. The tool path stays live. That holds only under AB6–AB8.
- **AB6.** The membership is read once, inside `startRun`, immediately before the parallel stage. That means after insert, rate limit, quota, the attachments (bridge HTTP, `runner.ts:287`) and the edit-and-resend delete, not in the route ahead of them. The route read (`routes/runs.ts:217`) is removed or becomes that single read. The array exists only in `startRun`'s frame and its call arguments: no module cache, no Redis, no reuse by another run or a continuation run.
- **AB7.** Tool calls keep calling `liveMemberWorkspaces` per call (`tools/readTools.ts:197`, `tools/writeTools.ts:207,240`, graph/view/list/builder tools). The run array is never put on the tool context. Test: delete the member row after `startRun` returns, then call `read_page` in that run. The tool denies.
- **AB8.** Equivalence test: a scoped token (C115) gets the same intersected list in every consumer the single read replaces.
- **AB9.** The stages are explicit in code, and the design's group (b) is corrected as follows:
  - history after the delete;
  - summary after history;
  - user context after skills;
  - the C340 refusal after skills and before money;
  - memory pins after memories;
  - `findSources` named in a stage.

  Tests: edit-and-resend never sends the edited-away text, and a C340 refusal leaves `reserved_microusd` at 0.
- **AB10.** FA26 survives the refactor. All eight `mayTrain` gates stay, and the FA26 captured-body test is green, **unchanged**, on the refactor commit.
- **AB11.** Pool bound: at most 3 concurrent queries per run, plus a process-wide cap of at most 6 concurrent pre-flight queries. That leaves at least 4 of the 10 connections for completing runs (`appendMessage`, `markRun`, `settleTarget`, `upstream.ts:317-361`) and tool reads.
  - Why: with 4 per run and no global cap, a tailnet stall (pg holding each query up to 5 s) exhausts the pool at 3 in-flight pre-flights instead of 10 today. Every other route then waits 5 s and fails.
  - Test, with a DB stub that holds every query 4 s: with 4 pre-flights waiting, a finishing run still marks and settles.
- **AB12.** A throw from any stage after `insertRun` marks the run `failed` before it propagates. The conversation is then not locked for 10 min. Test: a pool timeout injected into one loader leaves the next POST on that conversation not 409.
- **AB13.** The history bound is exact. Rows are read in newest-first keyset batches until `pickHistoryWindow`'s budget is spent or the rows run out. A plain row `LIMIT` is refused. Property test (fast-check: empty-text rows, continuation rows, rows over budget): `messages`, `oldestKeptId` and `dropped` are identical to the unbounded path.

### Phase 2: BLOCK as written
Frame first plus flush-on-resume either repeats tokens on resume or needs an id it does not have. The flush cannot be reached from another replica. Lift by meeting all of:
- **AB14.** A frame the client sees is already in the stream under that id.
  - Preferred: coalesce while a pipeline is in flight. The first delta into an idle buffer is appended at once. Deltas that arrive during a flush go into the next pipeline, and the frames are written after their ids return, in order. No resume change, no client change, and latency never worse than today's one RTT per token.
  - Allowed instead: monotonic explicit ids (`max(lastMs, now)-seq`), from one allocator per run, carried on the live frame.
  - A live frame without an id is refused.
- **AB15.** No "flush before read on resume" is built (`follow` already covers late entries).
- **AB16.** Barrier: every non-delta event waits for all earlier deltas to land before it is appended. That covers `route` (C260), `tool.called`, `tool.result`, permission, `usage`, `error` and `done`. `done`/`error` is never appended after a failed flush.
- **AB17.** A failed flush fails the run, as a failed awaited append does today (`upstream.ts:88-91`). It is never swallowed. Test: Redis refuses the 2nd pipeline. The run ends `error` and the stream holds no `done`.
- **AB18.** Test: resume after frame k, for every k, both with `Last-Event-ID` (follow) and from `''` (replay). The concatenated text arrives exactly once, with no loss and no repeat.
- **AB19.** The citation pipeline keeps the citation order and lands before the first delta.
- **AB20.** Each flush pipeline sets EXPIRE once and keeps `MAXLEN ~2000`. C402's gap check (`runStore.ts:102-111`) still reports on a trimmed research stream (existing test green).
- **AB21.** Build gate: Phase 2 is built only if Phase 0 shows `append_ms_total` ≥ 3 % of `stream_ms`, or ≥ 3 % of `provider_ttft_ms` p50. Redis is a local container, and per-token cost is likely sub-ms but unmeasured.

### Phase 3: BLOCK as written (false premise)
The dynamic blocks are already last. Reordering inside the final user turn moves no cacheable prefix. Moving the account, view or workspace block ahead of history makes every page create or rename invalidate the cached history. Moving it into the system role raises collaborator-controlled page titles into the instruction channel. Lift:
- **AB22.** No block leaves the final user turn, and nothing quoted moves into the system message. The C38 data-boundary line stays last in the system prompt.
- **AB23.** `cache_control` (or any cache hint) goes only to a provider that declares that wire (FA5). The mock captures the body per provider and proves no other provider receives it.
- **AB24.** Hints are built only with a before/after artifact, n ≥ 20 per model: provider-reported cached input tokens plus `provider_ttft_ms`. A provider that reports no cached tokens gets no hints.

### Phase 4a: measured rank: PROCEED-WITH-CONDITIONS
- **AB25.** Only the sort key changes. The no-train filter (FA23), the rest filter, provider-first diversity (FA12) and the chain size stay as they are (`runs/auto.ts:23-35`). The static rank (FA13's artifact) is the prior and the tie-break. The existing `autoChain` tests stay green, unchanged.
- **AB26.** What a sample is:
  - platform targets only, keyed by menu id (FA2);
  - TTFT is the first content part (FA15);
  - a failure is the failover allowlist plus the first-part timeout only. Cancel, 400, client disconnect, tool error and budget refusal never count.
- **AB27.** Poisoning bound: one user adds at most one sample per model per 60 s, the same posture as cooldown's two-user rule (`runs/cooldown.ts:29-31`). Test: 100 slow samples from one user leave the chain order unchanged.
- **AB28.** The score decays to the prior when samples stop, so a model that was demoted gets retried. If Redis errors or a key is missing, the static rank applies and the run never fails. The read joins the existing MGET in `autoChainFor` (`auto.ts:46-53`), with no extra round trip.
- **AB29.** FA18: a model whose measured p95 TTFT is above 90 s is never first.
- **AB30.** A `Caveat:` marker on the scorer names its wrong direction: a slow model stays first until enough users' samples move it, and a long prompt inflates TTFT.

### Phase 4b: hedged calls: BLOCK
- Two live attempts break the one-row ledger. The second reservation is either unrecorded, so a crash leaks it past the sweep (`repo.ts:163-182`), or it trips the rotation CAS when the other attempt extends (`rotate.ts:57`, `extend.ts:37`), and the run ends `stay`.
- "Never on a per-day-capped route" admits **zero** routes today, because all public routes are `:free` on the shared key.
- An aborted loser still spends a request upstream, and on a user connection it spends the user's money.
- **AB31.** Hedging is not built (`.out-of-scope/hedged-provider-calls.md`).
- **AB32.** To reopen, all of:
  - a ledger design where the row records every concurrent reservation, rotation and extension stay correct with two live attempts, and the sweep returns both;
  - a declared per-route field proving no per-day cap and not the shared key;
  - never on a user connection;
  - Phase 0 shows first-content-part stalls (> 8 s) on ≥ 5 % of runs over ≥ 7 days.

### Phase 4b′: adaptive first-part clock (alternative): PROCEED-WITH-CONDITIONS if chosen
It covers Goal 4 with one attempt at a time and no ledger change.
- **AB33.** Each attempt's first-part clock is `clamp(k × measured p95 first-content-part, floor, 90 s)`. Sequential failover is unchanged (FA19). FA15 (content part), FA16 (re-arm per step), FA17 (chain ≤ 150 s) and FA22 (a user-scope 60 s rest on that timeout) all hold. The floor is ≥ the measured p95 of the slowest reasoning model (FA18), so a thinker is not cut. Samples follow AB26–AB28. Test with the injectable clock: a stalled first model moves at the adaptive bound, not at 90 s.

### Small fixes
- **AB34.** Catalog TTL: multiply by `1000` on both lines (`catalog.ts:116,125`). The copy taken from Redis expires no later than the Redis key (its PTTL), or a `Caveat:` states the 48 h maximum age. Unit test with an injected clock. This ruling is the FB3 ruling for this fix only. Any other change in `connections/catalog.ts` comes back for one.

### Cross-cutting
- **AB35.** Each phase is its own commit, revertable alone, and lands behind tests plus `devil quality` with its AB5 artifact before it goes live.
- **AB36.** The earlier conditions that bind here, unrelaxed:
  - FA2 (menu-id keys);
  - FA5 (wire-specific body fields: AB23);
  - FA6 and FA27 (no secrets in logs: AB3);
  - FA11–FA13 (server Auto, diversity, measured prior: AB25);
  - FA15–FA18 (content-part clock, re-arm, chain bound, Nemotron: AB1, AB29, AB33);
  - FA19–FA22 (the failover rule unchanged, user-scope rest: AB33);
  - FA23 (may-train never auto: AB25);
  - FA26 (no workspace data to may-train: AB10);
  - FB1 and FB2 (BYO bench with a cap, revoke session: AB4);
  - FB3 (catalog fix ruling: AB34);
  - FC7 (the local model never public: Approach C).

  FA1, FA3, FA4, FA7–FA10, FA14, FA24, FA25, FA28, FA29, FB4–FB10 and FC1–FC6, FC8 are untouched by this design.

## Alternatives considered
- **B. Queue/worker rewrite.** Nothing measured asks for it. The mock knee is 140 concurrent runs (`load/RESULTS.md:48`), and there is one replica (`groot/infrastructure/tls/nginx.conf:179`). Its cost: a new process boundary and a new admission protocol, with no baseline to beat. Deferred until Phase 0 shows a pool or CPU knee under real traffic.
- **C. Local GPU primary.** It saturates at 1 req/s, with TTFT p50 21 s at that rate (`spikes/gpu/RESULTS.md:36`). FC7 keeps it dev-only.
- **Unbounded `Promise.all` (the design's group (b) at about 11 queries).** It exhausts the pool at 3 runs during a DB stall. Rejected for AB11.
- **Row `LIMIT` on history.** It changes `dropped` and the window when rows carry no text. Rejected for AB13.
- **Frame first plus flush-on-resume.** It repeats tokens or needs ids it lacks, and it cannot reach another replica. Rejected for AB14.
- **Hedging.** It double-books the one-row ledger and has no eligible public route. Rejected. The adaptive clock (AB33) reaches the same goal with one attempt at a time.

## Consequences
- Phase 0 decides everything after it. Phase 2, the cache hints and any hedging reopen only on its numbers (AB21, AB24, AB32).
- Membership freshness becomes "as of the run's pre-flight" for pre-flight reads and stays "per call" for tools. The window is the pre-flight duration, recorded in `preflight_ms`.
- Phase 1 must not lose retrieval to pool timeouts unseen: `retrieval_failed` is the guard (AB1).
- Conditions: AB1–AB36. They become the builder's acceptance criteria.
