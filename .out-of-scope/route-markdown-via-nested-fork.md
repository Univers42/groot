# Converting Markdown on the server with the notion-database-sys markdown fork is out of scope

- Decided: 2026-11-23 · by devil (osionos #240)
- Holds while: the editor's import uses `packages/markdown-engine`, and the fork's `parseParagraph` can consume 0 lines

## The concept

Bundle `src/shared/notion-database-sys/src/lib/markdown` into the bridge so that `POST /api/pages/from-markdown` turns Markdown into blocks the same way the app does.

## Why not

- The app's import does not use that fork. It uses `packages/markdown-engine/markdown/shortcuts.ts:34` via `src/services/page-actions/index.ts:170`, so the route would produce different blocks than the editor.
- The fork flattens inline marks and turns tables into `"[table]"`.
- `parserBlockParsers.ts:175-188` can return with 0 lines consumed, and `parser.ts:84-91` then loops forever. Measured: 6 of 6 tiny inputs hang and OOM at 512 MB in about 5 s.

## Prior requests

- 2026-11-23 (#240 design, option B): bundle the fork as `scripts/bridge-markdown-engine.mjs`.

## Reopen when

The editor's import itself switches to the fork, and the fork has a test proving every parse step advances.
