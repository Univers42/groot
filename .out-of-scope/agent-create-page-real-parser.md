# Giving the bridge agent's create_page the full Markdown engine is out of scope (for #240)

- Decided: 2026-11-23 · by devil (osionos #240)
- Holds while: model-read text can steer `create_page`, and `toolCreatePage` writes without `validatedPageContent`

## The concept

Replace `markdownToBlocks` in `scripts/bridge-agent.mjs:141` (one paragraph per line) with the engine #240 bundles, so agent-created pages get headings, lists, tables and app blocks.

## Why not

- Model output is injection-steerable (`scripts/bridge-agent.mjs` ~:183). The engine emits app blocks (buttons, database references, embeds, whiteboards) and asset URLs from `osi*` fences and media syntax. Today the agent can only write text.
- `toolCreatePage` (`:219-240`) skips `validatedPageContent`.
- This is a capability increase for an untrusted writer. It belongs under the AI modes and osio-bot rulings, not inside a route change.

## Prior requests

- 2026-11-23 (#240 design): proposed as a follow-on of the bundle.

## Reopen when

A ruling on agent write capabilities exists. Its minimum bar: the engine restricted to text-only block types for model output, plus `validatedPageContent` on the agent path.
