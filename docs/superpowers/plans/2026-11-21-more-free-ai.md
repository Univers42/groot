# More free AI (A pool · B bring-your-own · C local GPU) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Several free providers behind one server-resolved "Auto" with failover, a thinking-time clock that does not kill silent thinkers, a may-train guard on the server, MCP read access from Claude/ChatGPT in public, and a dev-only local GPU model.

**Architecture:** Pool models live in a new `OSIONOS_AI_PLATFORM_PROVIDERS` env (never in the legacy allowlist). A boot-time catalog merges legacy + pool, and `resolveTarget` hands each target its provider handle and wire. Auto is a server chain built from `rank` and the rest filter. The first-part clock is a small injectable module used by `streamPump`. B and C are mostly config (compose overlay, nginx, a GPU override), and each is verified live.

**Tech Stack:** Node 22 `--experimental-strip-types`, `ai` 7.0.139, `@ai-sdk/openai-compatible` 3.0.68, zod 4.6.7, Postgres + Redis, `node:test`. Client: React 19, canvas runner. llama.cpp Vulkan b11580.

**Spec:** `docs/superpowers/specs/2026-11-21-more-free-ai-design.md`. **Ruling (binds, wins on conflict):** `docs/adr/DRAFT-more-free-ai-ruling.md`, conditions FA1–FA29, FB1–FB10 and FC1–FC8.

## Global Constraints

- Service paths are relative to `apps/osionos/app/services/osionos-ai/` unless a path says otherwise.
- **Work location:**
  - osionos work goes in a worktree under `/mnt/storage/dlesieur/wt/` on `feat/more-free-ai`, branched from `origin/develop`.
  - groot work goes in a groot worktree on `feat/more-free-ai`.
  - Commit message is `updated`. No trailer. No push without the user's go, and never while osionos develop CI runs.
- **Service gate:** `MODELS_DIR=/home/dlesieur/Documents/groot/models AI_TEST_FILES=tests/<file>.test.ts timeout 900 sh scripts/ci.sh`. It runs `tsc --noEmit` and the named suite, and a full run omits `AI_TEST_FILES`.
- **App gate:** `timeout 1800 npm run test:quality` and `npm run test:canvas -- tests/canvas/<file>.test.ts`. Docker only; no Node on the host.
- **Size limits:**
  - Files must stay under 300 lines and functions at 25 lines or less.
  - `config.ts` (573), `runner.ts` (465), `upstream.ts` (385), `routes/runs.ts` (346) and `streamPump.ts` (307) are already over the limit, so new logic goes in new files and those files only gain call sites.
- Every heuristic, timeout and estimate carries a `Caveat:` line.
- **Constants (verbatim from the ruling):**
  - `FIRST_PART_TIMEOUT_MS = 90_000`
  - `CHAIN_FIRST_PART_BUDGET_MS = 150_000`
  - the idle timeout stays `30_000` and the total stays `120_000`
  - user rest after a first-part timeout is `60` s
  - `apiKeyEnv` must match `^OSIONOS_AI_KEY_[A-Z0-9_]+$`
  - `MAX_ATTEMPTS` stays 3
- **Secrets:**
  - Never print key values or DSNs; names and set/unset only. Keys live in `.env.public` / `.env.local` (600), or in groot `secrets/osionos-ai-free-keys.env`.
  - Unchanged rules: C227, C249, C254/C255, C288. Amended by name: R-C10 (FA9), and C256 for the user scope only (FA22).
- **Live:** every live sign-in ends with `scripts/revoke-automation-sessions.sh --api https://baas.tail10f2ea.ts.net:10000 --env-file secrets/osionos-live-probe.env --apply`. Nothing goes live without the user's go.

## Review Focus

1. **Legacy-only config** (no `OSIONOS_AI_PLATFORM_PROVIDERS`, today's public env): boots, menu, Auto chain and upstream body stay the same as today, except Auto now gets same-provider fallbacks. Pinned in Task 2 (`legacy only config decodes byte-identical`) and Task 5 (`openrouter-only Auto gives 3`).
2. **A key env var that is set but empty** (`OSIONOS_AI_KEY_GROQ=`), as compose renders from `${…:-}`: it counts as unset, the provider is dropped, and the log names the id only. Pinned in Task 2.
3. **A user whose saved model id disappears** (a provider dropped at boot): the run falls back to Auto and is not refused with an error page. Pinned in Task 5 (`unknown model id falls back to auto`).
4. **A conversation that cited pages earlier, then switches to a may-train model:** the replayed turns carry no page text either. Pinned in Task 6 (`replayed context stripped`).
5. **A tool-using run where the model goes silent after a tool result, with text already emitted:** the first-part clock re-arms at `start-step`, and no failover happens because text was emitted. Pinned in Task 7 (`re-arms after tool step`).

---

## Phase A — provider pool

### Task 1: Decode `OSIONOS_AI_PLATFORM_PROVIDERS`

**Files:**
- Create: `src/platformProviders.ts`
- Modify: `src/platformModels.ts:24-32` (optional `dataUse` on the legacy schema)
- Test: `tests/platformProviders.test.ts`

**Interfaces:**
- Produces:
  ```ts
  type DataUse = 'no-train' | 'may-train';
  type Wire = 'openrouter' | 'openai-compatible';
  interface PoolModel extends PlatformModelEntry { upstreamId: string; dataUse: DataUse; rank?: number }
  interface PlatformProvider { id: string; baseUrl: string; apiKeyEnv?: string; wire: Wire; models: PoolModel[] }
  function decodePlatformProviders(raw: string | undefined, opts: { devHosts: readonly string[] }): PlatformProvider[] | null
  ```
  - It returns `[]` for an unset or empty value, and `null` when the value is broken.
  - `PlatformModelEntry` gains `dataUse?: DataUse`, read by Task 2.

- [ ] **Step 1: Write the failing tests** in `tests/platformProviders.test.ts`:
  - `unset → []`.
  - `valid two-provider JSON round-trips`.
  - `apiKeyEnv "OSIONOS_AI_KEK" → null`, and the same for `"OSIONOS_AI_DATABASE_URL"` (FA3).
  - `baseUrl "http://example.com/v1" → null` (FA4).
  - `http://osionos-ai-llm:8080/v1` is accepted only when `devHosts` includes `osionos-ai-llm` (FA4).
  - `unknown dataUse → null` (the field is an enum).
  - `missing dataUse defaults to "may-train"` (FA24).
  - Duplicate provider ids → `null`.
  - Unknown keys are stripped, never trusted.
- [ ] **Step 2: Run the tests and check they fail.** `AI_TEST_FILES=tests/platformProviders.test.ts … sh scripts/ci.sh` → FAIL (module not found).
- [ ] **Step 3: Implement** with a zod schema. Pick the URL check with `new URL()`. A provider id is `^[a-z0-9-]{1,32}$`.
- [ ] **Step 4: Run again** → PASS.
- [ ] **Step 5: Commit** (`updated`).

### Task 2: The boot catalog (union, public refusal, may-train default)

**Files:**
- Create: `src/gateway/catalog.ts`
- Modify: `src/config.ts`. Read `OSIONOS_AI_PLATFORM_PROVIDERS` and `OSIONOS_AI_PUBLIC_MODE` (`'on'|''`), and expose `config.catalog`. These are new fields only.
- Modify: `scripts/test.sh` (the placeholder model gains `"dataUse":"no-train"`)
- Test: `tests/catalog.test.ts` is the existing connections catalog, so use `tests/platformCatalog.test.ts`.

**Interfaces:**
- Consumes: Task 1.
- Produces:
  ```ts
  interface CatalogEntry { menuId: string; upstreamId: string; providerId: string /* 'legacy' for OSIONOS_AI_PLATFORM_MODELS */; wire: Wire; dataUse: DataUse; rank: number; pricing: PlatformModelEntry }
  interface PlatformCatalog { entries: readonly CatalogEntry[]; providers: readonly PlatformProvider[]; defaultId: string }
  function buildCatalog(legacy: readonly PlatformModelEntry[], providers: readonly PlatformProvider[], env: { publicMode: boolean; keyOf: (name: string) => string | undefined; log: (line: string) => void }): PlatformCatalog | { refused: string }
  ```
  - `config.catalog: PlatformCatalog` and `config.publicMode: boolean` (read by Task 14).
  - Legacy entries get `wire: 'openrouter'` when `upstreamBaseUrl` host is `openrouter.ai`, else `'openai-compatible'`.
  - A missing `rank` sorts last, by list order.

- [ ] **Step 1: Write the failing tests:**
  - `legacy only config decodes byte-identical`: the entries equal today's `platformModels` (Review Focus 1).
  - `menu ids unique across the union`: a duplicate refuses (FA1).
  - `exactly one default across the union`.
  - `same upstreamId on two providers → two menu ids` (FA2).
  - `provider with unset key dropped, log names id only`, and the same when the key is the empty string. The captured log contains no key value (FA6, Review Focus 2).
  - `public mode: a non-zero price refuses`, and `the same entry with public mode off builds` (FA8).
  - `may-train default refuses` (FA23).
  - `unknown dataUse on a legacy entry counts as may-train` (FA24).
- [ ] **Step 2: Run them and check they fail.**
- [ ] **Step 3: Implement `buildCatalog`**, then wire it in `config.ts`. A refusal goes through the existing `refuse(name)`, which logs the name only and exits 1.
- [ ] **Step 4: Run the new test plus `tests/failover.test.ts` and `tests/cooldown.test.ts`** (regression) → PASS.
- [ ] **Step 5: Commit.**

### Task 3: Per-provider handles and wire-scoped options

**Files:**
- Modify: `src/gateway/platform.ts`. One cached `createOpenAICompatible` per provider. The `HTTP-Referer`/`X-Title` headers go on the `openrouter` wire only. `platformModel(menuId)` resolves through the catalog.
- Modify: `src/gateway/resolve.ts:184-199`. The platform target gets `provider`, `dataUse` and `upstreamWire`, and `optionsKey` becomes the provider's handle name.
- Modify: `src/runs/effort.ts:47-52`. OpenRouter's `reasoning:{effort}` only when `upstreamWire === 'openrouter'`, else `reasoningEffort`.
- Modify: `src/runs/attempt.ts:86-97`. `data_collection:'deny'` on every call to an openrouter-wire `no-train` model, and on vision calls as today (FA25).
- Extend: `tests/mockFailing.ts`. Record each request's headers and JSON body per model, as `bodies(model)` and `headers(model)`.
- Test: `tests/providerWire.test.ts`

**Interfaces:**
- Consumes: Task 2 `PlatformCatalog`.
- Produces: `ResolvedTarget` gains `provider: string`, `dataUse: DataUse` and `upstreamWire: Wire | 'user'`. User connections set `'user'` and `'no-train'`. The cooldown key keeps using `modelId` = the menu id (FA2).

- [ ] **Step 1: Write the failing tests** (mock as two providers on 127.0.0.1 through `OSIONOS_AI_DEV_ENDPOINT_HOSTS`):
  - `openrouter wire gets referer + reasoning effort shape`.
  - `openai-compatible wire gets neither header nor provider/reasoning body fields` (FA5).
  - `no-train openrouter text call carries data_collection deny` (FA25).
  - `upstream receives upstreamId, not menuId`.
  - `same upstreamId on two providers rests independently` (FA2; two `cooldownKey`s).
- [ ] **Step 2: Run them and check they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them plus `tests/effort.test.ts`, `tests/failover*.test.ts` and `tests/images.test.ts`** → PASS.
- [ ] **Step 5: Commit.**

### Task 4: `GET /api/ai/models` gains `rank` and `dataUse`

**Files:**
- Modify: `src/routes/models.ts:85` (the platform list maps `{id, label, default, vision, reasoning, rank, dataUse}`)
- Test: `tests/modelsRoute.test.ts`, created if absent; check `rg -l handleModels tests` first and extend that file when one exists.

- [ ] **Step 1: Write the failing test.** `models response keys snapshot`: each platform item's key set equals `['dataUse','default','id','label','rank','reasoning','vision', …rest-fields]`, and no key matches `/price|url|key|upstream/i` (FA14).
- [ ] **Step 2: Run it and check it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it** → PASS.
- [ ] **Step 5: Commit.**

### Task 5: Server-resolved Auto chain, and the may-train fallback refusal

**Files:**
- Create: `src/runs/auto.ts`
- Modify: `src/routes/runs.ts:184-189`. When the target is the platform and the model is absent or `"auto"` (or an unknown id, Review Focus 3), and the body has no explicit `fallbacks`, use `autoChain`.
- Modify: `src/routes/fallbacks.ts` returns `{kind:'refused', code:'fallback_may_train'}` → 400 (FA23).
- Test: `tests/autoChain.test.ts`

**Interfaces:**
- Produces:
  ```ts
  function autoChain(catalog: PlatformCatalog, resting: (menuId: string) => boolean, size = 3): CatalogEntry[]
  ```
  It picks the best rank first, then the remaining slots from other providers (best rank each), then the same provider's next models. It skips `may-train` and resting entries. If every entry is resting, it returns the non-resting set (possibly empty) and the route answers as today with no model.

- [ ] **Step 1: Write the failing tests:**
  - `openrouter-only Auto gives 3` (FA12).
  - `other providers first`.
  - `never picks may-train` (FA23).
  - `resting entries skipped`.
  - `explicit user fallbacks win over Auto` (FA11).
  - `unknown model id falls back to auto`.
  - `may-train fallback → 400 fallback_may_train` (route test through `failoverKit`).
- [ ] **Step 2: Run them and check they fail.**
- [ ] **Step 3: Implement.** `resting` comes from `restingUntil` (`runs/cooldown.ts:136`).
- [ ] **Step 4: Run them plus `tests/failoverRules.test.ts`** → PASS.
- [ ] **Step 5: Commit.**

### Task 6: A may-train run carries no workspace data (FA26)

**Files:**
- Create: `src/runs/privacyGate.ts`
- Modify: `src/routes/runs.ts`. The run route refuses a may-train run whose body carries `pageIds`, `attachments`, `searchWorkspace` or a `workspaceId` context, with 400 `may_train_context`.
- Modify: `src/runs/runner.ts:375`. For a may-train target it skips `memoriesForRun`, `retrieve`, `loadWorkspaceOverview`, `loadAttachments`, `workspaceSkillsForRun` and the page-reading tools, and strips page/citation blocks from replayed turns.
- Test: `tests/mayTrainPrivacy.test.ts`

**Interfaces:**
- Produces:
  ```ts
  function mayTrainRefusal(body: RunBody, target: ResolvedTarget): 'may_train_context' | null
  function stripWorkspaceContext(messages: ModelMessage[]): ModelMessage[]
  ```

- [ ] **Step 1: Write the failing tests.** The first three capture the upstream body with the Task 3 mock:
  - `may-train run with pageIds → 400 may_train_context`.
  - `replayed context stripped`: a conversation whose earlier turn cited a page, now on a may-train model. The captured body has no page text and no `<page` tag.
  - `may-train run exposes no page tools`.
  - `no-train run unchanged`.
- [ ] **Step 2: Run them and check they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them plus `tests/runs*.test.ts`** → PASS.
- [ ] **Step 5: Commit.**

### Task 7: The content-part first-part clock (FA15–FA17)

**Files:**
- Create: `src/runs/streamClock.ts`
- Modify: `src/runs/streamPump.ts:229-275`. `touch()` is replaced by `clock.onPart(part.type)`, and `PumpInput` gains `firstPartBudgetMs?: number`.
- Modify: `src/runs/runner.ts`. The chain keeps `chainStartedAt` and passes `firstPartBudgetMs = min(FIRST_PART_TIMEOUT_MS, CHAIN_FIRST_PART_BUDGET_MS - elapsed)`.
- Test: `tests/streamClock.test.ts` (fake timers through an injected `{ setTimeout, clearTimeout, now }`)

**Interfaces:**
- Produces:
  ```ts
  const FIRST_PART_TIMEOUT_MS = 90_000; const CHAIN_FIRST_PART_BUDGET_MS = 150_000;
  const CONTENT_PARTS = new Set(['text-delta','reasoning-delta','tool-input-start','tool-call']);
  function createStreamClock(opts: { onTimeout: () => void; firstPartMs: number; idleMs: number; timers?: Timers }): { onPart(type: string): void; stop(): void }
  ```
  - Before the first content part of a step, only the first-part timer runs. `start-step` re-arms it (FA16).
  - After a content part, the idle timer runs and is reset by every part.
  - The total timer stays in `streamPump`.
  - Caveat: a model that streams one byte every 29 s keeps the run alive until the total clock.

- [ ] **Step 1: Write the failing tests:**
  - `start-step then 60 s silence survives` (FA15).
  - `90 s with no content part times out`.
  - `idle 30 s after first text times out`.
  - `re-arms after tool step`: 45 s of silence after the second `start-step` survives (FA16, Review Focus 5).
  - `chain budget: 3 stalled targets end by 150 s` (FA17), with `firstPartBudgetMs` computed as in the runner.
- [ ] **Step 2: Run them and check they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them plus `tests/failover*.test.ts` and `tests/loopBudget.test.ts`** → PASS.
- [ ] **Step 5: Commit.**

### Task 8: The stall failover test, the header fix and the user rest (FA19, FA20, FA22)

**Files:**
- Modify: `src/runs/failover.ts:6-9`. Header text only: a timed-out attempt is moved by `failoverClassOf`, and `classifyFailure` alone does not move it.
- Modify: `src/runs/cooldown.ts:99`. A first-part timeout on a platform target writes `cooldownKey('user:'+userId, …)` for 60 s. Platform scope is unchanged. `FailureInput` gains `firstPartTimeout?: boolean`.
- Modify: `src/runs/streamClock.ts`. The timeout reason carries `'first_part'`, so `UpstreamTimeout` gains `phase: 'first_part' | 'idle' | 'total'`.
- Test: `tests/failoverStall.test.ts` (`startKit()`, and `script(model, {behaviour:'ok', delayMs: >first-part})` with an injected short `FIRST_PART_TIMEOUT_MS` through env `OSIONOS_AI_TEST_FIRST_PART_MS`, read only when `NODE_ENV=test`)

- [ ] **Step 1: Write the failing tests:**
  - `stall moves the run to the next model`: the events contain `route` with reason `unavailable`, the run ends `done` on model 2, and `attempts[0].billed === 0` (FA20).
  - `second run within 60 s skips the stalled model for that user` (FA22).
  - `another user still gets the stalled model first` (the platform scope is unchanged).
- [ ] **Step 2: Run them and check they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them plus `tests/cooldown*.test.ts`** → PASS.
- [ ] **Step 5: Commit.**

### Task 9: Operator scripts: the id list and the rank bench (FA13, FA18, FA28, FC6)

**Files:**
- Create: `scripts/list-provider-models.sh`. It reads `OSIONOS_AI_PLATFORM_PROVIDERS` and the named key env from a `--env-file`, calls `GET <baseUrl>/models`, and prints `provider<TAB>id` only. The key goes through a curl header file, never an argv.
- Move: `spikes/gpu/llm-bench-gpu.mjs`, `requests.mjs`, `summarize.mjs` and `table.mjs` → `scripts/bench/` (`git mv`). The bench gains `--base-url`, `--model` and `--n` (default 20). It reports time to the first content part p50/p95, success rate and tok/s.
- Create: `scripts/bench/rank-pool.sh`. It runs the bench per catalog entry, and its output is the rank artifact.
- Test: `tests/scripts/list-provider-models.bats` (curl stub, the same pattern as groot `scripts/tests/revoke-automation-sessions.bats`)

- [ ] **Step 1: Write the failing bats tests:**
  - `prints ids only`.
  - `key never in argv or output`.
  - `missing key → provider skipped with its id`.
- [ ] **Step 2: Run them and check they fail:** `docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 -c 'apk add -q --no-cache jq curl && bats tests/scripts/list-provider-models.bats'`.
- [ ] **Step 3: Implement.** Then check that the moved bench still runs against the dev `osionos-ai-llm` with `--n 3` (smoke).
- [ ] **Step 4: Run them** → PASS.
- [ ] **Step 5: Commit.**

### Task 10: Client: send "auto", show the label, hide may-train fallbacks

**Files (app repo):**
- Modify: `src/features/ai/model/aiInferencePort.ts:54` (`serviceModel()` sends `"auto"` for an empty or auto selection)
- Modify: `src/widgets/chat-shell/ui/ModelMenuParts.tsx`. A may-train item shows "May use prompts for training", and is excluded from the fallback picker.
- Modify: the model types next to `modelMenu.ts`, which gain `rank?` and `dataUse?`.
- Test: `tests/canvas/ai-model-menu.test.ts` (extend)

- [ ] **Step 1: Write the failing tests:**
  - `auto selection sends model "auto"`.
  - `may-train item carries the label`.
  - `fallback picker omits may-train`.
  - `missing dataUse treated as may-train` (FA24 on the client).
- [ ] **Step 2: Run them and check they fail** with `npm run test:canvas -- tests/canvas/ai-model-menu.test.ts`.
- [ ] **Step 3: Implement.** The label uses the existing `--osio-fg-muted` token; no raw colour.
- [ ] **Step 4: Run them plus `npm run test:quality`** → PASS.
- [ ] **Step 5: Commit.**

### Task 11: groot: public pins, the verify script and the ADR records (FA7–FA10, FA24, FA29, FC7)

**Files (groot worktree):**
- Modify: `docker-compose.public.yml:160-165`. Add these to `osionos-ai` `environment:`:
  - `OSIONOS_AI_PUBLIC_MODE: "on"`
  - `OSIONOS_AI_PLATFORM_PROVIDERS: ${OSIONOS_AI_PUBLIC_PLATFORM_PROVIDERS:-}`
  - one `OSIONOS_AI_KEY_<P>: ${OSIONOS_AI_PUBLIC_KEY_<P>:-}` for each provider admitted to public

  Run `git diff` first: the file has someone else's uncommitted lines, and those stay untouched.
- Create: `scripts/verify/ai-public-providers.sh`. It renders `docker compose -f docker-compose.yml -f docker-compose.public.yml config` and checks:
  - `PUBLIC_MODE` is `on`;
  - `PLATFORM_PROVIDERS` comes from the public var;
  - no provider `baseUrl` names `osionos-ai-llm` or another compose service name (FC7).
- Modify: `docs/adr/DRAFT-more-free-ai-ruling.md`. Add a "Records" section that amends R-C10 by name (FA9). Add one table row per provider: charge evidence with a date (FA10), the data-use policy URL with a date (FA24), and terms for multi-user production with a date (FA29). An empty row means the provider stays out of public.
- Test: `scripts/tests/ai-public-providers.bats`

- [ ] **Step 1: Write the failing bats test:**
  - `internal host in providers fails`.
  - `missing PUBLIC_MODE fails`.
  - `clean config passes`.
- [ ] **Step 2: Run it and check it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it** → PASS. Then run `scripts/verify/ai-public-flags-off.sh` → still PASS.
- [ ] **Step 5: Commit** (`docs(adr)` / `feat(ai)` style; groot uses conventional messages).

### Task 12: Keys, rank and live A verification (gated on the user)

Each step needs its input from the user, or the user's go.

- [ ] **Step 1: Key names (FA27).** `devil preflight` (or `grep -c`) on `secrets/osionos-ai-free-keys.env` prints set/unset per name.
- [ ] **Step 2: Model ids (FA28).** Task 9's id list, run per provider; Groq from the VM. Output and date go in the PR.
- [ ] **Step 3: Charge and terms evidence (FA10, FA29), plus OpenRouter `GET /api/v1/key`** (`limit` and `usage` only). Rows go into the Task 11 ADR table.
- [ ] **Step 4: Rank (FA13, FA18).** Run `rank-pool.sh` with n ≥ 20 per model, and set `rank` from it. If Nemotron's p95 time to the first content part is over 90 s, it is not ranked first. Record whether its reasoning arrives as `reasoning-delta`.
- [ ] **Step 5: Live, with the user's go:**
  - one chat per configured provider;
  - a forced-stall primary ends `done` on the fallback (FA21);
  - Nemotron is no longer cut at 30 s.
  - Then run the revoke script.

## Phase B — bring your own AI

### Task 13: B1 live bring-your-own check (FB1–FB3)

- [ ] **Step 1:** The user supplies a capped key. Through a probe sign-in: add the connection, run one chat on it, delete the connection, and check GET no longer lists it (FB1).
- [ ] **Step 2:** Run the revoke script (FB2).
- [ ] **Step 3:** For each failure, write a failing test, fix, and pass. A fix in `connections/crypto.ts`, `connections/endpointGuard.ts`, the KEK or the catalog stops here for a devil ruling (FB3).

### Task 14: B2 MCP read access in public (FB4–FB10)

**Files:**
- Modify (osionos): `src/routes/accessTokens.ts:104`. With `config.publicMode`, a mint whose scopes include `write_approval` gets 400 `scope_not_allowed` (FB8).
- Test (osionos): `tests/accessTokensPublic.test.ts`
- Modify (groot, **one commit**, FB4/FB5):
  - `docker-compose.public.yml:140` becomes `OSIONOS_AI_PAT: "on"`;
  - add `OSIONOS_AI_MCP_ALLOWED_HOSTS` pinned to the public API host, with `OSIONOS_AI_MCP_ALLOWED_ORIGINS: ""`;
  - remove the two `return 404` locations in `infrastructure/tls/public.d/bridge-public.conf:20-33`, keeping the locked-CORS map;
  - update `scripts/verify/ai-public-flags-off.sh` to the new truth.
- Create (groot): `docs/osionos/ai-mcp-claude.md`. It documents the token with `read` scope, the URL `https://<public API origin>/api/ai/mcp` (FB6), and the Claude Code / Claude Desktop setup. The example is pasted from the live probe.

- [ ] **Step 1: Write the failing test** `public mint with write_approval → 400 scope_not_allowed`, plus `read mint still 201`.
- [ ] **Step 2: Run it and check it fails, implement, then run it** → PASS.
- [ ] **Step 3: FB10.** Run `mcpAccess`, `mcpTools`, `mcpApprovals`, `mcpFlagOff`, `accessTokens`, `accessTokensOff` and `accessTokensPublic` on the flipping commit → all PASS.
- [ ] **Step 4: FB7, a read-only query on the live DB from the VM.** It checks that `public.ai_access_token_resolve` exists and that `osionos_ai` holds EXECUTE. The output goes in the PR. If it fails, stop: the flag cannot flip.
- [ ] **Step 5:** The groot commit (above), and `ai-public-flags-off.sh` → PASS.
- [ ] **Step 6: Live, with the user's go (FB5, FB9):**
  - a request with any `Origin` gets 403 `origin_not_allowed`, and a foreign Host gets `host_not_allowed`;
  - a 1-day token on one workspace makes one `tools/call` read from Claude Code;
  - after revoking it, the same call gets 401, and that output goes in the PR;
  - the token is never printed.

## Phase C — local GPU model (dev only)

### Task 15: GPU override, the measurement and the `local` provider (FC1–FC8)

**Files (groot):**
- Create: `docker-compose.gpu.yml`, overriding `osionos-ai-llm` with:
  - `image: ghcr.io/ggml-org/llama.cpp:server-vulkan-b11580@sha256:ee2ecb9c3a4d6fa00b918b133fd7a2828195593688eeaef6e6516ef833f88f09`
  - `devices: ["/dev/dri/renderD128"]` and `group_add: ["993"]`
  - `-ngl 99 -np 1 -fa on` and the measured `-c`
  - `restart: on-failure:3`
  - no `ports`
- Modify: `.env.local.example` (or the dev provider doc). Add the dev `local` provider entry: `{id:"local", baseUrl:"http://osionos-ai-llm:8080/v1", wire:"openai-compatible", models:[{id:"local-qwen3-4b", upstreamId:"qwen3-4b", dataUse:"no-train", rank:99, …0/0}]}` with `OSIONOS_AI_DEV_ENDPOINT_HOSTS=osionos-ai-llm`.
- Create: `scripts/verify/ai-gpu-override.sh`. It checks that the rendered config without the override is byte-identical to `main`'s (FC1), and that `docker compose port osionos-ai-llm 8080` prints nothing (FC8).

- [ ] **Step 1:** Write `ai-gpu-override.sh` and check that it fails before the file exists. Then add the override, and check it passes.
- [ ] **Step 2: FC3.** Start with the override. The container log shows Vulkan enumerating the RX 6600 with only `renderD128`.
- [ ] **Step 3: FC4.** Run the moved bench with the real prompt size (system + tools + 3 page contexts + 1024 output). Record the container's own VRAM and the card total with the desktop at ≥ 5 GiB. If the total is over 7.4 GiB, lower `-c` or set KV `q8_0` and re-measure.
- [ ] **Step 4: FC5.** Start it with the desktop holding ≥ 5.3 GiB. Record whether it refuses or spills, and that the desktop is unharmed.
- [ ] **Step 5: C4.** TTFT p50/p95, ITL p95, tok/s and VRAM, with the command, go in the PR.
- [ ] **Step 6: One local chat** through Auto, with the cloud providers forced to rest. Then commit.

## Gates before "done"

- The full service suite: `timeout 900 sh scripts/ci.sh` → green.
- App: `npm run test:quality` and the canvas tests touched → green.
- groot: the verify scripts touched, plus `ai-public-flags-off.sh` → green.
- CI green on the pushed branch (push only with the user's go).
- A whole-branch review (`reviewer`), plus a `security` pass on Tasks 3, 6 and 14.
