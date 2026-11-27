# More and better AI for free — design (A pool, B bring-your-own, C local)

Date: 2026-11-21 · Scope: `apps/osionos/app/services/osionos-ai`, the chat model menu,
`docker-compose*.yml` · Status: user chose "A until C, all steps verified" (2026-11-21).
Ruling: `docs/adr/DRAFT-more-free-ai-ruling.md` (devil, 2026-11-21). Its conditions FA1–FA29,
FB1–FB10 and FC1–FC8 are acceptance criteria. Where this document and the ruling disagree, the
ruling wins. The sections below were corrected to match it on 2026-11-21.

## Why

The assistant has 4 free OpenRouter models. The default one (Nemotron 3 Ultra) thinks silently,
and the service drops a run after 30 s with no streamed part (`runs/streamPump.ts:25`). The user
saw "The model took too long — try again" twice in a row, and wants more models, faster ones and
smarter ones, without paying per user.

## Goals

- G1. More free models from several providers, so one provider's limit or outage does not stop chat.
- G2. A run does not die while a model is still thinking, and moves to another model when the first stalls.
- G3. Anyone can use the best model they already pay for: their own key, or Claude/ChatGPT reaching
  osionos over MCP.
- G4. A local model on this host's GPU that needs no key and sends nothing out.

## Non-goals

- What the assistant may write (tables, cover, icon, properties, delete). That is project 2,
  together with the ABAC rules. It gets its own design and ruling.
- The connector marketplace and user-added integrations. That is project 3.
- Paid models on the platform key. The platform stays zero-price (R-C10's spirit).

## Anti-goals

- A key, a prompt or a page reaching a provider the user did not choose or the operator did not list.
- A private page silently sent to a free tier that trains on prompts.
- Failover that bills twice or hides a real error such as a 400 or a 401.

## Facts (2026-11-21)

- One platform upstream: `OSIONOS_AI_UPSTREAM_BASE_URL` + `_API_KEY` (`gateway/platform.ts:26-40`).
  Public mode pins it to OpenRouter's zero-price models (`docker-compose.public.yml:166-168`).
- Failover exists: on 429 or 5xx only, with nothing emitted yet (`runs/failover.ts`, C249). The
  client names at most 2 fallbacks (`routes/runs.ts:50`). These are kept in localStorage
  `osionos.ai.fallbacks.v1` (`src/features/ai/model/aiSelection.ts:35`). Failing models rest
  60–300 s (`runs/cooldown.ts`).
- Timeouts: 30 s idle, 2 min total (`streamPump.ts:25-27`). A timed-out attempt with nothing
  emitted already moves to the next model (`runs/attempt.ts:107-115`). The run ends only because
  the default user sends no fallbacks.
- The idle clock is reset by every stream part, including the SDK's `start` / `start-step`
  frames (`streamPump.ts:272`).
- Bring-your-own-key: 9 providers (`connections/providers.ts`), with keys encrypted under the KEK.
- MCP server with personal access tokens: built (`mcp/`, `pat/`), but `OSIONOS_AI_PAT: ""` in public.
- Host: Radeon RX 6600 (8 GB, gfx1032), `/dev/kfd` present, 31 GB RAM, 20 threads.
- Free tiers, late 2026 (web, cited in the conversation):

  | Provider | Free model | Limit |
  |---|---|---|
  | Groq | gpt-oss-120b | about 30 RPM / 1k RPD |
  | Gemini AI Studio | Flash models | limits not published; prompts may be used for training |
  | NVIDIA NIM | Nemotron | about 40 RPM |
  | Cloudflare Workers AI | — | 10k neurons/day |
  | OpenRouter | 17 `:free` models | — |
  | opencode zen | free models | — |

  GitHub Models, Cerebras and the Mistral free API are gone.

## Approaches considered

- **A. Free-provider pool with failover:** chosen.
- **B. Bring your own AI:** chosen as the upgrade path.
- **C. Local models:** chosen. It is the no-key, no-egress floor.

The user asked for all three, in order. Single-provider with longer timeouts only was rejected,
because it does not fix G1.

## Design

### A — provider pool

- **A1. Providers.** A new optional env var, `OSIONOS_AI_PLATFORM_PROVIDERS`: a JSON list of
  `{id, baseUrl, apiKeyEnv?, wire: "openrouter" | "openai-compatible", models: [...]}`.
  - Pool models live inside their provider entry, never in `OSIONOS_AI_PLATFORM_MODELS` (FA1):
    an image from before A1 then never sees them. Each carries a menu `id`, an `upstreamId`,
    `dataUse` and the usual price fields (FA2).
  - `OSIONOS_AI_PLATFORM_MODELS` keeps the legacy upstream only, so old config runs unchanged.
  - The key is read from the env var named by `apiKeyEnv`, never inline in the JSON. The name
    must match `^OSIONOS_AI_KEY_[A-Z0-9_]+$`, and `baseUrl` must be https (FA3, FA4).
  - A provider with an unset key is dropped at boot, and so are its models. The log line names
    the provider only.
  - `gateway/platform.ts` keeps one `createOpenAICompatible` handle per provider.
  - OpenRouter's headers and body fields (`reasoning`, `provider.data_collection`) go only to a
    provider with `wire: "openrouter"` (FA5).
- **A2. Zero price stays the rule on public.** Every pool model is listed at 0/0 µUSD. The boot
  check refuses a non-zero entry when `OSIONOS_AI_PUBLIC_MODE=on`, pinned by the public overlay
  (FA8). A provider joins public only with dated proof that its key cannot be charged (FA10). The prices of the platform budget are
  therefore unchanged.
- **A3. "Auto" in the model menu.**
  - It is the default for a user who never picked a model.
  - The **server** resolves it (`model: "auto"` or no model, FA11): the best-ranked model that is
    not resting, plus up to 2 fallbacks, other providers first, then other models of the same
    provider (FA12). It never picks a `may-train` model.
  - `rank` comes from a measured run, n ≥ 20 per model (FA13). `GET /api/ai/models` adds `rank`
    and `dataUse`, never prices, URLs or key names (FA14).
  - A user's own fallback choice still wins.
- **A4. Thinking time.**
  - The time to the first **content** part (`text-delta`, `reasoning-delta`, `tool-input-start`,
    `tool-call`) gets its own clock: `FIRST_PART_TIMEOUT_MS = 90_000` (FA15). It re-arms at each
    `start-step` (FA16). A chain waits at most 150 s in total for its first content part (FA17).
  - After the first part, the idle limit stays 30 s.
  - A reasoning model that streams `reasoning-delta` already resets the idle clock. One that
    thinks silently gets the 90 s.
  - The total clock stays at 2 min.
- **A5. A timeout fails over** — it already does (BLOCKED as first written, replaced by FA19–FA22):
  - fix the misleading header of `runs/failover.ts:6-9`; no rule change;
  - add the missing integration test: a stall moves the run to the next model, `billed === 0`;
  - a first-part timeout rests that model for that user only, 60 s (amends C256, user scope).
- **A6. Privacy label.**
  - `may-train` models show "may use prompts for training" in the menu.
  - The server enforces it: never `default` (refused at boot), a 400 as a fallback, never picked
    by Auto (FA23). Unknown data use counts as `may-train` (FA24).
  - OpenRouter `no-train` models send `data_collection: 'deny'` on every call (FA25).
  - The user may still pick one by hand, but that run sends no pages, workspace, attachments or
    memories (FA26).
- **A7. Keys.**
  - The operator gets the free keys (Groq, Google AI Studio, NVIDIA build, Cloudflare,
    opencode) and puts them in `.env.public` / `.env.local` under `OSIONOS_AI_KEY_<PROVIDER>`.
    These are sign-ups only the account owner can do.
  - Real model ids are checked against each provider's `GET /models` before they go in the list.

### B — bring your own AI

- **B1.** Per-user keys already work. Verify live, end to end: add a key in Settings → AI, then
  run a chat on it. Fix whatever fails.
- **B2. Claude / ChatGPT over MCP.**
  - Turn `OSIONOS_AI_PAT` on in public together with both nginx 404 locks, in one change (FB4).
  - Document how to create a token with `read` scope; public mints `read` only for now (FB8).
  - Document how to add `https://<public API origin>/api/ai/mcp` to Claude Code / Claude Desktop.
    That is the API origin, not `:8443`, which serves the SPA for `/api/*` (FB6).
  - Verify one read tool call from Claude Code end to end, then revoke the test token.
  - Writes stay approval-only (C227 unchanged).

### C — local model

- **C1. Reuse what exists, on the GPU.** No Ollama: rungs 4–5 beat a new dependency.
  - Dev already runs `osionos-ai-llm` (`docker-compose.yml:552`) with llama.cpp `server-b11580`,
    Qwen3-4B-Instruct Q4_K_M, on the CPU.
  - The spike `services/osionos-ai/spikes/gpu/RESULTS.md` (2026-10-21) measured that on this host.
    On the CPU the first token took 57–84 s at about 1 tok/s. With Vulkan (`server-vulkan-b11580`,
    already pulled) it took 1.3 s, with 16 ms between tokens (about 60 tok/s for one stream).
  - C1 switches the service to the Vulkan image, pinned by digest, with only
    `/dev/dri/renderD128` and `group_add: ["993"]` (FC2, FC3). This is an opt-in compose override,
    so a host without a GPU renders the same config as today (FC1). Start from spike config 2
    (np1, f16 KV), but re-measure at the real `-c`: card total ≤ 7.4 GiB with the desktop at
    ≥ 5 GiB (FC4); `restart: on-failure:3` (FC5); no published port (FC8).
  - The model is already in the volume `osionos_ai_models_llm`, so there is no download.
    `/mnt/storage` has 23 GB free.
- **C2. The model is Qwen3-4B.** An 8B model does not fit: the desktop holds 1.8–5.3 GiB of the
  8 GiB, and the spike's rule caps the total at 7.4 GiB. Throughput saturates near 0.5 req/s,
  so the local model serves one person well and a crowd badly. That is why it is ranked last,
  as the floor.
- **C3. The `local` provider** (`dataUse: no-train`, no key), zero price, rank after the cloud
  pool. It is the fallback that never hits a quota.
- **C4. Measured, not claimed.** Tokens/s, time to first token, and VRAM for each model, from a
  script kept under `scripts/`.

## Verification (done-when)

- Unit tests:
  - provider decode, including a legacy config with no providers;
  - key-missing drop;
  - the public non-zero refusal;
  - `may-train` never as default;
  - the content-part first-part clock, its re-arm at `start-step` and the 150 s chain bound;
  - a stalled first model moves the run to the next one, `billed === 0`, and rests for that user;
  - a server-resolved Auto chain, other providers first, filled from the same provider;
  - every FA/FB/FC condition that names a test.
- osionos-ai test suite and typecheck green; app `test:quality` green; CI green.
- Live:
  - one chat on each configured provider;
  - one forced failover (a bad model id → 5xx → next provider);
  - Nemotron no longer cut off at 30 s;
  - B2 from Claude Code;
  - a C local chat with its measured numbers.

## Left to the builder

The exact free model ids (from `/models`), the file split inside `gateway/`, and the UI copy of the
label.
