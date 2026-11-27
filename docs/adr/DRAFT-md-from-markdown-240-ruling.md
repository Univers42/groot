# DRAFT. A Markdown create route reuses the editor's own engine, linear first, or does not exist

- Status: proposed (draft, unnumbered). devil 2026-11-23, osionos #240: A BLOCK; B as written BLOCK; B′ PROCEED-WITH-CONDITIONS M240-1–M240-19; C BLOCK; D PROCEED (status quo).
- Date: 2026-11-23
- Code read: osionos worktree `osionos-am-l14`, markdown engine pin 9b8ace1.
- Full ruling: `/mnt/storage/dlesieur/scratch/md240/RULING.md` (findings F1–F8, conditions M240-1–M240-19, bench in `bench/`).

## Context

- The editor imports Markdown through `packages/markdown-engine/markdown/shortcuts.ts:34`, called at `src/services/page-actions/index.ts:170` with `sanitizeLinkBlockFields`. The design instead bundled the nested fork `src/shared/notion-database-sys/src/lib/markdown/shortcuts.ts:58`. That fork does not match the editor, and it loops forever on 6 of 6 tiny inputs (`parserBlockParsers.ts:175-188` consumes 0 lines, `parser.ts:84-91` never advances).
- The real engine is quadratic in the length of one line at `parser.ts:116` (heading) and `parserBlockParsers.ts:149` (table separator): 13.2 s and 8.0 s for one 128 KiB line. The bridge is one Node process, so one request stalls every user.
- Page create reads 6 MiB, caps the stored row at the edge's 131,072 B (`scripts/bridge-api.mjs:506`), and has no session rate limit (`takeToken` only at `:2488`, `:2566`). 128 KiB of Markdown amplifies to 1.5–2.5 MB of blocks.
- The bridge image has no build stage and copies only `scripts/bridge-*.mjs`. PATs are denied by default unless the route is listed (`scripts/bridge-pat-middleware.mjs:376-377`).

## Decision

Build B′: bundle `packages/markdown-engine` behind one app-side `markdownImportBlocks` shared with the editor's import. Commit it as `scripts/bridge-*.mjs` with a drift test. Land it only after the engine's two regexes are linear. Markdown is capped at 64 KiB before parsing, plus the edge check after conversion and a per-user rate limit. Authorisation reuses `handlePageCreate` with a uniform 404.

## Alternatives considered

- **A, the agent line converter**: BLOCK. One paragraph per line is not the editor's import, so the published contract would be false.
- **B, the nested fork**: BLOCK. It disagrees with the client and hangs forever (`.out-of-scope/route-markdown-via-nested-fork.md`).
- **C, bundle at image build**: BLOCK. It adds a build stage to a no-build image, and whether the build context has the submodule is unknown.
- **D, no route**: PROCEED. It costs callers the block-JSON authoring they already do. It is the fallback.
- **Swap the agent's converter for the engine**: out of scope (`.out-of-scope/agent-create-page-real-parser.md`).

## Consequences

M240-1–M240-19 are acceptance criteria. The ones most likely to be skipped:
- M240-1: linear regexes before the route merges.
- M240-7: missing and hidden parent are byte-identical, with an equal call count.
- M240-12: an absent submodule is a loud SKIP locally and a FAIL in the required CI job.
- M240-18: its own bridge promotion, with a rollback tag.
