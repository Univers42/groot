# Restricting the callout kind at the parser (a word or one emoji) is out of scope

- Decided: 2026-11-18 · by devil (U3 push decisions, D1, [ADR 0062](../docs/adr/0062-a-callout-kind-becomes-a-class-only-when-it-is-a-word-nesting-past-32-levels-stays-text-and-the-preview-keeps-its-toodeep-path.md))
- Holds while: a callout's kind is stored as free text in `block.color`, and the host writes an emoji kind by default
  (`pageMarkdownSerialize.ts:94-96`)

## The concept

Close the callout-kind injection (ADR 0062 finding #1) in `parserBlockQuote.ts` / `parser.ts`: `> [!kind]` becomes a
callout only when the kind is a word or one emoji. Anything else parses as a plain quote.

## Why not

- **It changes stored data.** "One emoji" is a grapheme heuristic. ⚠️ is two code points, and flags, skin tones and
  ZWJ sequences are longer. Any kind the heuristic misjudges re-imports as a plain quote, and the page loses its
  callout with no message.
- **It fixes the wrong place.** The sink is the renderer that puts the kind into a class (`html.ts:147`,
  `react.tsx:285`). An AST that does not come from this parser would still reach that sink. The same applies to the
  host's copy of the engine (ADR 0062 L-2).
- **The sink fix costs nothing visible.** No stylesheet in the host uses a kind class: the host styles only
  `.md-callout` (`markdownDocument.css:39`).

## What would have to change

The kind becomes a closed list that the host owns, such as an enum column or a fixed set of icon names with a
migration for every stored `block.color`. Then the parser could reject anything outside the list without losing a
callout. The renderer check (ADR 0062 CK-1) stays in either case. Reopen this only with a devil ruling.
