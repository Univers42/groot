# DRAFT. AI writes may auto-apply only for add_blocks, rename and create, only from trusted provenance, with the run request's own token; bypass, auto-archive and auto-build stay blocked; C227 stays in force

- Status: proposed (draft, unnumbered). devil: overall PROCEED-WITH-CONDITIONS (AM1–AM20) · manual PROCEED · plan, accept_edits, auto PROCEED-WITH-CONDITIONS · bypass BLOCK · auto `archive_page` BLOCK · auto `build_plan` BLOCK.
- Date: 2026-11-22
- Deciders: devil (ruling); the osionos-ai builder and the operator (live with it)
- Design: `docs/superpowers/specs/2026-11-22-ai-modes-design.md`
- Full ruling: `/mnt/storage/dlesieur/scratch/me-d/RULING-ai-modes.md`

## Context

Paths are under `apps/osionos/app/services/osionos-ai/src/` unless prefixed `app/` (= `apps/osionos/app/`).

- Every AI write today is a card: tools write nothing and hold no token (`approvals/toolSet.ts:14-19`); the write runs on the decide request with that request's token (`approvals/execute.ts:300`), then always starts a continuation run (`approvals/execute.ts:239-293`).
- A run holds no credential for its tools. The run route reads the bearer (`routes/runs.ts:200`); the runner uses it only for attachments (`runs/runner.ts:266`). Continuations get none (`approvals/execute.ts:273-280`). Runs last ≤120 s (`runs/streamPump.ts:27`), ≤8 min for research (`tools/limits.ts:39-43`); the session TTL is 3600 s (`config.ts:36`).
- C227 exists only in code and commit text: "no rewrite of an existing block: that one waits for the strict page version" (`tools/writeTools.ts:11-27`, `tests/mcpApprovals.test.ts:115-117`, commit 9dd6127a3). It is a concurrency rule. Approval-only is a separate invariant (the single-gate design). `docs/adr/DRAFT-more-free-ai-ruling.md` conflates them.
- Block ids are minted by the service (`approvals/execute.ts:106`) and inserted verbatim by the atomic, idempotent `osionos_page_append` (`models/osionos-page-version-migration.sql`); they are not stored in the approval result.
- Strict page version is off (`OSIONOS_PAGE_STRICT_VERSION` unset in every env file read; `app/scripts/bridge-api.mjs:4317-4329`), so a content PATCH without `baseVersion` is last-writer-wins.
- The page refresh after a write advances the sync base before the dirty check (`app/src/store/pageStore.actions.ts:209`), then `resolveFetchedPage` either replaces unpublished keystrokes or lets the next PATCH erase the AI's blocks (`app/src/store/sync/mergeServerPages.ts:129-147`). Traced, not executed. It affects manual clicks today.
- Taint covers web and MCP only (`mcpClient/taint.ts`, `web/tools.ts:131`). Page content written by other members is read untainted; C119's `otherAuthor` marking exists only on the MCP endpoint (`mcp/tools.ts:183-188`, `tools/types.ts:94-95`); the bridge has no last-editor column (`app/scripts/bridge-api.mjs:1300`).
- Decide, resume and undo share the runs rate bucket, 20/min (`routes/approvals.ts:85,131,221`, `rateLimit.ts:84-91`, `config.ts:47`).
- Unarchive cascades to every writable descendant, including ones archived earlier (`app/scripts/bridge-api.mjs:4202-4208,4371`). Plan undo keeps databases (`builders/undo.ts:20-24`).
- Beta shares the prod API and bridge, so a service flag cannot be beta-only.
- Unknown when this was written: U1 and the refresh defect were traced from source, not executed; the full list of content writers that omit `baseVersion`.

## Decision

The approval-only invariant is amended by name for run-origin writes, and only these: `add_blocks`, `rename_page`, `create_page` auto-apply in `accept_edits` (anchor subtree) and `auto` (conversation's workspace) when the conversation has trusted provenance, the user is on the server-side allowlist, and the run holds its own request's token. Everything else is a card. C227 stays in force: undo of an auto append is a version-preconditioned removal of the recorded ids, refused on "changed since". `bypass`, auto `archive_page` and auto `build_plan` are BLOCKED.

The conditions AM1–AM20 are the acceptance criteria: token in closure only (AM1), one factored gate (AM2), read-time sticky provenance taint (AM3), outcome as tool result (AM4), own rate bucket (AM5), caps and coalescing (AM6), recorded ids and `decided_by` migration (AM7), changed-since inverses (AM8), abort never strands a claim (AM9), server-side mode (AM10) and anchor (AM11), no cross-workspace (AM12), non-user runs manual (AM13), plan mode drops write/MCP tools (AM14), merge-safe refresh (AM15), no LWW content writer (AM16), closed auto allowlist (AM17), per-user allowlist (AM18), visible audit (AM19), executed evidence gate (AM20).

## Alternatives considered

- **Keep approval-only**: no new risk, but refuses the feature the user asked for on 2026-11-22; the bounded subset is safe under AM1–AM20.
- **G1 as specified (web/MCP taint only)**: leaves a zero-click path where a member's edit to a shared page makes another user's AI copy private text into that page; undo cannot recall a disclosure.
- **A run-scoped service credential**: a second credential that outlives the request and skips the session cut-off; rejected.
- **Strict version only, no client fix**: closes LWW writers but not the base-advance defect (`pageStore.actions.ts:209`) or rebase exhaustion (`app/src/store/sync/pageConflict.ts:76`).
- **Bypass auto-running `mcp_call`**: no inverse, arguments can carry workspace text to a third party, `readOnlyHint` is self-declared; see `.out-of-scope/ai-bypass-mode-auto-mcp-call.md`.

## Consequences

- The osionos-ai builder owns AM1–AM14, AM17–AM19; the app sync owner owns AM15; the operator owns AM16 and AM18 (allowlist empty in the public overlay by default).
- AM15 fixes a defect that manual clicks already hit; it ships regardless of modes.
- A new `decided_by` column (additive, nullable) on the approvals table.
- `archive_page` auto lifts with a captured-descendants inverse (B2); `build_plan` auto lifts with a database inverse (B3); `bypass` lifts only with a new ruling (B1).
- Residual: ownership-based trust trusts what the user pasted themselves; rename undo has a one-round-trip TOCTOU; coalescing is per step only. Each carries a Caveat line in the ruling.
- Reverse this the day an auto write is shown to land from untrusted input, or a loss of user or AI content is reproduced: set the allowlist empty.
