# DRAFT. The free-model pool keeps its models out of the legacy allowlist, proves zero cost and data use per provider, and fails over on the timeout rule that already exists; MCP opens read-only behind all three locks; the local GPU model stays dev-only

- Status: proposed (draft, unnumbered). devil, per part: A1 A2 A3 A4 A6 A7 PROCEED-WITH-CONDITIONS · A5 BLOCK as written (lift: FA19–FA22) · B1 B2 PROCEED-WITH-CONDITIONS · C1–C4 PROCEED-WITH-CONDITIONS, dev only.
- Date: 2026-11-21
- Deciders: devil (ruling); the osionos-ai builder and the operator (live with it)
- Design: `docs/superpowers/specs/2026-11-21-more-free-ai-design.md` (C section as corrected 2026-11-21: llama.cpp Vulkan, no Ollama)

## Context

Paths are under `apps/osionos/app/services/osionos-ai/src/` unless they say otherwise.

- One platform handle, named `platform`, with no `fetch` guard and OpenRouter's two headers on every call (`gateway/platform.ts:28-38`). Every platform target gets `optionsKey: 'platform'` (`gateway/resolve.ts:184-199`). The effort option sent under that key is OpenRouter's `reasoning: { effort }` shape (`runs/effort.ts:47-52`). A platform vision call adds OpenRouter's `provider: { data_collection: 'deny' }` (`runs/attempt.ts:91-93`). Both are OpenRouter body fields. Another provider ignores them, or answers 400, and a 400 ends the run (`runs/failover.ts:6-9,78`).
- The model schema is a plain `z.object`, and zod 4.6.7 strips unknown keys (`platformModels.ts:24-32`, `package.json` `"zod": "4.6.7"`). An image from before A1 that reads an entry with `provider: "groq"` drops the field and sends the model id to OpenRouter with the platform key. Groq's `openai/gpt-oss-120b` id is also a **paid** OpenRouter id. The run would then spend real money while the ledger books it at 0/0.
- Model ids must be unique across the whole allowlist (`platformModels.ts:42-44`). The same upstream model on two providers therefore needs a menu id that differs from the id sent upstream.
- The service has no "public mode" signal. The public overlay only pins env values (`docker-compose.public.yml:166-168`), and `config.ts` has no public flag (`grep -n -i public src/config.ts`: comments only).
- The public list today: 4 entries, all 0/0, default `nvidia/nemotron-3-ultra-550b-a55b:free`, and no entry has `reasoning: true` (`.env.public` `OSIONOS_AI_PUBLIC_PLATFORM_MODELS`; ids and prices read, key not printed). No `OSIONOS_AI_KEY_*` is set in `.env.public` or `.env.local` (count 0 in each).
- **A timeout already fails over.** When the attempt's own clock aborts, no part was emitted and another model is waiting, the run moves on as `unavailable`, booked at the estimate (`runs/attempt.ts:110-115`, commit 4153b653b, "devil C249, C252"). The header of `runs/failover.ts:6-9` says a timeout ends the run. That is true of `classifyFailure` alone, not of the run. The design's fact "A timeout ends the run" (spec line 42) is wrong. The run ends because the default user sends **no fallbacks**: `hasNext` is false (`runs/attempt.ts:107`), and fallbacks exist only when the user picked them (`src/features/ai/model/aiSelection.ts:35`). No test drives a stalled upstream into a `route` event (`grep -n -i timeout tests/failover*.ts`: only the C252 abort-isolation unit, `tests/failoverUnits.test.ts:73`).
- A timed-out attempt never rests its model (`runs/cooldown.ts:72,101`, C256). The platform rest needs 3 failures from 2 users within 30 s (`runs/cooldown.ts:29-31`). With 90 s per attempt, that window can never fill from timeouts.
- `touch()` resets the idle clock on **every** stream part (`runs/streamPump.ts:240-243,272`), including the SDK's `start` / `start-step` frames. The 30 s that kills a silent thinker runs from the last such frame.
- Pricing of a user connection is always 0/0 in our ledger (`gateway/resolve.ts:225`). "Zero-price" by itself does not identify the platform.
- The edge has two locks on MCP in public, not one: `location ^~ /api/ai/access-tokens { … return 404; }` and `location ^~ /api/ai/mcp { return 404; }` (`infrastructure/tls/public.d/bridge-public.conf:20-33`), plus `OSIONOS_AI_PAT: ""` (`docker-compose.public.yml:140`). The MCP host allowlist defaults to loopback only (`config.ts:528`), and the public overlay does not set it.
- `/api/ai/` is served on the API (:4000) server (`infrastructure/tls/nginx.conf:178`). On `:8443`, `/api/*` answers 200 text/html (the SPA), measured 2026-10-30 (memory `osionos-live-probe-traps`). The design's MCP URL `https://<public origin>:8443/api/ai/mcp` is the wrong origin.
- PAT tokens are sha256-hashed, scoped (`read`, `write_approval`), limited to a list of workspaces, valid 1–365 days, and resolved on every request with no cache (`pat/token.ts:48-54`, `routes/accessTokens.ts:48-50`, `pat/repo.ts:81-87`). The MCP lane allows 4 calls at once with a queue of 16 (`mcp/lane.ts`). There is a per-token rate limit (`routes/mcp.ts:46`).
- The GPU spike, config 2 (`-np 1 -c 2816 -fa on`, f16 KV), peaked at 7.27–7.28 GiB **total card** VRAM. The desktop share at that moment is not recorded, and over the spike it ranged 1.8–5.3 GiB. TTFT p50 was 1.26 s at 0.25 req/s and 21.2 s at 1 req/s (`spikes/gpu/RESULTS.md:20,34-37`; `spikes/gpu/run-part-a.sh:219`). The dev service runs `-c 8192` (`docker-compose.yml:552-571`). Config 2 was **not** measured at 8192. Assuming Qwen3-4B has 36 layers, 8 KV heads and head dim 128, an f16 KV cache costs about 0.15 MB per token, so 8192 tokens cost about 0.8 GB more than 2816. That is an estimate, not a measurement.
- The spike passed the whole `/dev/dri` to the container (`spikes/gpu/try-llm.sh:17`). The host has `card1` (display, group video) and `renderD128` (group render, gid 993) (`ls -l /dev/dri`).
- `ghcr.io/ggml-org/llama.cpp:server-vulkan-b11580` is local: created 2026-10-13, repo digest `sha256:ee2ecb9c3a4d6fa00b918b133fd7a2828195593688eeaef6e6516ef833f88f09` (`docker image inspect`).
- The public overlay moves `osionos-ai-llm` to the `ai-dev-only` profile (`docker-compose.public.yml:210-211`).
- Unknown when this was written:
  - whether each provider key can incur a charge (a card on the Groq, Google, Cloudflare or NVIDIA account; credits on the OpenRouter key);
  - each provider's and each `:free` endpoint's data-use policy, including the 4 OpenRouter models in use now;
  - whether `@ai-sdk/openai-compatible` 3.0.68 maps OpenRouter's `reasoning` delta to `reasoning-delta`;
  - Nemotron's real time to the first content part;
  - whether the live grobase DB holds the PAT schema (`ai_access_token_resolve`; no migration found by `rg` in services/, grobase/ or models/);
  - the VRAM the LLM itself uses at the context the service needs, and what llama.cpp Vulkan does when VRAM is short (fails to start, spills to host memory, or disturbs the desktop);
  - the NVIDIA build trial terms for a production multi-user service.

  Each is a condition below, not an assumption.

## Decision

### A — provider pool

**A1 Providers — PROCEED-WITH-CONDITIONS.** Blast 3 · Reversibility 3 (env revert is one step, but an old image reading the new env is a hazard) · Cost on failure 4 (real money unseen by the ledger, or a secret sent to an operator-chosen URL) · Confidence 3.
- FA1. Pool models are declared outside `OSIONOS_AI_PLATFORM_MODELS`, for example inside each `OSIONOS_AI_PLATFORM_PROVIDERS` entry. An image from before A1 then never sees them. `OSIONOS_AI_PLATFORM_MODELS` keeps legacy-upstream entries only. Test: decoding both vars yields one default and unique menu ids across the union, and an old-shape var stays byte-identical in behaviour.
- FA2. A pool entry carries a menu `id` and a separate `upstreamId`. The cooldown key uses the menu id. Test: the same `upstreamId` on two providers gives two menu ids and two independent rests.
- FA3. Boot refuses any `apiKeyEnv` not matching `^OSIONOS_AI_KEY_[A-Z0-9_]+$`. Test: `apiKeyEnv: "OSIONOS_AI_KEK"` and `"OSIONOS_AI_DATABASE_URL"` both refuse to boot.
- FA4. Boot refuses a `baseUrl` that is not `https:`, except a host on the compose network named in the config (the dev `osionos-ai-llm`). Test: `http://example.com/v1` refuses.
- FA5. The OpenRouter body fields (`provider.data_collection`, `reasoning: {effort}`) and the `HTTP-Referer` / `X-Title` headers go only to a provider that declares the OpenRouter wire. Every other provider gets the generic `reasoningEffort` or nothing. Test: capture the upstream body per provider in the mock and check it.
- FA6. The boot log names a dropped provider by id only. Test: the key value is not in stdout or stderr.
- FA7. The public overlay pins `OSIONOS_AI_PLATFORM_PROVIDERS` in `environment:` from `.env.public` (`${…:-}` or `:?`), so `.env.local` cannot add providers to public. `scripts/verify/ai-public-flags-off.sh` (or a sibling) checks this.

**A2 Zero-price boot refusal — PROCEED-WITH-CONDITIONS.** Blast 3 · Rev 2 · Cost 4 · Conf 2.
- FA8. Public mode is an explicit signal pinned in the public overlay `environment:` (for example `OSIONOS_AI_PUBLIC_MODE: "on"`), never inferred. With it on, boot refuses any non-zero price in either var. Test: one non-zero entry refuses to boot; the same entry with public mode off boots.
- FA9. This amends R-C10 ("OpenRouter zero-price models only") by name. The amendment is recorded in the ADR that lands A1/A2, not as "its spirit".
- FA10. Zero in our config is not zero upstream. A provider joins the public list only after a dated record in this ADR, per provider, of the evidence that its key cannot be charged: no payment method on the account, or a hard spend cap of 0. For OpenRouter, the key's credit limit (via `GET /api/v1/key`; print only `limit` and `usage`). A provider without that record stays out of public.

**A3 Auto + rank — PROCEED-WITH-CONDITIONS.** Blast 3 · Rev 1 · Cost 3 · Conf 3.
- FA11. Auto is resolved on the **server** (`model: "auto"` or no model), from `rank` and the existing rest filter. The client does not assemble the chain. The may-train exclusion (FA23) is then a server fact, not a client promise. A user's own explicit fallbacks still win.
- FA12. With fewer than 3 usable providers, Auto fills the remaining slots with other models of the same provider (distinct menu ids). Other providers come first. Test: an OpenRouter-only config gives a chain of 3, not 1. Today's config is OpenRouter-only. Without this, Auto ships with no fallback, and the reported bug stays.
- FA13. The initial `rank` comes from a measured artifact: n ≥ 20 runs per model of time to the first content part, success rate and tok/s, with the command that reproduced it. It is not chosen by hand.
- FA14. `GET /api/ai/models` adds `rank` and `dataUse` and still never returns prices, base URLs or key names. Test: a snapshot of the response keys.

**A4 First-part 90 s clock — PROCEED-WITH-CONDITIONS.** Blast 3 · Rev 1 · Cost 2 · Conf 2.
- FA15. A "part" for this clock is a **content** part: `text-delta`, `reasoning-delta`, `tool-input-start` or `tool-call`. `start`, `start-step`, `raw` and metadata frames do not end the 90 s. Test: a mock that sends `start-step` and then 60 s of silence survives. Without this, A4 changes nothing (`streamPump.ts:272`).
- FA16. The first-part clock re-arms at every `start-step` until that step's first content part. A silent thinker after a tool result is then not killed by the 30 s idle clock with text already emitted, where no failover can help. Test with an injectable clock.
- FA17. The time a chain waits before its first content part is bounded across attempts, not only per attempt. The proposed bound is ≤ 150 s: attempt n gets min(90 s, what is left). A test asserts the bound for a chain of 3 stalled targets. Unbounded, 3 × 90 s is 270 s of spinner.
- FA18. Before ship, measure Nemotron's time to the first content part (FA13's artifact), and check whether the SDK surfaces its reasoning as `reasoning-delta`. If its p95 exceeds 90 s, it is not ranked first.

**A5 Timeout failover for zero-price nothing-emitted targets — BLOCK as written.** Blast 3 · Rev 1 · Cost 3 · Conf 1 (the premise is false).
The rule it asks for already exists for every target (`runs/attempt.ts:110-115`). As written, A5 would remove timeout failover from user connections and paid targets ("keeps today's behaviour: the run ends"). That is a regression built on a misread. The billing change from `estimate` to `none` changes nothing at a price of 0/0. Lift by replacing A5 with:
- FA19. No change to the failover rule or to C249. Fix the misleading header at `runs/failover.ts:6-9`: it lists "a timeout" among the failures that end the run. Say that a timed-out attempt is moved by `failoverClassOf`, and that `classifyFailure` alone does not move it.
- FA20. Add the missing integration test: a mock that stalls with nothing emitted → a `route` event with reason `unavailable` → the next model answers. For a 0/0 target, `attempts[0].billed === 0`.
- FA21. G2 is reached through FA11/FA12, because Auto supplies the fallbacks. Live proof: a run on a forced-stall primary ends `done` on the fallback.
- FA22. A first-part timeout of a platform attempt rests that model **for that user only** (scope `user:`, 60 s). Platform scope is unchanged. This amends C256 for the user scope only. Without it, every run of that user waits 90 s again on the same stalled first-ranked model. Test: a second run within 60 s skips the stalled model.

**A6 may-train label / never default / never auto-fallback — PROCEED-WITH-CONDITIONS.** Blast 4 (pages of a whole workspace) · Rev 5 (a prompt sent to a training provider cannot be recalled) · Cost 4 · Conf 2.
- FA23. Server-side, not client-side: boot refuses `default` on a may-train model; the run route refuses a may-train model in `fallbacks` (400, one code); Auto never selects one. Test for each of the three.
- FA24. A model's `dataUse` comes from the provider's published policy, recorded in this ADR with URL and date. **Unknown is `may-train`.** This also covers the 4 OpenRouter `:free` models in use now: several free endpoints log prompts, and the current text calls send no data-collection deny (`runs/attempt.ts:91-93` adds it to vision calls only). If no public model qualifies as no-train, boot refuses (FA23) and the operator decides. Do not relabel a model to get past the check.
- FA25. An OpenRouter model labelled `no-train` gets `provider: { data_collection: 'deny' }` on **every** call, not only vision calls. The label is then enforced on the wire. Test: the captured body.
- FA26. A run on a may-train target sends no page context, workspace retrieval, attachments or memories, either in this turn or in replayed turns. Either refuse the run (400, one code), or the user starts a fresh conversation. Test: capture the upstream body for a conversation that earlier cited pages.

**A7 Operator keys — PROCEED-WITH-CONDITIONS.** Blast 2 · Rev 2 (a leaked key must be rotated at the provider) · Cost 3 · Conf 3.
- FA27. Keys are sign-ups done by the account owner. They go in `.env.public` / `.env.local` (mode 600) as `OSIONOS_AI_KEY_<PROVIDER>`. They are never written in a commit, an argv or a log. `devil preflight` reports names and set/unset only.
- FA28. One script under `scripts/` lists `GET /models` per provider and prints **ids only**, with the key read from the env and never echoed. Its output, with the date, goes in the PR.
- FA29. Before a provider joins public, its terms allow serving a multi-user production app on that key. The NVIDIA build trial and the opencode zen free tier are named as unknown. The answer is recorded with URL and date. A provider without it stays dev-only.

### B — bring your own AI

**B1 BYO key live verify — PROCEED-WITH-CONDITIONS.** Blast 2 · Rev 1 · Cost 2 · Conf 3.
- FB1. The live test uses the user's own key on an account with a spend cap. The connection is deleted after the test, and the deletion is checked (GET lists it no more).
- FB2. The probe's sign-in ends with `scripts/revoke-automation-sessions.sh --apply` (memory `live-probes-revoke-own-session`), never a bridge logout.
- FB3. "Fix whatever fails": a fix touching `connections/crypto.ts`, `connections/endpointGuard.ts`, the KEK or the catalog comes back for a ruling before it merges. Any other fix ships with a failing-then-passing test.

**B2 PAT on in public + MCP from Claude Code — PROCEED-WITH-CONDITIONS.** Blast 3 (the read scope reaches every page the owner can read in the listed workspaces) · Rev 2 (a token read by a third party cannot be recalled; revocation is immediate) · Cost 4 · Conf 3.
- FB4. All three locks move in **one** change: `OSIONOS_AI_PAT: "on"` and the two `return 404` locations in `infrastructure/tls/public.d/bridge-public.conf:20-33`. The locked-CORS map is kept for the panel. `scripts/verify/ai-public-flags-off.sh` is updated in that same change, so the gate states the new truth.
- FB5. `OSIONOS_AI_MCP_ALLOWED_HOSTS` is pinned in the public overlay `environment:` to the public API host. `OSIONOS_AI_MCP_ALLOWED_ORIGINS` stays empty. Test against the deployed host: a request with any `Origin` gets 403 `origin_not_allowed`; a foreign Host gets `host_not_allowed`.
- FB6. The documented URL is the **API origin** (the public `VITE_API_URL`, :4000 path through Funnel), not `:8443`. That `:8443/api/*` serves the SPA was measured 2026-10-30. The doc example is pasted from the live probe's output.
- FB7. Before the flag: a read-only query on the live DB proves that `public.ai_access_token_resolve` exists and that the `osionos_ai` role may execute it. The output goes in the PR.
- FB8. Public mints `read` only in this phase. `write_approval` waits for a live approve-and-deny e2e of an MCP proposal (C117, C227 unchanged). Test: a public mint with `write_approval` returns 400.
- FB9. The live check uses a token with `expiresInDays: 1` and one workspace. One `tools/call` read from Claude Code succeeds. Then revoke the token, and the same request returns 401. The 401 output goes in the PR. The token value is never printed or committed.
- FB10. Before the flag, the existing suites pass on the commit that flips it: `mcpAccess`, `mcpTools`, `mcpApprovals`, `mcpFlagOff`, `accessTokens` and `accessTokensOff`.

### C — local model (corrected design: llama.cpp Vulkan, `osionos-ai-llm`)

**C1–C4 — PROCEED-WITH-CONDITIONS, dev only.** Blast 2 (dev stack and the user's desktop session) · Rev 1 (the override is a file) · Cost 3 (a VRAM squeeze can disturb the desktop that shares the card) · Conf 2 (config 2 was measured at 2816 context, the service needs 8192).
- FC1. The override is opt-in (a separate compose file or profile). The default `docker compose up` on a GPU-less host is byte-identical in its rendered config (`docker compose config` diff empty without the override).
- FC2. The image is pinned by digest: `ghcr.io/ggml-org/llama.cpp:server-vulkan-b11580@sha256:ee2ecb9c3a4d6fa00b918b133fd7a2828195593688eeaef6e6516ef833f88f09`.
- FC3. Pass only `/dev/dri/renderD128` with `group_add: ["993"]` (render), not the whole `/dev/dri` and not `card1` (the display node). Proof: Vulkan device enumeration in the container log with only that node.
- FC4. Measure again at the context the service needs. The config is `-ngl 99 -np 1 -fa on` with the `-c` that fits the real system prompt plus tools plus 3 page contexts plus `maxOutputTokens` 1024 (`config.ts:43`). The run records the LLM container's **own** VRAM (per-process, not card total) and the card total with the desktop at its high share (≥ 5 GiB). The card total stays ≤ 7.4 GiB, or `-c`/KV type is lowered until it does. Spike config 2 at `-c 2816` is not evidence for `-c 8192`.
- FC5. Record what happens when VRAM is short: start the container with the desktop holding ≥ 5.3 GiB. The pass condition is a clean refusal or a bounded spill with the desktop unharmed. The override uses `restart: on-failure:3`, not `unless-stopped`, so a load failure cannot loop on the GPU.
- FC6. C4 reuses `spikes/gpu/llm-bench-gpu.mjs` / `run-part-a.sh` by moving them into `scripts/`. No second benchmark is written. Output: TTFT p50/p95, ITL p95, tok/s and VRAM, with the command.
- FC7. The `local` provider is not in any public provider list. A public verify asserts that no provider `baseUrl` names `osionos-ai-llm` or another compose-internal host. Putting it in public needs its own ruling. At 1 req/s, TTFT p50 was 21 s (`RESULTS.md:36`). When the cloud quotas run out, the floor gets every user at once.
- FC8. The llama server stays unpublished (`ports` empty) and has no host port. Test: `docker compose port osionos-ai-llm 8080` prints nothing.

## Alternatives considered

- **Platform models stay in `OSIONOS_AI_PLATFORM_MODELS` with a `provider` field (the design)**: an image from before A1 strips the field (`platformModels.ts:24`, zod strip) and sends the id to OpenRouter with the platform key. A colliding paid id spends money the ledger books at 0. Rejected for FA1.
- **Client-built Auto chain (the design)**: the may-train exclusion would be a client promise, which a bug or an old cached bundle breaks silently. A server-resolved `auto` costs one branch in `resolveTarget`. Rejected for FA11.
- **Narrow timeout failover to zero-price (A5)**: removes an existing, working move from user connections. Rejected.
- **Spike config 3 (np4, q4 KV) for the local model**: better under load (TTFT p95 6.95 s at 0.5 req/s), but ITL p95 1.24 s at 1 req/s. It is a dev box serving one person, so config 2's latency wins, provided FC4 holds at the real context.
- **Ollama ROCm (original C)**: withdrawn by the design itself: a new dependency (rung 6) where an existing image works (rung 4).

## Consequences

- G2 is met by Auto supplying fallbacks (FA11/FA12) and by the content-part clock (FA15/FA16), not by a failover rule change. Whoever lands A3 is responsible for FA20's test.
- The anti-goal "a private page silently sent to a free tier that trains" is enforced on the server (FA23, FA24, FA25, FA26). The cost: public may have no no-train default until the operator finds one. That trade-off is deliberate.
- R-C10 is amended by name (FA9), and C256 for the user scope only (FA22). C227, C249, C254/C255 and C288 are unchanged.
- B2 opens one internet-facing, read-only route with hashed, expiring, revocable tokens. `write_approval` in public is a later ruling (FB8).
- The local GPU model is a dev convenience and the user's desktop shares its card. It reaches public only through a new ruling (FC7).
- Conditions: FA1–FA29, FB1–FB10, FC1–FC8. They become the builder's acceptance criteria.

## Records

R-C10 ("OpenRouter zero-price models only") is amended by name (FA9): the public platform list may hold zero-price models of any provider that has a complete row below. A row is complete only when all three columns carry a source and a date. An empty cell keeps the provider out of public. Today no row is complete, so `OSIONOS_AI_PUBLIC_PLATFORM_PROVIDERS` stays empty and `docker-compose.public.yml` pins no `OSIONOS_AI_KEY_*` (`scripts/verify/ai-public-providers.sh`).

The provider ids are the ones the design names (`docs/superpowers/specs/2026-11-21-more-free-ai-design.md`, "Free tiers"). The live key checks that would fill the first column are Task 12; nothing here was measured or browsed.

| Provider | Charge evidence, date (FA10) | Data-use policy URL, date (FA24) | Multi-user production terms URL, date (FA29) |
|---|---|---|---|
| openrouter | `GET /api/v1/key` on the live public key, 2026-11-21T03:47Z: usage 0, `is_free_tier` true | <https://openrouter.ai/docs/features/provider-routing>, read 2026-11-21: `data_collection: "deny"` = "use only providers which do not collect user data"; wire check 2026-11-21T03:47Z (16-token chat, deny on): 200 for `openrouter/free`, `baidu/ernie-5.5-flash-preview:free`, `recursive/flint-v1.0:free`, `dots-studio/dots-3-note-preview:free`; 404 "No endpoints found matching your data policy" for every `nvidia/nemotron-*:free` | |
| groq | | | |
| gemini | | | |
| nvidia | | | |
| cloudflare | | | |
| opencode | | | |

**Public default, recorded 2026-11-21 (FA23–FA25, ledger R39 C1).** The public list's default is `openrouter/free`, with `baidu/ernie-5.5-flash-preview:free` and `recursive/flint-v1.0:free` behind it. All three carry `"dataUse":"no-train"`, and every call sends `data_collection: "deny"` (FA25). Nemotron leaves the public list: no endpoint of it accepts deny. The `openrouter` row above has the FA24 column only. Its FA29 cell stays empty, so the row is not complete and `openrouter` is not added to `OSIONOS_AI_PUBLIC_PLATFORM_PROVIDERS`. The default reaches OpenRouter through the existing upstream (R-C10).

Caveat: the label covers the upstream providers only. The OpenRouter docs read on 2026-11-21 do not say what OpenRouter itself keeps of a prompt ("This setting has no bearing on OpenRouter's own policies"). `openrouter/free` picks its provider per call, so a deny-compatible answer today does not pin which provider answers tomorrow. Deny still filters each call.
