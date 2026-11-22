# 0073. Inline Markdown stays linear at the shared matchers; no app-side length cap and no parse worker

- Status: accepted
- Date: 2026-11-22
- Deciders: devil (B PROCEED-WITH-CONDITIONS IM1–IM10; A, C, D BLOCK), 2026-11-21

## Context

- osionos#321: another member's inline Markdown parses on the reader's main thread, so one long
  text could freeze every reader. The issue's shapes (`"*a "`, 100k `[`) were already linear at
  engine 9ff30b1 (2.5 ms at 30 KB, 13.9 ms at 240 KB); its 7.5 s / 32.9 s figures predate the
  scan frame (ADR 0068 D path).
- Three shapes were still quadratic at 9ff30b1 (one parse, fresh node process, i5-13600KF):
  `<`×n then `>` 7003 ms at 128k chars; `<a@` + `b.`×n + ` >` 3152 ms; unclosed `[a](`×n 3444 ms,
  the same in html-subset mode.
- Chat is bounded by the server (`safeText(content, 8000)`, bridge the only writer); blocks are not
  (6 MiB body, shape-only validation).
- Full facts and verdicts: /mnt/storage/dlesieur/scratch/me-d/RULING-321.md.

## Decision

Fix at the shared matchers (option B), in both plain and html-subset modes:
- 827f96f: each "(" of a scan is paired once (findClosingParen in the scan frame).
- c0f0f0d: the autolink close search ends at the first whitespace or "<" (CommonMark), remembered
  in the scan frame; the email check is engine main's one-pass isEmailAutolink (82037ae).
- 80cb1f5: matchStackedEmphasis reads the next "\\" and "`" from the scan memo, found by the
  seeded property (not one of the issue's shapes).
- 9b8ace1: 827f96f paired every "(" of a scan up front, which cost the common text +5.11 %
  (IM5 FAIL on 5d5b206 (pre-rebase sha of 80cb1f5), "parse inline mixed 10K chars", r321/im5-abc-run1.txt; an interleaved
  bisect put +7.2 % on 7920926 (pre-rebase 827f96f) alone). A link now walks to its own ")" and the scan pairs the
  whole text only once those walks have read its length, so a scan reads the text at most three
  times and the common case pays no pairing.

## Evidence (conditions)

- IM2: scan steps 128K/32K are 4.00 for every listed shape, plain and subset
  (tests/inline-linear-steps.test.cjs fails above 4.5; at 9ff30b1 `[a](` fails with 15.99).
- IM3: 21-shape sweep at 8k/32k/128k, both modes: worst t(128k)/t(32k) 2.52, limit 6
  (r321/sweep/sweep-table.md); remeasured on the pinned 9b8ace1: worst 2.71 (hl, html subset),
  steps still 4.00 for every shape (r321/sweep/sweep-9b8ace1.tsv, steps-9b8ace1.txt). Ruling: the property is a seeded generator over `<[(@.*_`
  using the engine's tests/support/seededRandom.cjs instead of fast-check — same generated-input
  coverage, reproducible by seed, and no new dependency in a shared library.
- IM4: 1,102 inputs × ast/render × plain/subset against 9ff30b1: 18 differences, 9 inputs, all
  plain-mode autolinks holding whitespace or "<", each named in c0f0f0d.
- IM5: bench gate A/B on 9b8ace1 PASS, worst test +0.72 %, "parse inline mixed 10K chars" −3.74 %
  (after the FAIL at +5.11 % on 5d5b206 above).
- IM6: engine main 9b8ace1 CI green on attempt 1; osionos develop CI run 44977230145 success on 9eafe97a6 (2026-11-22).

## Alternatives considered

- **A, app-side length cap**: dead code in chat (≥ 8000) or truncation of accepted messages;
  does not bound pages unless N ≤ 2000. `.out-of-scope/inline-length-cap.md` in osionos.
- **C, parse worker**: needs an engine export anyway, async flash on hot paths, CPU still burns
  to the 3 s kill. `.out-of-scope/inline-parse-worker.md` in osionos.
- **D, A as a stop-gap then B**: blocked with A.

## Consequences

- IM8: the 8000 cap in bridge-chat.mjs stays; raising it or adding a writer without it needs a
  fresh measurement. IM9: no app-side cap, no worker.
- Two autolink spellings render as text now: `<http://a b>` and anything with "<" inside `<…>`.
- Reverse only by re-measuring with the scan-step counter; a red ratio is never re-run green.
