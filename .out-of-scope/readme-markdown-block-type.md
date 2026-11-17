# A new `markdown` block type for the README is out of scope

- Decided: 2026-11-17 · by devil (ADR 0058)
- Holds while: a supported client drops unknown block types and keys in raw mode.

## The concept

Store a markdown README in a new block type, or under a new flag key, rather than a `code` block with `codeView`.

## Why not

- An older client renders an unknown type as one paragraph (`ReadOnlyBlock.tsx:563-571`) and writes it out raw (`pageMarkdownSerialize.ts:66-67`), which re-parses into dozens of blocks.
- A new key is dropped by the page-file overlay (`blockOverlay.ts:164-168`). `codeView` survives (`:92`).
- This would change once every supported client keeps unknown types and keys through raw mode.

## Prior requests

- 2026-11-17 (osionos main session): profile page spec rev 1, units U3 and U4.
