# osio bot and local models: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to run this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking. Every step that changes behaviour starts with a failing test.

**Goal:**
- **Part 1.** Ship "osio", a team assistant in osionos chat channels. It answers `@osio` or `@ai` in the thread. It only ever uses data that the channel's whole audience can already read.
  - Phase 1a: auto-post in channels that opted in, with no page context.
  - Phase 1b: pages everyone in the channel can open.
  - Phase 3: per-workspace persona and budget.
  - Phase 2 (comments) is a design and a re-submission only.
- **Part 2.** Close more-free-ai Task 15 (local GPU model, dev only) as ruled. Propose a "company-private model" for a new devil ruling. Nothing in Part 2 reaches the public deployment.

**Architecture:**
- **Posting.** The client posts every bot row through the existing guarded route `POST /api/chat/channels/:id/ai-answers` (OB1). The AI service never writes to the bridge.
- **Admission.** Admission lives in `threads/admission.ts`: channel lock, four buckets and a day seat.
- **Phase 1b eligibility.** Page eligibility is one SECURITY DEFINER SQL function, `osionos_ai_audience_pages`, used in two places:
  - inside the retrieval query and the `read_page` query;
  - again in a `BEFORE INSERT` trigger on `osionos_messages`. The trigger rechecks every page the run read, on every insert path.
- **Budget.** Day budgets move to one Redis Lua script that charges runs and upstream calls together, all or nothing. It serves OB10 with tools and OB30.
- **Flags.** Every new behaviour sits behind an exact-`"on"` server flag that defaults to off. The flag is pinned to `""` in `docker-compose.public.yml`.

**Tech Stack:**
- Frontend: React and Vite (`src/`), tested with the canvas runner.
- Bridge: plain-Node `.mjs` (`scripts/bridge-*.mjs`), tested with the bridge runner (`node --test`).
- AI service: TypeScript (`services/osionos-ai`), tested with `node:test` plus Postgres and Redis through `scripts/ci.sh`.
- Data and deployment: Postgres migrations in groot `models/`, Redis Lua, docker compose.
- Local model: llama.cpp Vulkan b11580.

**Spec:**
- Bot design: `groot/docs/superpowers/specs/2026-11-21-osio-bot-design.md`.
- Bot ruling: `groot/docs/adr/DRAFT-osio-bot-ruling.md` (OB1–OB31).
- Local models: `groot/docs/adr/DRAFT-more-free-ai-ruling.md` (FC1–FC8, FB1–FB10) and `groot/docs/superpowers/plans/2026-11-21-more-free-ai.md` (Task 15).
- Spike data: `/mnt/storage/dlesieur/spikes/local-llm/RESULTS.md`.
- User decisions:
  - The bot is named "osio", and `@ai` stays as an alias.
  - Auto-post is off by default for new channels.

**Global Constraints:**
- **Worktrees.** Use `/mnt/storage/dlesieur/wt/oo-osio` (osionos, from `9af6d241d`) and `/mnt/storage/dlesieur/wt/groot-osio` (groot, from `origin/develop`). Never edit `/mnt/storage/dlesieur/wt/oo-296`. Commit message `updated`. No push without the user's go. /mnt/storage has about 9.5 GB free, so check `df -h /mnt/storage` before creating worktrees.
- **Size limits.** Files stay under 300 lines and functions at 25 lines or fewer. Do not grow these files, which are already over the limit: `config.ts`, `runner.ts`, `upstream.ts`, `routes/runs.ts`, `streamPump.ts`, and `retrieval/search.ts` (630 lines). Turning an existing line into an `export` is allowed. New code goes into new files.
- **Caveats.** Every heuristic, bound, cap, regex parser and derived constant gets a `Caveat:` line in its doc comment.
- **No real provider calls in builds or tests.** Tests use the stub upstream and a fetch spy. Live probes are counted against the budget (Task 7).
- **Secrets.** Never print a secret value. Print variable names and set/unset only.
- **Live sign-in.** After every live sign-in, run:
  `scripts/revoke-automation-sessions.sh --api https://baas.tail10f2ea.ts.net:10000 --env-file secrets/osionos-live-probe.env --apply`
- **Gates.** Builds and tests run in Docker only.
  - Service: `cd services/osionos-ai && MODELS_DIR=/home/dlesieur/Documents/groot/models AI_TEST_FILES=tests/<file>.test.ts timeout 900 sh scripts/ci.sh`
  - Bridge: `npm run test:bridge -- tests/bridge/<file>.test.mjs`
  - Canvas: `npm run test:canvas -- tests/canvas/<file>.test.ts`
  - App (before every merge): `timeout 1800 npm run test:quality`
- **Migrations.** New SQL goes in groot `models/` with a matching `models/rollback/` file, and is listed in `services/osionos-ai/scripts/migrations.txt`.

**Review Focus:**
1. The OB14 SQL: the ancestor chain, the cycle and depth bound, the anti-join, and the fail-closed share-rule handling.
2. The `BEFORE INSERT` trigger. It must not block phase 1a rows, whose ledger is empty.
3. Lua atomicity: no partial charge, and a Redis error refuses.
4. No zero-click egress from a bot row (OB4) and no title inside message content (OB18).
5. Public overlay pins, which must keep every new flag off by default.
6. Parity of the three handle lists.

---

## Rollout facts (2026-11-22)

**What is live:**

| Edge | Live tag | Contains phase 1a? |
|---|---|---|
| web (live) | `main-0e10ff56` (an ancestor of develop `9af6d241d`) | Has only the C429 click-to-post draft flow. No auto-post. |
| web (beta) | develop `9af6d241d` | Yes |
| bridge (shared by live and beta) | `main-077cc9a1` | No: no `bridge-chat-autopost.mjs` |
| osionos-ai (shared) | `boost-fa0b0a99` | No: has `runs/auto.ts` and `privacyGate.ts`, but no `threads/admission.ts` (OB8–OB10) |

**Fixed order:**
1. Gateway `verify-password` route (VD1–VD9, being deployed now).
2. Bridge promotion per ADR 0067, carrying #296 and the A296-14 checks.
3. New osionos-ai image.
4. Flags on: beta first, then live.

**Budget:**
- One OpenRouter free key: 50 requests/day.
- `OSIONOS_AI_THREAD_RUNS_PER_DAY=8` runs × 3 requests = 24, which is under 25, i.e. 50 % headroom.

## Flags (all of them, with defaults)

| Flag | Where | Default | Gate semantics | Public overlay pin (Task 5) |
|---|---|---|---|---|
| `OSIONOS_THREAD_ANSWERS` | bridge | unset = off | exactly `"on"` | `${OSIONOS_PUBLIC_THREAD_ANSWERS:-}` |
| `OSIONOS_AI_THREAD_ANSWERS` | osionos-ai | unset = off | exactly `"on"` | `${OSIONOS_AI_PUBLIC_THREAD_ANSWERS:-}` |
| `OSIONOS_AI_AUTOPOST` | bridge | unset = off | exactly `"on"`; also needs `OSIONOS_THREAD_ANSWERS` | `${OSIONOS_PUBLIC_AI_AUTOPOST:-}` |
| `osio.ai.channel` / `VITE_OSIO_AI_CHANNEL` | web | `false` | `?osio.ai.channel=1`, localStorage, or build env `=1` | build arg per edge (beta `1`, live off until R6) |
| `OSIONOS_AI_THREAD_RUNS_PER_DAY` | osionos-ai | `8` | platform-wide thread runs per day | `${OSIONOS_AI_PUBLIC_THREAD_RUNS_PER_DAY:-8}` |
| `OSIONOS_AI_THREAD_RUNS_PER_USER_PER_DAY` | osionos-ai | `2` | per asker per day | unchanged |
| **new** `OSIONOS_AI_THREAD_CALLS_PER_DAY` | osionos-ai | `24` | platform-wide upstream calls reserved by thread runs (Task 14) | `${OSIONOS_AI_PUBLIC_THREAD_CALLS_PER_DAY:-24}` |
| **new** `OSIONOS_AI_THREAD_PAGES` | osionos-ai | unset = off | exactly `"on"`; audience page tools (Task 11) | `${OSIONOS_AI_PUBLIC_THREAD_PAGES:-}` |
| **new** `OSIONOS_AI_PERSONAS` | osionos-ai and bridge (same name) | unset = off | exactly `"on"`; persona and workspace budget (Tasks 19–22) | `${OSIONOS_AI_PUBLIC_PERSONAS:-}` / `${OSIONOS_PUBLIC_AI_PERSONAS:-}` |
| **new** `osio.ai.persona` / `VITE_OSIO_AI_PERSONA` | web | `false` | settings UI only | build arg |
| `docker-compose.gpu.yml` | dev compose | not included | opt-in override file (FC1); provider `local-qwen3-4b`, dev only | never in public (FC7, `scripts/verify/ai-public-providers.sh`) |
| *proposed only* `OSIONOS_AI_PRIVATE_MODEL` | osionos-ai | off | not buildable until the FC7 ruling (Task 25) | would stay `""` |

Caveat: the client flag is not a security gate. Any build honours `?osio.ai.channel=1`, so the server flags and caps are the real gate on every edge.

---

# Part 1: osio-bot

## Task 0: Verify phase 1a as built (OB1–OB12)

**Files:** none changed. The output goes in the PR description.

- [ ] Create the worktree: `git -C /home/dlesieur/Documents/osionos worktree add /mnt/storage/dlesieur/wt/oo-osio 9af6d241d -b osio-bot`. Adjust the source repo path to wherever oo-296 was created from.
- [ ] Run, and record the test names and pass counts:
  - `npm run test:canvas -- tests/canvas/channel-ai-autopost.test.ts tests/canvas/channel-ai-row.test.ts tests/canvas/channel-ai-answering.test.ts tests/canvas/channel-ai-draft.test.ts`
  - `npm run test:bridge -- tests/bridge/bridge-chat-autopost.test.mjs tests/bridge/bridge-chat-ai.test.mjs`
  - Service gate, once per file: `threadAdmission`, `threadDayShare`, `threadPlatformCap`, `threadRuns`, `threadRunsFlagOff`.
- [ ] Fill in the table below with test **names** taken from the run.

Caveat: the line numbers below come from reading `9af6d241d`. The PR must cite test names, not lines.

| OB | Proving tests on 9af6d241d | Status |
|---|---|---|
| OB1 client posts through the guarded route | `channel-ai-autopost.test.ts` (~73/82/90); `bridge-chat-autopost.test.mjs` "goes through the same post route…" | met |
| OB2 `ai_autopost` column, admin-only toggle | `bridge-chat-autopost.test.mjs` (~151–188); groot `models/osionos-chat-ai-autopost-migration.sql` and its rollback | code met. No UI exists (Task 3). Whether the column is applied live is unknown (Task 7 R3). |
| OB3 consent notice | `channel-ai-autopost.test.ts` (~36/49/56/63) | met |
| OB4 no link cards or images, no zero-click request | `channel-ai-row.test.ts` (~63/70/106), static markup only | **GAP**: no fetch/img spy (Task 1) |
| OB5 no mention resolution; only `ai_requested_by` is notified | `bridge-chat-autopost.test.mjs` (~196) | met |
| OB6 badge, "asked by", delete, report | `channel-ai-row.test.ts` (~76/82/87/99); `bridge-chat-ai.test.mjs` C437/C439 cases | met |
| OB7 a failed guard leaves a held draft | `channel-ai-autopost.test.ts` (~98/111/119/130) | met |
| OB8 one run per channel, fail closed | `threadAdmission.test.ts` (~56–80) | met |
| OB9 no-train Auto chain only | `threadAdmission.test.ts` (~91–105) | met |
| OB10 platform day cap | `threadAdmission.test.ts` (~113–131), `threadDayShare.test.ts`, `threadPlatformCap.test.ts` | code met. The allowance has not been measured (Task 6). |
| OB11 flags exactly `"on"`; migration before flag | `bridge-chat-autopost.test.mjs` (~138), `threadRunsFlagOff.test.ts` | **GAP**: no public overlay pin (Task 5); migration order (Task 7) |
| OB12 no pending row; textless "answering" | `channel-ai-answering.test.ts` (~21/30/37/47); `bridge-chat-autopost.test.mjs` (~208–236) | minor GAP: nothing asserts that `message_updated` is never sent (Task 2) |
| OB21(iv), pulled forward because auto-post makes it reachable | none | **GAP** (Task 2) |
| User decision: name "osio", alias `@ai` | `AI_IDENTITY.name` is `'AI'`; handles are `ai`, `ai-bot`, `assistant` | **GAP** (Task 4) |

**Gate:** all commands above pass on `9af6d241d` before Task 1 starts. If any fails, stop and report; do not fix it inside Task 0.

---

## Task 1: OB4 zero-click egress spy

**Files:**
- Create `tests/canvas/channel-ai-row-network.test.ts`.
- Touch `src/widgets/channel-messages/ui/MessageRow.tsx` only if the test fails.

**Interfaces:** none.

- [ ] Write the test. Render an AI row (with `ai_run_id` and `isAi`) whose content holds `https://exfil.example/a.png`, `![x](https://exfil.example/b.png)`, `<img src="https://exfil.example/c">`, and the bare domain `exfil.example/d`. Spy on:
  - `globalThis.fetch`;
  - the `HTMLImageElement.prototype.src` setter (`Object.defineProperty`);
  - `document.createElement`, for `link`, `iframe`, `video`, `audio` and `source`.
- [ ] Assert zero spy calls, zero `img/link/iframe/video/audio/source/a` elements in the row subtree, and that the text is rendered literally.
- [ ] Add a positive control: `new Image().src = 'https://exfil.example/z'` inside the test must trip the spy, which proves the spy is live.
- [ ] Run it. It is expected to pass, because AI rows render plain `message.content`. If it fails, make the AI branch of `MessageRow` render text only.

**Gate:** `npm run test:canvas -- tests/canvas/channel-ai-row-network.test.ts`

**Satisfies:** OB4.

## Task 2: OB12 "never `message_updated`" and OB21(iv) bot-trigger tests

**Files:**
- Modify `tests/bridge/bridge-chat-autopost.test.mjs`.
- Create `services/osionos-ai/tests/threadBotTrigger.test.ts`.
- Create `tests/canvas/channel-ai-bot-trigger.test.ts`.

- [ ] **Bridge.** On a successful auto-post, the realtime publish log contains exactly one `message_created` with `isAi: true` and `mentions: []`, and no `message_updated` for that channel.
- [ ] **Service.** A trigger message authored by `AI_BOT_AUTHOR` whose content is `@ai summarise` or `@osio summarise` is refused by `readTrigger`/`triggerRefusal`, because its label is `AI`, not `You`. The stub upstream log has zero requests.
- [ ] **Canvas.** A realtime `message_created` with `isAi: true` and content `@ai hi` causes no `fetch` to `/api/ai/thread-runs`.
- [ ] If any test fails, fix it at the narrowest point: the trigger check in `aiAnswerDraft.ts`, or `triggerRefusal` in `threads/context.ts`.

**Gate:** the bridge, service and canvas commands for the three files.

**Satisfies:** OB12 and OB21(iv).

## Task 3: Channel admin toggle for auto-post

**Files:**
- Modify `src/shared/chat/channelApi.ts`.
- Create `src/widgets/channel-messages/ui/AiAutopostToggle.tsx`.
- Modify `src/widgets/channel-messages/ui/ChannelHeader.tsx` (82 lines).
- Create `tests/canvas/channel-ai-autopost-toggle.test.ts`.

**Interfaces:**
```ts
// channelApi.ts
export async function setChannelAiAutopost(channelId: string, enabled: boolean): Promise<{ aiAutopost: boolean }>;
// PUT /api/chat/channels/:id/ai-autopost  body { enabled }
```

- [ ] Write the failing tests:
  - The toggle is hidden when `osio.ai.channel` is off, in non-text channels, and for non-admins.
  - It renders "off" when `aiAutopost` is undefined or false.
  - A click sends PUT with `{enabled:true}` and flips the state on 200.
  - A 403 shows "Only channel admins can change this" and leaves the state unchanged.
  - A 503 `autopost_unavailable` shows "Auto-post is not available yet" and leaves the state unchanged.
- [ ] Implement it. The label is "Let osio post answers here without a click". The helper text repeats the OB3 notice.
- [ ] Admin detection: use the channel's existing role field if the client model has one (see Unknowns). If it has none, render the toggle for members and hide it for the session after the first 403. The bridge `requireChannelAdmin` stays the only enforcement.

Caveat: the hide-after-403 fallback shows the toggle to non-admins once.

**Gate:** canvas for the new test, plus `channel-ai-autopost.test.ts`.

**Satisfies:** OB2 (admin-only opt-in, reachable) and the user decision (off by default, because the column defaults to false and the toggle starts off).

## Task 4: Name "osio" and the `@osio` handle (the OB28 triplet, applied early)

**Files:**
- groot `models/osionos-account-profiles-migration.sql`: add `osio` to `osionos_username_reserved()` and to the census DO block. Edit this file in place; re-applying a separate file would overwrite a later replacement of the function.
- `services/osionos-ai/src/threads/context.ts` (`AI_MENTION`, ~line 31).
- `src/widgets/channel-messages/model/aiAnswerDraft.ts` (~line 23–31).
- `scripts/bridge-chat-ai.mjs` (`AI_HANDLES`, line 39; `AI_IDENTITY`, `name: 'osio'`).
- `src/widgets/channel-messages/ui/AiAutopostMarker.tsx`: copy "osio answers @osio and @ai here".
- `src/widgets/channel-messages/ui/MessageRow.tsx`: the bot badge.
- Create `tests/bridge/ai-handles-parity.test.mjs`.

- [ ] **Precondition: read-only live census.** Count the accounts whose username or display name folds to `osio`, and print the count only. If it is greater than 0, stop: keep `@ai`, leave the display name, and report.
- [ ] Write the parity test. It reads the three source files as text, extracts each handle set, and asserts that the sets are equal, non-empty, and contain `ai` and `osio`.
  Caveat: this is a regex over source text. A reformat makes it fail loudly, never pass silently, because emptiness is asserted.
- [ ] Write the canvas test. An AI row renders the name "osio" and the badge "AI", the badge has no prop that hides it, and authorship comes from `ai_run_id`, not from the name (C436).
- [ ] Write the service test. `@osio` and `@ai` both trigger; `@osiox` and `email@osio.dev` do not.
- [ ] Implement: change the three copies together, add the reserved-name entry and the census row, and change the display name.
- [ ] Update the copy strings asserted in `channel-ai-autopost.test.ts` and `channel-ai-row.test.ts`.

**Gate:** bridge parity; canvas `channel-ai-row`, `channel-ai-autopost`; service `threadRuns`, `threadBotTrigger`; the groot migration applied to the dev DB, with `select osionos_username_reserved('osio')` returning `true` (exact function arity: see Unknowns).

**Satisfies:** OB28 (triplet and badge), C435/C436, and the user decision on the name.

## Task 5: Pin the thread flags in the public overlay

**Files:**
- groot `docker-compose.public.yml`: the bridge and osionos-ai `environment:` blocks.
- groot `scripts/verify/ai-public-flags-off.sh`.

- [ ] Extend the verify script first, so it fails today. It renders `docker compose -f docker-compose.yml -f docker-compose.public.yml config` with `OSIONOS_THREAD_ANSWERS=on OSIONOS_AI_AUTOPOST=on OSIONOS_AI_THREAD_ANSWERS=on OSIONOS_AI_THREAD_PAGES=on OSIONOS_AI_PERSONAS=on` exported, which simulates a leaking `.env.local`. It then asserts with jq that each rendered value is `""`.
- [ ] Add a second render with `OSIONOS_PUBLIC_AI_AUTOPOST=on` and assert that only that value becomes `on`, which proves the switch works.
- [ ] Add the pins listed in the flags table, following the existing `OSIONOS_AI_*: ""` / `${OSIONOS_AI_PUBLIC_*:-}` pattern.

**Gate:** `bash scripts/verify/ai-public-flags-off.sh`; `shellcheck scripts/verify/ai-public-flags-off.sh`.

**Satisfies:** OB11 (off by default on public), plus the pins for 1b and 3.

## Task 6: Measure the shared free allowance (OB10)

**Files:**
- groot `wiki/runbooks/osionos-ai.md`: add a section "Thread-run allowance".

- [ ] Run the following on the host that holds `.env.public`. It prints only the fields listed, never the key:
  ```sh
  set -a; . ./.env.public; set +a
  curl -s -H "Authorization: Bearer $OSIONOS_AI_PUBLIC_UPSTREAM_API_KEY" https://openrouter.ai/api/v1/key \
    | jq '{limit:.data.limit, usage:.data.usage, is_free_tier:.data.is_free_tier, rate_limit:.data.rate_limit}'
  ```
- [ ] Record the date, the command, the output, and OpenRouter's documented free-model daily rule. Set:
  - runs: `OSIONOS_AI_THREAD_RUNS_PER_DAY = floor(allowance × 0.5 / 3)`, which is 8 at 50/day;
  - calls: `OSIONOS_AI_THREAD_CALLS_PER_DAY = floor(allowance × 0.5) − 1`, which is 24.
- [ ] Caveat: `/key` reports credits and limits, not today's free-model request count. Other features share the key, so the 50 % headroom is the only protection for the private assistant.

**Gate:** the runbook diff is reviewed before Task 7 R5.

**Satisfies:** OB10 (measured and recorded before auto-post goes public).

## Task 7: Phase 1a rollout (images, flags, probes, rollback)

**Probe budget:** at most 3 probe runs × 3 requests = 9 requests, which uses 3 of the 8 daily thread runs. Run each probe on a separate step and stop at the first failure.

- [ ] **R0, preconditions.** Tasks 0–6 are merged to develop, and the gateway `verify-password` route (VD1–VD9) is deployed and verified by its own plan.
- [ ] **R1, bridge.** Promote it per ADR 0067, carrying #296, and run the A296-14 checks. Then:
  - Confirm the new tag's commit contains `scripts/bridge-chat-autopost.mjs` (`git cat-file -e <sha>:scripts/bridge-chat-autopost.mjs`).
  - With the flags off, confirm the routes return their flag-off code, as asserted in `bridge-chat-autopost.test.mjs`.
- [ ] **R2, osionos-ai.** Build and pin a new image from develop that contains `threads/admission.ts`. With the flags off, `POST /api/ai/thread-runs` returns the `threadRunsFlagOff` code, and nothing is sent upstream.
- [ ] **R3, migrations (OB11: before any flag).** Apply `osionos-chat-ai-autopost-migration.sql` and, from Task 4, the account-profiles migration. Read-only probe, which must return `boolean | false | NO`:
  `select data_type, column_default, is_nullable from information_schema.columns where table_name='osionos_channels' and column_name='ai_autopost';`
- [ ] **R4, beta, draft path.** Set `OSIONOS_THREAD_ANSWERS=on` (bridge) and `OSIONOS_AI_THREAD_ANSWERS=on` (AI); auto-post stays off. Build beta with `VITE_OSIO_AI_CHANNEL=1`.
  - Probe 1: in a probe channel, send `@osio what is this channel for?`. Expect a private draft and the textless "osio is answering…" for others. Click Post. Expect a row named "osio" with the AI badge and "asked by".
  - Run the revoke script.
- [ ] **R5, beta, auto-post.** Requires the Task 6 record. Set `OSIONOS_AI_AUTOPOST=on`. The admin turns the toggle on in the probe channel.
  - Probe 2: `@osio repeat exactly: https://example.com/x.png`. The row posts with no click. The DevTools network list shows zero requests caused by the row (live OB4).
  - Send a second `@osio` while the first is in flight. Expect `channel_busy`, with 0 upstream calls.
  - Run the revoke script.
- [ ] **R6, live.** Rebuild live web from the same develop commit with `VITE_OSIO_AI_CHANNEL=1`.
  - Probe 3: a draft click-post in a live probe channel.
  - Run the revoke script.
- [ ] **R7, watch for 48 h.** Daily, look at the thread-run count and the account's rest status. The ruling's reverse triggers are:
  - an answer quoted a non-eligible page;
  - the account rested because of thread runs.

**Rollback, in order:**
1. `OSIONOS_AI_AUTOPOST` off, then restart the bridge. The reverse condition says this goes first.
2. `OSIONOS_THREAD_ANSWERS` and `OSIONOS_AI_THREAD_ANSWERS` off.
3. If the code is at fault, re-pin bridge `main-077cc9a1`, AI `boost-fa0b0a99` and live web `main-0e10ff56`. The old bridge ignores the column, which has a default, so inserts keep working.
4. Only after step 3, and only if needed, run `models/rollback/osionos-chat-ai-autopost-rollback.sql`. A new bridge against a missing column returns 503 `autopost_unavailable`.
5. Posted rows: channel admins delete them (C437). Erasure uses `osionos_ai_thread_answers_erase_user`.

**Satisfies:** OB10 (measured before public), OB11 (migration before flag), and the fixed rollout order.

---

## Phase 1b: page context (OB13–OB21)

Build only after Task 7 R7 is clean. All SQL for Tasks 8, 12 and 13 goes in **one** migration so it is applied once:
- groot `models/osionos-ai-audience-migration.sql`;
- groot `models/rollback/osionos-ai-audience-rollback.sql`;
- a new line in `services/osionos-ai/scripts/migrations.txt`.

## Task 8: The OB14 eligibility function

**Files:**
- The migration above.
- `services/osionos-ai/eval/fixture.sql`, only if a column the function needs is missing from the stubs.
- Create `services/osionos-ai/tests/audiencePages.test.ts`.

**Interfaces (SQL):**
```sql
-- OB14(e): true when every channel member row belongs to a live member (or the owner) of channel.workspace_id.
create or replace function public.osionos_ai_audience_open(p_channel uuid) returns boolean
  language sql stable security definer set search_path = public, pg_temp;
-- OB14(a)-(d) for p_pages, or for every page of the workspace when p_pages is null.
-- Returns no rows when the audience is not open.
create or replace function public.osionos_ai_audience_pages(p_channel uuid, p_pages uuid[]) returns setof uuid
  language sql stable security definer set search_path = public, pg_temp;
revoke all on function ... from public; grant execute on function ... to osionos_ai;
```

**Rules:**
- **(a)** `page.workspace_id = channel.workspace_id`, and the channel is a text channel.
- **(b)** `visibility in ('shared','public')`.
- **(c)** `archived_at is null` on the page **and every ancestor**. An ancestor id with no row means a broken chain, which excludes the page.
- **(d)** No `osionos_share_rules` row exists for this workspace where any of these hold:
  - `resource_type='workspace'`;
  - `resource_id = ''`;
  - `resource_type='page' and resource_id = any(chain ids)`;
  - `resource_type in ('database','block')`.
  Caveat: a database or block rule anywhere excludes the whole workspace, because the rule-to-page mapping is not in this table. This over-refuses, which is the fail-closed side.
- **(e)** The member-row anti-join uses the same membership sub-expression as `osionos_ai_channel_context`. The workspace owner counts as a member.
- **Chain bound.** The chain is a recursive CTE over `parent_page_id`, with a cycle guard and depth ≤ 64. Caveat: a chain deeper than 64 is excluded (fail closed).

- [ ] Write a failing matrix test with real Postgres. Make each of (a)–(e) false alone and expect the page excluded; all true means included. Also cover:
  - an ancestor page rule;
  - a workspace-wide rule;
  - a database rule elsewhere;
  - a trashed grandparent;
  - a cycle a→b→a, which must terminate and exclude;
  - depth 65;
  - a collaborator-only page;
  - a guest member row in a private channel, which gives an empty set for all pages;
  - a public channel with workspace members, which is open;
  - `p_pages = null`, which lists every eligible page;
  - an `osionos_ai` role call that succeeds while `anon` is denied.
- [ ] Implement the function and its rollback (`drop function`).

**Gate:** service gate `tests/audiencePages.test.ts`.

**Satisfies:** OB13, OB14.

## Task 9: Audience search with OB14 inside the query

**Files:**
- Create `services/osionos-ai/src/retrieval/audienceSearch.ts`.
- `retrieval/search.ts`: `export` existing fragments only, with no net line growth.
- Create `services/osionos-ai/tests/audienceSearch.test.ts`.

**Interfaces:**
```ts
export interface AudienceHit { pageId: string; title: string; snippet: string }
export async function searchAudience(db: Db, q: { channelId: string; query: string; embedding: number[] | null; limit: number }): Promise<AudienceHit[]>;
```

- [ ] Write the failing tests:
  - With eligible and non-eligible pages that match the same query, only eligible hits come back.
  - The non-eligible sentinel text is absent from every field.
  - Any total or count reflects eligible pages only.
  - `[[page:<uuid>]]` inside snippets becomes `[page]`.
  - A closed audience returns `[]`.
- [ ] Implement: the fusion CTE starts from `ai_chunks where page_id in (select osionos_ai_audience_pages($channel, null))`, so the filter runs **before** ranking and snippets. Every function stays at 25 lines or fewer.
  Caveat: eligibility is computed per call, as one recursive scan of the workspace's pages; the daily run cap bounds the cost.

**Gate:** service gate `tests/audienceSearch.test.ts`, plus the existing retrieval tests.

**Satisfies:** OB15 (search).

## Task 10: Audience `read_page` and text projection

**Files:**
- Create `services/osionos-ai/src/tools/audienceText.ts`.
- Create `services/osionos-ai/src/tools/audienceTools.ts`.
- Create `services/osionos-ai/tests/audienceReadPage.test.ts`.

**Interfaces:**
```ts
export function projectAudienceText(content: unknown, maxChars: number): string; // TEXT_BLOCK_TYPES only; [[page:..]] -> [page]
export function makeAudienceTools(ctx: { db: Db; channelId: string; runId: string }): ToolSet; // search_workspace, read_page only
```

- [ ] Write the failing tests for the four OB16 cases, each with a sentinel title and text in the private target:
  1. a private child page under a shared parent;
  2. an `@page` mention of a private page;
  3. a synced block referencing a private page's block;
  4. a linked database view of a private database.
  In each case the sentinel must not appear in `read_page(parent)`.
- [ ] Also test that `read_page(<non-eligible id>)` and `read_page(<random uuid>)` return the identical `{ error: 'not_available' }`, so the tool is not an existence oracle.
- [ ] Implement `read_page` as `PAGE_SQL` with `and id in (select osionos_ai_audience_pages($ch, array[$id]))`. The projection keeps `TEXT_BLOCK_TYPES` only and drops child-page, database and synced-reference blocks.
  Caveat: dropping non-text blocks also hides harmless content such as tables and code.

**Gate:** service gate `tests/audienceReadPage.test.ts`.

**Satisfies:** OB15 (read), OB16.

## Task 11: Wire the tools into thread runs (flag, privacy gate, prompt)

**Files:**
- Create `services/osionos-ai/src/threads/threadFlags.ts`. It parses `OSIONOS_AI_THREAD_PAGES` and `OSIONOS_AI_THREAD_CALLS_PER_DAY`; this keeps `config.ts` from growing.
- Create `services/osionos-ai/src/threads/pageTools.ts`.
- Modify `services/osionos-ai/src/routes/threadRuns.ts` (132 lines).
- Modify `services/osionos-ai/src/threads/context.ts`: the pages prompt variant.
- Create `services/osionos-ai/tests/threadPageTools.test.ts`.

**Interfaces:**
```ts
export async function threadPageTools(i: { db: Db; channelId: string; runId: string; target: ResolvedTarget }): Promise<ToolSet | undefined>;
// undefined when: flag !== 'on' | isMayTrain(target) | !osionos_ai_audience_open(channel) | the SQL errors (fail closed)
```

- [ ] Write the failing tests:
  - Flag off: no tools, and the prompt says "no tools".
  - A may-train target: refused at admission, and no tools.
  - A guest in the channel: no tools.
  - Flag on and audience open: the stub upstream request lists exactly `search_workspace` and `read_page`.
  - `maxSteps <= 3`.
  - The prompt order is IDENTITY first and the data-boundary line last.
- [ ] Implement it. The prompt tells the model to cite pages as `[[page:<id>]]` and never to write a page title next to a citation.

**Gate:** service gate `threadPageTools`, `threadRuns`, `threadRunsFlagOff`.

**Satisfies:** OB15 (no other tool), OB19.

## Task 12: Record the pages a run read

**Files:**
- Migration: `alter table ai_runs add column if not exists audience_page_ids uuid[] not null default '{}'`.
- Create `services/osionos-ai/src/threads/audienceLedger.ts`.
- Modify `tools/audienceTools.ts`.
- Create `tests/audienceLedger.test.ts`.

**Interface:**
```ts
export async function recordPages(db: Db, runId: string, ids: readonly string[]): Promise<void>;
```

- [ ] Write the failing tests:
  - After a search with 3 hits, all 3 ids are recorded, not only cited ones.
  - `read_page` records its id.
  - If the ledger write throws, the tool returns `{ error: 'not_available' }` and no content (write-ahead, fail closed).
- [ ] Implement it, writing the ledger **before** the tool returns content.

**Gate:** service gate `tests/audienceLedger.test.ts`.

**Satisfies:** OB17 (recorded server-side).

## Task 13: Post-time recheck on every insert path

**Files:**
- Migration: function `osionos_ai_answer_pages_refusal(p_run uuid, p_channel uuid, p_content text) returns text`, plus a trigger `osionos_messages_ai_pages_check BEFORE INSERT ... WHEN (new.ai_run_id is not null)` that raises `pages_changed`.
- `scripts/bridge-chat-ai.mjs`: map the error to 409 `{error:'pages_changed'}`.
- `src/widgets/channel-messages/ui/AiDraftCard.tsx`: add `pages_changed` to the FAILURES map.
- Create `services/osionos-ai/tests/audiencePostCheck.test.ts`.
- Create `tests/bridge/bridge-chat-ai-pages.test.mjs`.

**What the trigger refuses:**
1. any ledger id missing from `osionos_ai_audience_pages(new.channel_id, ledger)`;
2. any `[[page:x]]` in `new.content` where x is not in the ledger.

An empty ledger with no citations is a no-op, so phase 1a is unchanged.

- [ ] Write the failing SQL tests:
  - An eligible page passes.
  - A page made private after the run raises.
  - A guest added to the channel raises.
  - A cited id that is not in the ledger raises.
  - A raw SQL insert raises too, which covers both the auto and click paths and older bridge images.
  - Phase 1a rows still insert.
- [ ] Write the failing bridge tests:
  - The REST error maps to 409 `pages_changed`, with no realtime publish.
  - The client keeps the held draft (OB7); its Post re-runs the same check.
- [ ] Implement it. Caveat: the trigger sees the insert statement's snapshot (READ COMMITTED), so a membership change that commits concurrently with the insert is not seen. This is the one-request residual OB17 names. The old bridge `main-077cc9a1` returns 500 instead of 409, which is fail-closed.

**Gate:** service gate `audiencePostCheck`; bridge `bridge-chat-ai-pages`, `bridge-chat-ai`, `bridge-chat-autopost`; canvas `channel-ai-autopost`.

**Satisfies:** OB17 (recheck on both paths, C454 kept by the existing `runRefusal`), OB18 (server half: content carries ids only).

## Task 14: Atomic day budget for runs and upstream calls

**Files:**
- Create `services/osionos-ai/src/threads/dayBudget.ts`.
- Modify `threads/admission.ts`: replace `takeDaySeat` with `takeDayBudget`.
- Create `services/osionos-ai/tests/threadDayBudget.test.ts`.

**Interfaces:**
```ts
export type BudgetRefusal = 'user_day' | 'all_day' | 'calls_day' | 'ws_day' | 'ws_calls_day';
export async function takeDayBudget(redis: Redis, b: { keys: BudgetKeys; caps: BudgetCaps; reserveCalls: number }): Promise<BudgetRefusal | null>;
export function reserveFor(withTools: boolean): number; // derived from maxSteps and the Auto chain's attempt bound
```

**How it works:**
- One Lua script reads every key and checks every cap. It increments all of them only if all pass, with a TTL of 2 days.
- A Redis error makes admission return `rate_limit_unavailable`.
- There is no refund; see Decisions.

Caveat: `reserveFor` is the worst case, maxSteps plus the failover attempts. If the chain gains an attempt, the cap undercounts. A test asserts that the reserve is at least the code constants it derives from.

- [ ] Write the failing tests:
  - With 20 concurrent admissions, cap 24 and reserve 5, exactly 4 are admitted.
  - When a cap is reached, no key is incremented (no partial charge).
  - Redis down means a refusal.
  - `threadDayShare` and `threadPlatformCap` stay green.
- [ ] Implement. Keep `ws_*` keys absent until Task 21.

**Gate:** service gate `threadDayBudget`, `threadAdmission`, `threadDayShare`, `threadPlatformCap`.

**Satisfies:** OB10 with tools (24 calls under the 25 headroom); the base for OB30.

## Task 15: Citation chips and help text

**Files:**
- Create `src/widgets/channel-messages/ui/AiAnswerText.tsx`.
- Create `src/widgets/channel-messages/ui/AiPageChip.tsx`.
- Modify `MessageRow.tsx`: AI rows use `AiAnswerText`, about +3 lines.
- Modify `AiAutopostMarker.tsx` and `AiDraftCard.tsx`: help text.
- Create `tests/canvas/channel-ai-chips.test.ts`.

- [ ] Write the failing tests:
  - `[[page:<id>]]` renders a chip whose title comes from the reader's loaded page store.
  - An unknown id renders "restricted", with no title and not as a link.
  - No `fetch` happens; reuse the Task 1 spies.
  - Non-AI rows are not parsed.
  - The help text is present: "osio reads only pages everyone in this channel can open. A posted answer stays after a page is made private or deleted, and later members can see it, like a quote typed by hand."
- [ ] Implement it. Caveat: a page the reader can open but whose store has not loaded yet shows "restricted". That is a false "restricted", which is the safe side.

**Gate:** canvas `channel-ai-chips`, `channel-ai-row`, `channel-ai-row-network`.

**Satisfies:** OB18, OB20.

## Task 16: Injection tests (OB21 i–iii)

**Files:**
- Create `services/osionos-ai/tests/threadInjection.test.ts`.
- Create `tests/bridge/bridge-chat-ai-injection.test.mjs`.

The stub model is scripted to obey every injection, which is the strongest case. Its output becomes the stored answer. The bridge test posts that stored answer.

- [ ] **(i)** A channel message asks for a non-eligible page and an exfil URL. The scripted model calls `read_page(private)` and gets `not_available`. Assert:
  - The posted row has no sentinel.
  - The fetch spy and the stub log have no request to `exfil.example`, and no request body contains the sentinel.
  - A citation of the private id makes the insert raise, and the row falls back to a held draft.
- [ ] **(ii)** A shared page carries planted instructions to read a private page. Same assertions.
- [ ] **(iii)** The answer holds 50 `@everyone` and `@alice` mentions. The bridge row has `mentions: []`, and the only notification goes to `ai_requested_by`.
- [ ] **(iv)** is already covered in Task 2. Reference it in the PR.

**Gate:** service `threadInjection`; bridge `bridge-chat-ai-injection`.

**Satisfies:** OB21.

## Task 17: Phase 1b rollout

**Probe budget:** 1 run, at most 5 calls.

- [ ] Apply `osionos-ai-audience-migration.sql` live. It is a no-op for phase 1a rows (empty ledger).
- [ ] Deploy the new AI image and bridge image, then the web containing chips and help text.
- [ ] Set `OSIONOS_AI_THREAD_PAGES=on`.
- [ ] Probe in a probe workspace that has one shared page and one private page with a sentinel. Ask `@osio` about both. The posted row cites only the shared page, and the sentinel is absent.
- [ ] Run the revoke script.
- [ ] Rollback: `OSIONOS_AI_THREAD_PAGES` off. The trigger stays, harmlessly. `osionos-ai-audience-rollback.sql` runs only after the flag is off and the images are re-pinned.

---

## Task 18: Phase 2 (comments): design and re-submission only (BLOCKED, OB22–OB26)

**Files:** groot `docs/superpowers/specs/2026-11-2x-osio-comments-design.md`. No code.

- [ ] Write the design. It must contain:
  - **OB22:** the full SQL of `osionos_ai_comment_context(p_page uuid, p_comment uuid)`. The context is the commented page and its thread only, and `read_page` follows OB16.
  - **OB23:** held comments (the asker's own included) and deleted comments are excluded.
  - **OB24:** refusal on `public` pages.
  - **OB25:** the route schema `POST /api/ai/comment-runs {runId, pageId, commentId}`; the bridge post path announcing `discussion_changed`. The design must also cover:
    - unique `ai_run_id` on `osionos_page_comments`, plus a check that the bot author holds exactly when `ai_run_id` is set;
    - `requireInteraction` for the asker;
    - per-page and per-member buckets;
    - L0 `on`, the 30-minute bound, and the unedited and unchanged guards;
    - a page-read recheck for the asker at post time.
- [ ] Submit it with `/devil:deal`. **Gate:** a PROCEED verdict is recorded before any phase 2 code (OB26).

---

## Phase 3: persona and workspace budget (OB27–OB30)

## Task 19: Settings and audit schema

**Files:**
- groot `models/osionos-ai-workspace-settings-migration.sql` and its rollback; a `migrations.txt` line.
- Create `services/osionos-ai/tests/workspaceSettings.test.ts`.

**Schema:**
- `osionos_ai_workspace_settings` columns: `workspace_id pk`, `persona_name text check (char_length between 1 and 32)`, `avatar_asset text`, `instructions text check (char_length <= 2000)`, `runs_per_day int check (runs_per_day between 0 and 200)`, `calls_per_day int check (calls_per_day between 0 and 1000)`, `updated_by uuid not null`, `updated_at`.
- `osionos_ai_workspace_settings_audit` columns: `id`, `workspace_id`, `actor`, `field`, `new_value`, `at`. An `AFTER INSERT OR UPDATE` trigger writes one row per changed field.
- No direct client grants.

- [ ] Write the failing tests: the length checks, one audit row per changed field, and the grant matrix.
- [ ] Implement.

**Satisfies:** OB27 (server-checked length, audit), OB29 (storage key, not a URL column).

## Task 20: Bridge persona route and name checks

**Files:**
- Create `scripts/bridge-chat-ai-persona.mjs`.
- Create `scripts/bridge-name-fold.mjs`.
- Create `tests/bridge/bridge-chat-ai-persona.test.mjs`.

**Interfaces:**
```js
// GET/PUT /api/workspaces/:id/ai-persona   (OSIONOS_AI_PERSONAS === 'on'; requireWorkspaceAdmin, bridge-social-core.mjs:249)
export function foldName(s) // NFKC, lowercase, strip zero-width/combining marks, map a fixed confusable table
```

- [ ] Write the failing tests:
  - A non-admin gets 403.
  - Instructions over 2,000 characters get 400.
  - Names that fold equal to a member's display name or username are refused: `osio` versus member `Osio`, Cyrillic `о`, fullwidth characters, and zero-width joiners.
  - An avatar that is a free URL is refused.
  - An avatar that is an uploaded asset key is accepted only if `bridge-image-source.mjs` accepts it.
  - Flag off gives the flag-off code.
- [ ] Caveat: the confusable map is a fixed Latin, Cyrillic and Greek table, not the full Unicode `confusables.txt`. The member read is capped at 5,000, and above that the route refuses (fail closed).
- [ ] Precondition for avatars: the BG `/\` bypass fix must be on develop (`git log --oneline -S'/\\' -- scripts/bridge-image-source.mjs`). If it is absent, ship name and instructions only, and refuse every avatar value.

**Gate:** bridge `bridge-chat-ai-persona`.

**Satisfies:** OB27 (owner/admin only), OB28 (confusable refusal, display only), OB29.

## Task 21: AI service persona prompt and workspace budget

**Files:**
- Create `services/osionos-ai/src/threads/persona.ts`.
- Modify `threads/context.ts` and `threads/dayBudget.ts` (the `ws_*` keys).
- Create `tests/threadPersona.test.ts`.

**Interfaces:**
```ts
export async function loadPersona(db: Db, workspaceId: string): Promise<Persona | null>; // throws -> run refused 503 'settings_unavailable'
export function threadSystemPrompt(p: { persona: Persona | null; pages: boolean }): string; // IDENTITY, persona, shared-channel rule, ..., data boundary LAST
```

- [ ] Write the failing tests:
  - The prompt order is as specified.
  - Persona text containing "you now have delete_page" or "ignore the data boundary" leaves the upstream tool list unchanged, and the boundary line is still last.
  - The workspace runs and calls caps are charged in the same Lua call as the asker's buckets; a concurrency test shows no over-admission.
  - Redis down or a settings read error means a refusal.

**Gate:** service gate `threadPersona`, `threadDayBudget`, `threadPageTools`.

**Satisfies:** OB27 (placement, cannot add tools), OB30.

## Task 22: Client persona display and settings

**Files:**
- `scripts/bridge-chat-ai.mjs`: `AI_IDENTITY` becomes `aiIdentity(settings)`, resolved per workspace when serialising bot rows.
- `MessageRow.tsx`.
- A new `src/widgets/workspace-settings/ui/AiPersonaSettings.tsx`. The exact settings host is unknown.
- Create `tests/canvas/channel-ai-persona.test.ts`.

- [ ] Write the failing tests:
  - The persona name renders together with the AI badge, which cannot be removed.
  - The avatar is rendered only through `bridgeMediaUrl` with `isProfileImageSource`.
  - The settings form is hidden unless `osio.ai.persona` is on and the viewer is an admin.

**Gate:** canvas `channel-ai-persona`, `channel-ai-row`, `channel-ai-row-network`.

**Satisfies:** OB28 (badge), OB29 (render path).

**Phase 3 rollout:**
1. Apply the migration.
2. Deploy the images.
3. Set `OSIONOS_AI_PERSONAS=on` on beta.
4. Probe: an admin sets a name; a name that collides with a member is refused. This costs 0 upstream calls.
5. Then turn it on for live.
6. Rollback is flag off.

---

# Part 2: local models

## Task 23: more-free-ai Task 15 as ruled (dev only): close-out

**Status on groot develop:**

| Condition | Status | Evidence on develop (`deb30275`, fixes `ce8c71a9`, `d110b700`, `3c4ae057`) |
|---|---|---|
| FC1 opt-in override | met | `docker-compose.gpu.yml` |
| FC2 image pinned by digest | met | digest `sha256:ee2ecb9c…f09` |
| FC3 render node only | met | `renderD128` with `group_add` 993 |
| FC6 bench reused, not rewritten | met | `services/osionos-ai/scripts/bench/` |
| FC7 not in any public provider list | met | `scripts/verify/ai-public-providers.sh` |
| FC8 no host port | met | no ports published |
| FC5 short-VRAM behaviour | partly met | `restart: on-failure:3` is in place; the runbook records "spills instead of refusing" |
| FC4 card total | **not met** | See below. |

**Why FC4 fails:**
- FC4 requires a card total of at most 7.4 GiB while the desktop holds at least 5 GiB, which leaves the model at most about 2.4 GiB (about 2,458 MiB).
- The runbook records 3,370 MiB at `-c 6144`.
- The 4B Q4_K_M weights alone are 2,497,281,120 B, about 2,382 MiB. So full offload (`-ngl 99`) cannot meet FC4 at any `-c`.
- Caveat: this treats the file size as the VRAM taken by the weights. Vulkan compute buffers add to it, so the real gap is larger.

**Files:**
- groot `docker-compose.gpu.yml`.
- groot `wiki/runbooks/osionos-ai.md`.
- `scripts/ai-gpu-vram.sh` and `scripts/verify/ai-gpu-override.sh`, read only unless a step changes them.

- [ ] **Measure option A, partial offload.** Find the largest `-ngl N` whose container VRAM, measured with `scripts/ai-gpu-vram.sh <container>`, is at most about 2,300 MiB at the `-c` FC4 requires. Record the card total from `/sys/class/drm/card*/device/mem_info_vram_used` with the desktop at ≥ 5 GiB. Record the bench numbers (TTFT p50/p95, ITL p95, tok/s) with the command, as FC6 asks.
- [ ] **Option B, CPU only.** `-ngl 0` uses 0 VRAM. Spike row 1b shows 14.6 tok/s and TTFT 0.76 s at `-c 2048`; re-bench it at the FC4 context.
- [ ] Pick the option with the higher gen tok/s that meets FC4. If neither reaches 10 tok/s at the real context, write a deviation record for devil instead of changing anything.
- [ ] **FC5.** Start the container with the desktop at ≥ 5.3 GiB and record whether it refuses cleanly or spills a bounded amount, and confirm the desktop is unharmed.
- [ ] Update the runbook numbers. Put the FC4 and FC5 records in the PR.

**Gate:**
- `bash scripts/verify/ai-gpu-override.sh` and `bash scripts/verify/ai-public-providers.sh`.
- `docker compose config` without the override is byte-identical to before (FC1).
- `docker compose -f docker-compose.yml -f docker-compose.gpu.yml port osionos-ai-llm 8080` prints nothing (FC8).
- No OpenRouter calls anywhere in this task.

**Satisfies:** FC4 and FC5, closing Task 15.

The 30B-A3B model is not adopted. It needs 6,482 MiB at `--n-cpu-moe 40`, or 3,536 MiB at `--n-cpu-moe 48`, and both exceed the FC4 budget on the shared card.

## Task 24: PROPOSAL, a company-private model: NEEDS A NEW DEVIL RULING (FC7) before any public use

This is not buildable under any existing ruling. FC7 says the local provider never goes public without its own ruling, and nothing here may be built before that ruling.

**Files:** groot `docs/superpowers/specs/2026-11-2x-company-private-model-design.md`. No code.

**Two shapes to put to the ruling:**
- **P1, operator-hosted.** A workspace selects "private model". Its runs go only to a llama.cpp server on our host, with no cloud fallback (strict), so the data never leaves the host.
- **P2, bring your own endpoint.** A workspace admin registers the company's own OpenAI-compatible base URL and key, and our server calls their host instead of our GPU.

**Questions the ruling must answer:**
1. **Queueing and capacity.** FC7 recorded a TTFT p50 of 21 s at 1 req/s. One 4B stream at about 70 tok/s with 1,024 output tokens takes about 15 s, so the server handles about 4 answers a minute, one after another. The ruling must settle:
   - the queue depth;
   - per-workspace concurrency;
   - whether a full queue refuses with "busy" or spills. Spilling to the cloud breaks "never leaves the host", so P1 must refuse.
2. **The shared desktop GPU.** Task 23 shows that full offload cannot meet FC4. Public use therefore needs a dedicated card, CPU-only serving, or a revised FC4. The ruling must also say who wins when the desktop and the model compete, and whether a GPU reset can hurt the desktop.
3. **Per-workspace selection.** Who may switch it on: the owner only, audited? Does it become the *only* target for the workspace? How does it interact with OB9 (thread runs are no-train only; local is no-train by construction) and FA26? How does it show in the model picker?
4. **Disk.** The 30B GGUF is 18.6 GB, against 9.5 GB free on /mnt/storage (about 28 GB after deleting the spike GGUF); the 4B is 2.5 GB. The ruling must say where the weights live, how they are pinned by checksum, and who downloads them.
5. **Bring your own.** OB9 forbids user connections for thread runs, so a workspace-level connection is a new principal.
   - P2 touches `connections/endpointGuard.ts` (company endpoints on private networks) and `connections/crypto.ts` (KEK), so FB3 applies.
   - FB1–FB10 is the live-verify precedent.
   - Under FA24, a workspace admin's "no-train" claim is unverifiable. The ruling must say whether it counts or the target stays may-train.
6. **Public verify.** `scripts/verify/ai-public-providers.sh` asserts that no compose-internal `baseUrl` exists. The ruling must say what replaces that check.
7. **Fairness.** One workspace must not starve the others: a per-workspace token or run budget, using the Task 14 Lua.
8. **Data at rest.** llama-server logging and slot or prompt caches (`--slot-save-path` unset; logging off) need to be settled.
9. **Quality floor.** Is a 4B answer acceptable for workspace features without failover? An eval is needed before it is offered.

- [ ] Write the proposal with these questions and the proposed flag `OSIONOS_AI_PRIVATE_MODEL` (default off).
- [ ] Submit it with `/devil:deal`. **Gate:** a verdict is recorded. Until then, no code exists and the public overlay is unchanged.

---

## Decisions (with reasons)

1. **The client posts; no AI-service write edge.** The ruling's OB1 alternative analysis rejects a service-to-bridge credential, and phase 1a already works this way.
2. **The display name "osio" and the `@osio` handle ship in phase 1a through the full OB28 triplet** (reserved name, census, three copies), gated on a census of 0. The user chose the name, and OB28 is the only ruled way to add a handle. `@ai` keeps working.
3. **Edit `osionos-account-profiles-migration.sql` in place** rather than adding a new reserved-name migration. A separate file that re-creates the function would overwrite a later replacement of it.
4. **"Beta first" means global server flags plus the client flag built into beta only.** Beta and live share one bridge and one AI service, so the server flags cannot be split by edge. The old live client only has the ruled C429 click flow, and the 8 runs/day cap bounds exposure. Caveat: `?osio.ai.channel=1` works on any build.
5. **Pin every thread flag to `""` in `docker-compose.public.yml`.** In the bridge, `environment:` beats `env_file`. Without a pin, a dev `.env.local` value could turn the feature on in public (OB11).
6. **Eligibility is one SQL function, used inside the queries and in a `BEFORE INSERT` trigger.** OB14 asks for one predicate. The trigger covers the auto path, the click path, any older bridge image and raw inserts, and it shrinks the OB17 residual from one request to one statement snapshot. This goes further than OB17's "the bridge re-evaluates", and the PR must say so.
7. **Database and block share rules exclude the whole workspace.** The rule table cannot map them to pages, and OB14(d) requires fail-closed.
8. **Audience `read_page` answers `not_available` for both non-eligible and non-existent pages.** Otherwise the tool tells callers whether a page exists.
9. **One migration file for the function, ledger column and trigger.** It is applied once, rolled back once, and with an empty ledger it is a no-op for phase 1a.
10. **The ledger is written before content is returned.** A failed write must not leave content that the post-time check cannot see.
11. **Reserve worst-case calls with no refund (Task 14).** Whether the runner exposes an attempt count is unknown, and a refund needs `runner.ts`, which is over the size limit. The cost is 4 page runs a day instead of up to 8. Revisit once an attempt count exists.
12. **One Lua script for all day budgets.** It fixes the non-atomic day seat and is exactly what OB30 needs later.
13. **New env parsing goes in `threads/threadFlags.ts`, not `config.ts`.** `config.ts` is already over the size limit.
14. **Chip titles come from the reader's already-loaded page store, with no fetch.** That satisfies OB18 (each reader's own access) and keeps OB4 (no request caused by a bot row).
15. **Phase 2 stops at a design document.** OB26 requires a re-submission before any code.
16. **Task 23 does not claim FC4.** The arithmetic shows full offload cannot meet it, so the task measures partial or CPU offload or records a deviation.
17. **Part 2's private model is a proposal only.** FC7 requires its own ruling, and bring-your-own for thread runs conflicts with OB9 and touches FB3 files.

## Unknowns (not resolved from the code)

- Whether `ai_autopost` and `osionos_messages_ai_answer_check` are applied in the live DB, and the env flag state on the VM.
- How the beta build sets `VITE_*` flags (build arg or env) and its deploy path.
- The real free allowance and today's usage on the shared key; `/key` does not report a free-request count.
- How the client knows the viewer is a channel admin (whether the channel model has a role field).
- The exact `visibility` values and the "live member" predicate of `osionos_workspace_members`. Task 8 reuses `osionos_ai_channel_context`'s expression, which must be read first.
- How synced blocks and linked database views are stored in `osionos_pages.content`: by reference or by copy. This decides what Task 10's projection must drop.
- What child-page blocks store: title only, or more.
- Whether any account holds or folds to "osio". The live census is pending.
- The exact signature of `osionos_username_reserved()`, and which runner applies groot SQL outside `migrations.txt`.
- Whether the Auto chain's per-run attempt bound is a named constant. Task 14 derives its reserve from it.
- The reasons recorded for C446/C447, which this plan did not need but must not contradict.
- Whether the BG `/\` image-source bypass fix is merged. Task 20's avatars depend on it.
- Whether the FC4, FC5 and C4 measurement records from Task 15 were ever put in a PR.
- Whether running 30B or partial offload on this host is acceptable to the desktop user, and how the workspace settings UI is hosted.
- What REST error body the bridge's data client returns when a trigger raises (needed for the 409 mapping).

### Critical Files for Implementation
- /mnt/storage/dlesieur/wt/oo-296 at 9af6d241d: `services/osionos-ai/src/threads/admission.ts` (admission, day seat, becomes `takeDayBudget`)
- /mnt/storage/dlesieur/wt/oo-296 at 9af6d241d: `services/osionos-ai/src/tools/readTools.ts` (base of the audience `read_page` and search)
- /mnt/storage/dlesieur/wt/oo-296 at 9af6d241d: `scripts/bridge-chat-ai.mjs` (`AI_IDENTITY`, `AI_HANDLES`, `postAiAnswer`, the `pages_changed` mapping)
- /mnt/storage/dlesieur/wt/oo-296 at 9af6d241d: `src/widgets/channel-messages/ui/MessageRow.tsx` (AI row rendering, badge, chips, OB4)
- /home/dlesieur/Documents/groot/docker-compose.public.yml (public flag pins, OB11)
