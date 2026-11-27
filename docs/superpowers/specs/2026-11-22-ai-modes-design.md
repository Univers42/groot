# osionos assistant modes: design

Status: draft, 2026-11-22. A devil ruling is required before any code: this reverses the "writes stay approval-only" rule (C227 as the more-free-ai ruling cites it).

## Why

The user (2026-11-22): the assistant should have Claude-Code-style modes (manual, accept edits, plan, auto, build, bypass permissions). The goal is that a user can let the AI apply changes directly instead of accepting each suggestion card. Today every write is a card. A ten-block edit costs ten clicks, and a run stops after each proposal ("waiting for approval: stop"). That round trip is also why the user reads some runs as "silent stops".

## Facts today (osionos-ai, read 2026-11-22)

Paths are relative to `apps/osionos/app/services/osionos-ai/src/` unless they start with `W/`, which stands for `apps/osionos/app/src/`.

- **Write tools.** `create_page`, `rename_page`, `archive_page` and `add_blocks` are always available (`tools/writeTools.ts:11-27`). `build_plan` is added when `OSIONOS_AI_BUILDERS=on`.
  - Their arguments are whitelisted: `visibility`, `collaborators`, `properties` and `archivedAt` are dropped.
  - No tool deletes, and no tool rewrites an existing block.
- **One gate.**
  - Every write goes through `proposeWrite` (`approvals/propose.ts:49`), which inserts a `pending` row.
  - Only `decideApproval` (`approvals/execute.ts:300`) reaches the bridge, after the conditional claim `pending→executing` (`approvals/repo.ts:117`).
  - The bridge call uses the deciding request's session token, which is never stored (`execute.ts:24-35`).
- **Access tokens.** Scopes are `read` | `write_approval` (`routes/accessTokens.ts:48`). A token can never decide; decisions require a user session (`routes/support.ts:17`).
- **Undo.**
  - Only `build_plan` has an undo route (`routes/approvals.ts:205`), and nothing in the UI calls it.
  - `create_page`, `rename_page`, `archive_page` and `add_blocks` cannot be undone.
- **Taint.** After a third-party MCP result or web content enters a conversation, later write cards carry `influencedBy` (`approvals/toolSet.ts:73-79`, C286/C359).
- **Rate limits.**
  - Decisions are limited to 20 per minute per user. Builds are limited to 10 per day.
  - Outside-agent writes are limited to 10 per minute per token.
  - No setting changes approval behaviour today.

## Goals

1. Each conversation can be in one of the modes below. The user picks the mode in the chat composer, and it is stored server-side on the conversation.
2. In auto modes, writes run without a card but still produce the same approval row, now with `status=executed` and `decidedBy=mode:<name>`. The audit trail is unchanged.
3. Every auto-applied change can be undone from the chat, one step per turn ("Undo this turn's changes").
4. Modes only narrow what the user's own grant already allows. They never widen it.

## Non-goals

- The scope × capability × verb grant model (Cloudflare-style): that is project 2b, a later ruling. Modes ship against today's implicit grant (the user's own bridge rights).
- Auto mode for access tokens or outside MCP agents. Tokens stay `write_approval` and always produce a card.
- New write tools: no delete, no block rewrite. Those wait for the strict page version (C227's other half).

## Anti-goals (a failure even if it works)

- Text from a web page or MCP result writes to the user's pages without a click (prompt injection).
- A mode can be switched by the model, by a token, or by page content.
- A run loops and creates hundreds of pages.
- A change the user cannot find or undo.

## Modes

| Mode | Write tools offered | What runs without a card | Still a card |
|---|---|---|---|
| `manual` (default, today) | all | nothing | every write, every `mcp_call` |
| `plan` | none (read tools only) | — | The model ends with a plan. "Run this plan" starts the next turn in `accept_edits`. |
| `accept_edits` | all | `add_blocks`, `rename_page` and `create_page` inside the anchor page's subtree | `archive_page`, `build_plan`, anything outside the subtree, every `mcp_call` |
| `auto` | all | every write tool, including `archive_page` and `build_plan`, on pages the user can edit | every `mcp_call` |
| `bypass` | all | everything `auto` runs, plus `mcp_call` to servers the user already enabled | — (still capped, see Guards) |

"Build" from the user's list is `auto` with builders on. It is not a separate mode; the UI shows it as the `auto` row's description.

## Guards (apply in every mode)

- **G1 Taint downgrade.** When a conversation is tainted (a `web:` or `mcp:` origin is in `influencedBy`), every write in that turn and every later turn goes back to a card, whatever the mode. The card says why. Only a user message that clears the taint lifts this. Clearing means starting a new conversation; there is no override.
- **G2 Caps.**
  - At most 25 auto-applied writes per turn and 200 per user per day (config, opt-in to raise).
  - Over the cap, the write becomes a card and the run continues.
  - Auto-applied writes count against the existing 20 decisions per minute.
- **G3 Mode authority.** The mode is a column on the conversation. Only `PATCH /api/ai/conversations/:id/mode` with a user session can set it, and it needs a recent sign-in for `auto` and `bypass`. The model has no tool for it. Tokens get 403.
- **G4 Undo before auto.** No write tool runs automatically until it has an inverse:
  - `create_page` → archive the page;
  - `rename_page` → restore the previous title, captured at execution;
  - `add_blocks` → remove exactly the added block ids;
  - `archive_page` → unarchive;
  - `build_plan` → the existing `undoBuild`.
  - An inverse that would clobber a later human edit is refused with "changed since". It is never forced.
- **G5 Visibility.** Each auto-applied write appears in the thread as a compact "applied" row with an Undo link. There is also a per-turn "Undo all" button. Nothing is applied silently.
- **G6 Never grantable.** A code constant lists what no mode can reach, and a test asserts no tool maps to it: sharing/permissions, delete-forever, account, billing, tokens, workspace membership.
- **G7 Flag.** `OSIONOS_AI_MODES` (service) and `osio.ai.modes` (web) are both off by default. Beta turns them on first; live waits a week.

## Approach chosen

**Server-side auto-decide.**
- In auto modes, `proposeWrite` inserts the row and then calls the same `decideApproval` path immediately, using the run's in-memory session context.
- Rejected: client-side auto-click. The run stops at each proposal, so the latency and silent-stop look would stay, and a closed tab would strand rows.
- Rejected: a separate auto-write path. A second gate is what the single-gate design exists to avoid.

## Unknowns (for the ruling)

- **U1.** Does a run hold the user's session token in memory for its whole life? Today only the deciding request does (`execute.ts:24-35`). If not, auto-decide needs a short-lived, run-scoped bridge credential. That is a security design of its own.
- **U2.** C227's exact text is not on disk. Code reads it as "no block rewrite"; docs read it as "writes approval-only". The ruling should restate it.
- **U3.** `add_blocks` inverse: are block ids stable through the outbox round trip, so a removal hits exactly what was added?
- **U4.** Concurrency: an auto write and the user editing the same page at once. Is the bridge write last-writer-wins on the page?

## Done when

- Unit tests cover the mode × tool × taint matrix, the caps, G3's refusals, and every inverse in G4, including "changed since".
- Playwright, production build, beta: an `accept_edits` turn applies 3 blocks with no card, Undo removes them, and a tainted turn shows cards.
- devil quality is green and files stay under 300 lines.
