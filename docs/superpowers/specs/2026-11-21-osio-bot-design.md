# osionos in-app bot ("our own Grok"): design draft

Status: draft for the user's approval. Nothing is built yet. It needs a devil ruling before any code.
Date: 2026-11-21. Recon: osionos develop 230dde4c5 (map in `/mnt/storage/dlesieur/scratch/osio-bot/recon.md`).

## Intent
The user wants a bot like Grok on X, but our own and inside osionos. A member @mentions it where people talk:
in chat channels, page comments, and later the editor. It answers in the thread, for everyone in the thread,
using the workspace's knowledge, and it is fast and free.

## What exists today (facts)
- **"@ai" thread answers in text channels**, behind flags `OSIONOS_THREAD_ANSWERS`, `OSIONOS_AI_THREAD_ANSWERS`
  and `osio.ai.channel`:
  - The answer is a **private draft** for the asker (`POST /api/ai/thread-runs`).
  - It goes public only when the asker clicks (`POST /api/chat/channels/:id/ai-answers`,
    `scripts/bridge-chat-ai.mjs:146-186`).
  - It is posted as the bot author `AI_BOT_AUTHOR` (`bridge-chat-ai.mjs:36-41`).
  - Guards: own run, same channel, < 30 min, unedited trigger, no channel change since the read, L0 moderation,
    one post per run. Devil C429–C454.
- Thread runs get **no tools and no pages** (`services/osionos-ai/src/routes/threadRuns.ts:20-21`). Context is the
  last 12,000 characters of the channel, with authors labelled You/AI/Member k.
- Limits: 6 per 10 min per channel, 200/day per workspace, 3 per member per channel, 40/day per member. They fail closed.
- Comments (`scripts/bridge-comments.mjs`) have no mentions and no bot author.
- The editor has `/complete` and the assistant dock only. There is no bot principal and no persona config.

## Goals
1. @mention the bot in a chat channel and get the answer **in-thread without a click**, in a channel where
   the members opted in.
2. The bot can **cite workspace pages**, but only pages **every member of the thread can read**. The answer is
   public to the thread, so reading what only the asker can see would leak.
3. The same in page comments: @bot in a comment thread gets a reply in the thread.
4. Fast: first tokens are visible to the thread while the answer streams. It runs on free models through the
   existing failover chain.
5. One persona per workspace: name, avatar and short instructions, set by an admin.

## Non-goals
- No autonomous actions: the bot never writes pages. Write tools stay behind the approval flow in the private
  assistant.
- No bot in DMs or voice. The bot does not proactively join conversations.
- No cross-workspace knowledge. No training on messages; models stay no-train (the platform rule).

## Anti-goals
- A bot that tells members what one member's private pages contain.
- A bot that someone can make flood a channel, or burn the platform's free-model quota.
- An answer posted under a member's name, or a member's text posted under the bot's name.

## Approaches
- **A. Auto-post thread answers (recommended for phase 1).** Keep the existing run, bot author and guards.
  Add a per-channel opt-in, set by a channel admin. In an opted-in channel the bridge posts the answer as soon
  as the run finishes, instead of waiting for the click. The asker's authority and budget still apply. Small:
  it reuses C429–C454. It needs a ruling, because removing the click removes the human review of what is
  posted.
- **B. A workspace bot principal.** The bot is a real member with its own token, budget and ACL, and it can be
  mentioned anywhere. It is more general, but it adds a new authority model (who does the bot act for?) and a
  new long-lived credential. Deferred until A shows real use.
- **C. The bot as an external API client** (PAT/MCP connector posting messages). Rejected: no streaming into
  the thread, and a token stored outside the app.

## Design (approach A, phased)

### Phase 1: chat, auto-post, read-only page context
- `osionos_channels.ai_autopost boolean default false`, a migration in groot `models/`, nullable-tolerant
  probe. Channel admins toggle it. The asker's draft flow stays for channels with it off.
- The bridge posts the bot message when a thread run reaches `done`. The guards stay: the trigger is
  unedited, nothing in the channel changed since the read, and L0 moderation passes. If a guard fails, the
  answer falls back to the asker's private draft, never to silence.
- Streaming: the bot message is inserted with `pending` state and updated as text arrives. Realtime gets the
  `message_updated` events. A partial answer is marked pending until done.
- Page context: thread runs get `search_workspace` and `read_page` read tools, restricted to pages readable by
  **every current channel member**. That is the intersection of `canReadPageRowAsMember` over the members, capped
  at the channel member count limit. Citations render as page chips; a chip for a page a reader cannot open
  shows as "restricted".
- Mention UX: the picker lists the bot first (persona name), the message renders a bot chip, and the answer
  notifies the asker.
- Limits: existing buckets. Auto-post adds one more cap, ≤ 1 bot message in flight per channel.

### Phase 2: page comments
- `osionos_page_comments.ai_run_id`, a comment-thread context function (the counterpart of
  `osionos_ai_channel_context`), a `/comment-runs` route, and a bridge post path announcing
  `discussion_changed`. The page context set is pages readable by everyone who can read the page. The
  simplest safe rule: the commented page itself plus pages with the same or broader audience.

### Phase 3: persona and workspace budget
- `osionos_ai_personas (workspace_id, name, avatar_url, instructions ≤ 2k chars)`. The instructions are
  prepended after the platform IDENTITY line and can never replace it.
- Workspace daily budget, charged together with the asker's.

## Left to the builder
Exact migration names, UI placement of the channel toggle, and the streaming update cadence (≥ 250 ms between
updates).

## Devil ruling (2026-11-21), conditions OB1–OB31
Full text: `docs/adr/DRAFT-osio-bot-ruling.md` (copy at `/mnt/storage/dlesieur/scratch/osio-bot/VERDICT.md`).

- **Phase 1a, auto-post in opted-in channels without page context: PROCEED-WITH-CONDITIONS, OB1–OB11.**
  - No link cards or images on bot messages (OB4). Any URL would otherwise load a favicon in every reader's
    browser, which leaks data with no click.
  - Fallback only to models that do not train on the data (OB9).
  - A platform-wide cap, once the real free allowance has been measured, before auto-post goes on in the public
    deployment (OB10).
- **Streaming into the channel: BLOCK.** The asker can still watch a private stream while the channel shows a
  textless "answering" notice (OB12).
- **Phase 1b, page context: BLOCK until OB13–OB21.**
  - The rule must be fixed, not a per-member loop: a page qualifies only if it is shared or public in the
    channel's workspace, with no share rule anywhere in its chain, and only if every channel member belongs to
    that workspace.
  - The check is repeated at post time for every page the run read (OB14, OB17).
  - Reason: `canReadPageRowAsMember` ignores share rules, and public channels are readable by the whole workspace.
- **Phase 2, comments: BLOCK until OB22–OB26 and a new submission.**
- **Phase 3, persona and budget: PROCEED-WITH-CONDITIONS, OB27–OB30.**
- **Approach B: BLOCK until it comes back as its own design. Approach C: BLOCK.**

## Open questions for the user
1. The bot's default name: "osio"? Or something else (the handle `@ai` keeps working as an alias)?
2. Auto-post default for new channels: off (recommended) or on?
