# Writing new `:::` container kinds into stored markdown is out of scope

- Decided: 2026-11-19 · by devil (ADR 0064, PS11)
- Holds while: the live engine pin turns an unknown container kind into its bare children.

## The concept

The page-shells plan (Phase 1.4) teaches the markdown engine `::: row|stack|grid {cols=3 min=16rem gap=4 stack=mobile}` and `::: section {surface=… padding=…}`. It also has `pageMarkdownSerialize.ts` emit these forms, so that stored `.omd` and raw-mode text read like the layout the user sees.

## Why not

- The probe ran on both the live engine 674dd65 and develop's 08301d0. On each, `::: grid {cols=3}` wrapping two `:::column` parses to two orphan `column` blocks, and the `column_list` is lost (`markdown/shortcuts.ts:333-334`).
- Beta and live share production data (ADR 0040). A live client that re-saves a beta-written file therefore keeps the broken structure, and there is no undo.
- `:::columns {layout=grid cols=3}` and `:::column 0.5 {span=2}` keep the structure and the ratio on both pins. Layout already round-trips through the overlay `style` (`blockOverlay.ts:124`, also on main). The canonical form loses nothing.
- Reading the sugar is allowed under PS13–PS15. It is normalised to `columns`/`column` with `style`.

## Prior requests

- 2026-11-19 (osionos main session): plan `delightful-dazzling-kay.md`, Phase 1.4.

## Reopen when

Every engine pin that serves production data maps `row|stack|grid|section` to a `column_list` that carries `style`, shown by the same container probe run against the live pin.
