# DRAFT. The schemeless-link check becomes an exact linear scan, not a whitespace guard

- Status: proposed (draft, unnumbered). devil 2026-11-23, osionos #240 S1: whitespace guard BLOCK; exact linear rewrite PROCEED-WITH-CONDITIONS S1-1–S1-9.
- Date: 2026-11-23
- Full ruling: `/mnt/storage/dlesieur/scratch/md240/RULING-S1.md`; evidence `devil-s1/run1.jsonl`, `devil-s1/run2.jsonl`, `sec/SECURITY.md`.

## Context

- `/^[^\s/]+\.[^\s/]+(?:[/?#].*)?$/i` at markdown-engine `inlineLinks.ts:29` (pin 31ce91f, also live pin 9b8ace12) backtracks. It takes 2.3 s at 64 KiB (quadratic) and 25.6 s at 8 KiB (cubic, `.?` + CR). The bridge is one process, and the client runs the same function on stored content (`EditableContent.tsx:220,914`, via `parserInlineMatchers.ts:145,220`).
- The proposed guard `!/\s/.test(href)` is linear, but it turns `example.com/my page`, `google.com/search?q=hello world`, `example.com?q=a b`, `example.com#a b` and a tabbed href from working `https://` links into relative links (`run1.jsonl`, q:2).

## Decision

Replace the regex with a scan that gives the same answers: no line terminator, then the longest `[^\s/]` prefix, then the first dot at index ≥1, then end, `/`, or `?`/`#` after a non-empty label. It differs from the regex on 0 of 5,257,437 strings and takes ≤0.83 ms at 512 KiB. It ships as its own develop unit ahead of #240.

## Alternatives considered

- **Whitespace guard**: BLOCK. It silently breaks spaced external links (`.out-of-scope/link-href-whitespace-guard.md`).
- **Out-of-band live web hotfix**: rejected. The exposure is about 7 months old and limited to availability for an in-tenant writer, while a live switch outside promotion carries more risk. The fix instead rides the next promotion, at most 7 days out.
- **Fix only inside #240's branch**: rejected. The client fix would then wait on 19 unrelated conditions.

## Consequences

S1-1–S1-9 are acceptance criteria. The ones most likely to be skipped:
- S1-2(a): the differential test keeps the old regex as its oracle.
- S1-8: the client fix ships within 7 days and does not wait on #240.
- S1-9: `matchBareUrl` rescans measure 171 ms at 64 KiB, which breaks M240-4. #240 does not merge until that is linear.
