# 0060. The page-cache flush counts wide characters in one flat pass, and is bound by 1.5 ms, not by 3 %

- Status: accepted. This re-rules ADR 0056 LL3, the threshold in LL4 and LL9's flush bounds (the L1a landing).
  - (a) a per-page cached size (a WeakMap keyed by object identity): BLOCK.
  - (b) as worded, which keeps the shipped exact scan under an absolute bound: BLOCK.
  - (b′) an exact counter whose cost does not grow with the number of wide runs, under an absolute bound:
    PROCEED-WITH-CONDITIONS FB1 to FB6. FB1, FB2 and FB6 come before develop; FB3 to FB5 come before live.
  - (c) an upper bound first, with the exact scan only near the ceiling or on a refusal: BLOCK.
  - LL8 (38 cells) and LL10 are unchanged.
- Date: 2026-11-17
- Deciders: devil (ruling); osionos main session and builder (live with it); benchmarker (FB3 to FB5)

## Context

ADR 0056 LL9 bounds the realistic flush, and the flush with the index refused, at a median within +3 % of base. The
builder reports it cannot be met. The L1a head is `feat/page-cache-rotation` dcf90bf5f: 16 commits on osionos develop
628f5de19, not pushed.

### What the builder measured (read, not re-run)

The figures are in the comment of `tests/bench/page-cache-flush.bench.ts`. They come from node, an in-memory storage
and an 8k `generatedTree`, in ABBA order against fcff64db5 with 5 rounds per side.

| Fixture | Base median | HEAD median | Over base |
|---|---|---|---|
| Latin-1 | 1.50–1.53 ms | 1.55 ms | +1.3 % |
| 📄 per page, the old charCodeAt loop | 2.25 ms | 3.28 ms | +47.7 % |
| 📄 per page, the shipped run-regex (`roomMaker.ts:24,30-36`) | 2.24 ms | 2.80 ms | +25.0 % (range +8.9 to +28.6) |

- A single native scan of an 869k two-unit string costs 0.26 ms, which is 11 % of the base flush.
- The builder's counter variants are in `stored-length-variants-{1,2}.log`. The run-regex wins on the shapes measured
  there, which are a 📄 per page, a single wide unit, and all-CJK text. None of them has many short runs.

### What the devil measured (2026-11-17)

- **Setup.**
  - The bench is `/mnt/storage/dlesieur/scratch/devil-l1a/ll9/core.js`, run once per engine, in docker with `--cpus=2`.
  - The engines are node 22.23.5, Chromium 147.0.7727.15 headless, and Playwright's Firefox 148, which is **not**
    stock 158.
  - The pages were cross-origin isolated, giving a 5 µs timer in Chromium and 20 µs in Firefox.
  - Each fixture is a synthetic page tree, not `generatedTree`. Its page count was chosen so that storedLength is
    958–959k, just under the 1,000,000 ceiling.
  - Base, HEAD-regex and HEAD-flat ran interleaved, rotating the order every round, with 41 rounds kept.
  - HEAD adds the index read, the count of the key and value, and the index write.
- **Load.** Another lane's Playwright container (`c7-e2e-sbf-fa`) started 9 s before the third run. The p95 values in
  that run are noisy (one Chromium base p95 is 10 ms); the medians match the second run to within 0.2 ms.
- **Correctness.** The two counters returned the same number on all five fixtures. The run aborts on any disagreement,
  and it did not abort.

Median flush increment over base (HEAD median − base median), in ms:

| Fixture (wide runs) | Chromium regex | Chromium flat | Firefox regex | Firefox flat | Base median, Chromium / Firefox |
|---|---|---|---|---|---|
| F-latin (0) | 0.00 | −0.08 | 0.02 | 0.00 | 2.04 / 2.96 |
| F-icon, a 📄 per page (3,666) | 0.29 | 0.56 | 0.44 | 0.66 | 5.04 / 3.08 |
| F-words, space-separated Cyrillic (22,932) | 0.98 | 0.70 | 0.68 | 0.92 | 4.31 / 2.70 |
| F-alternating, 24 runs per page (81,288) | 2.22 | 0.61 | 1.46 | 0.62 | 4.72 / 3.04 |
| F-dense, alternating ASCII and CJK (209,408) | **4.88** | 0.60 | **3.20** | 0.58 | 3.87 / 2.74 |

"Flat" is a non-global one-character test (`/[\u0100-\uffff]/`) followed by the charCodeAt loop.

The parts, timed alone in the browsers:

| Part | Cost |
|---|---|
| Index read and write | 0.015–0.025 ms |
| WeakMap pass, one `get` per page | 0.02–0.105 ms for 1.6k–3.7k pages |
| Identity diff, `===` per index | ≤ 0.005 ms |
| Run-regex count | 0.39 ms on F-icon, 3.83 ms on F-dense |
| charCodeAt loop | 0.55–0.92 ms on every fixture |

### Why +3 % was the wrong bound

- L1a needs a size for every value it writes. Three places use it:
  - the LB9 oversized test (`cacheWriter.ts:62-63`);
  - the LB7 allowance comparison (`cacheWriter.ts:68`);
  - the index, which the LB8 rotation sums (`rotation.ts:35-37`).
- Base computes no size at all.
- An exact size has to read every code unit once. That pass costs 0.4–0.9 ms in the browsers on a value at the ceiling,
  which is 6–34 % of the base flush. So +3 % forbade the ruled design on every workspace that holds a single character
  above 0xFF.
- ADR 0056's Conflict 2 predicted about +50 %. LL3 then assumed that a cheaper counter would close the gap, and nobody
  measured the floor.
- That error is the devil's. It is re-ruled here under LL9's own clause ("stop and re-rule"); the bound is not waived.

### The failure nobody mentioned

The run-regex's cost grows with the number of wide runs, at about 16–23 ns per run. The loop's cost is flat.

- On F-dense, HEAD-regex adds 4.88 ms in Chromium. HEAD-flat adds 0.60 ms.
- Real text has many short runs:
  - Cyrillic, Greek, Arabic or Hebrew prose, where every word is a run;
  - pasted prose full of curly quotes and dashes;
  - mixed CJK and ASCII.
- `storedLength` also runs at **pagehide**, in two places:
  - The KDS journal is counted against `KDS_JOURNAL_CHAR_CAP = 1_000_000` (`knownDatabaseJournal.ts:32,119`).
  - The flush runs from the pagehide listener (`pageStore.helpers.ts:322`), and inside `flushOnUnload` it runs before
    the keepalive push (`usePageSync.ts:268-269`).
- A pure two-unit alternation at the cap has about 333k runs. Its count would take about 7–8 ms with the regex. This
  figure is **extrapolated**, not measured.

## Decision

### (a) A per-page cached size: BLOCK

- **It rests on an unproven invariant.** No `PageEntry` reachable from the store may ever be mutated in place.
  - The flush serialises the store's own arrays (`pageStore.helpers.ts:297-319`).
  - The enqueue has 38 call sites in 8 non-test files.
  - The editors' write paths were not audited.
  - One in-place write was checked: `pageStore.helpers.ts:113`. It acts on a `structuredClone`, so it is safe. Nothing
    proves the rest. UNKNOWN = FAIL.
- **A stale size is never corrected.** It flows into the index, the LB7 comparison and the LB9 test, and stays there
  until the page's identity changes. An under-count lets the family grow past the allowance.
- **It does not clear +3 % with margin.**
  - The WeakMap pass alone costs 0.02–0.105 ms for 1.6k–3.7k pages. That scales to about 0.1–0.2 ms at 8k pages,
    which is 2–7 % of the browser base flush.
  - On top of that come the changed pages' own `JSON.stringify`.
  - The first flush of a session misses on every page and serialises the whole tree twice.
- **It is rung 7.** It adds a cache module with one caller.
- **To lift it:** a test that deep-freezes every `PageEntry` the store hands to the enqueue, across all 38 call sites;
  then a fresh ruling. This is the upgrade path if the whole increment ever has to go. It is not needed for (b′).

### (b) As worded, keeping the shipped scan: BLOCK

- With the shipped run-regex, F-dense adds 4.88 ms (Chromium) and 3.20 ms (Firefox) to the flush.
- The same counter runs over the KDS journal at pagehide.
- An absolute bound wide enough to pass that would be a bound on nothing.

### (b′) A flat exact counter under an absolute bound: PROCEED-WITH-CONDITIONS FB1 to FB6

- **The number is 1.5 ms of median increment per flushed key, at a value of storedLength 900k–1M.**
- **Why it is safe.**
  - **It buys the only input that LB7, LB8 and LB9 have on the flush.** The designs that avoid paying for it are
    blocked here.
  - **It lands in idle time.** The flush runs after a 750 ms quiet period, in `requestIdleCallback` with a 50 ms
    fallback (`pageStore.helpers.ts:35,384`). Base plus 1.5 ms is about 6.5 ms on the slowest base measured (5.04 ms). That is
    under half a 60 Hz frame and under a seventh of the 50 ms long-task line.
  - **It is bounded by the ceiling.** A key over 1,000,000 is marked once per session and then skipped before any
    stringify or count (`cacheWriter.ts:60`). The cost of a flat counter depends only on the length, so the bound
    covers the worst text and not only the typical one.
  - **At pagehide it delays the keepalive by at most 1.5 ms.** Whether a later keepalive loses anything is not
    asserted here. LL8 decides it: 0 lost across 38 cells, with the pagehide duration recorded.
- **Why 1.5 ms and not 1 ms.**
  - The flat counter's worst measured increment is 0.92 ms (Firefox 148, F-words).
  - A 1 ms bound would fail on noise, or on stock Firefox 158 being slower.
  - 1.5 ms leaves 0.58 ms for `generatedTree`'s heavier pages and for machine load.
  - The run-regex still fails it on F-alternating (Chromium) and on F-dense (both engines).
- **Why +3 % stays for F-latin.** L1a adds no count there: the one-character test returns at once on a one-byte string
  (0.000 ms in every engine).

### (c) Upper bound first: BLOCK

- **It saves nothing where the cost is.** LL3's fixture is about 951–965k characters. Twice that is about 1.9M, which is
  over the 1,000,000 ceiling, so the exact scan runs on every flush. The band where (c) must scan is 500k–1M
  characters, and realistic large workspaces sit in it.
- **The question asked: do LB5 and LB7 survive an over-estimate? Yes.**
  - LB5 is untouched: the room-maker measures storage exactly (`roomMaker.ts:81`), and its last attempt removes every
    key and the index.
  - LB7's ratchet is set from those exact sizes (`roomMaker.ts:111`). An over-estimate in the comparison at
    `cacheWriter.ts:68` errs on the safe side: the family never grows past the allowance, and a fitting key is dropped
    at worst.
- **LB8 and LB9 do not survive an over-estimate if it reaches them.**
  - If written to the index, the rotation evicts workspaces that fit (`rotation.ts:35-37`). On the fixture, 1.9M alone
    is over the ceiling, so every other rotatable key would go.
  - If used in the LB9 test (`cacheWriter.ts:63`), it marks the active workspace oversized. LB9 then never caches it,
    and it boots from the server every session.

## Conditions

1. **FB1. The counter is exact and flat.** Before develop; this replaces LL3's counter rule.
   - `storedLength` returns the charCodeAt loop's number for every string. S1's 20,000 random strings and the LB14
     boundary and surrogate tests in `tests/canvas/page-cache-room-maker.test.ts` pass with their assertions unedited.
   - Its cost does not grow with the number of runs. In the node bench (FB2):
     - its median on F-dense is at most 1.1 × the charCodeAt loop's median on F-dense;
     - its median on F-latin is at most 0.01 ms.
   - The comment at `roomMaker.ts:31-34` is replaced. The new one gives FB2's four numbers for the counter in use, and
     says why the run-regex was dropped: F-dense, and the pagehide journal count.
   - One shape that meets FB1 is a non-global one-character test, then the loop (measured above). It is not mandated.
2. **FB2. Four fixtures in the bench.** Before develop; this replaces LL3's fixture rule.
   - `tests/bench/page-cache-flush.bench.ts` runs base against HEAD on four fixtures built from `generatedTree`. Each is
     sized to a storedLength between 900,000 and 1,000,000, and the bench comment records the page count.
     - **F-latin:** today's Latin-1 tree.
     - **F-icon:** today's 📄-per-page tree.
     - **F-words:** titles and one text field of space-separated Cyrillic words, so every word is one run.
     - **F-dense:** one text field that alternates an ASCII and a CJK code unit, with at least 200 runs per 1,000
       characters.
   - The bench comment records the median and p95 of each, plus the counter-only medians that FB1 uses.
   - LL3's units are unchanged. The allowance, the ceiling and the J-C5 cap all count in `storedLength`.
3. **FB3. The flush bound in the prod build.** Before live; this replaces LL9's "realistic flush" bullet.
   - The setup is LL9's:
     - run by the benchmarker;
     - Chromium 147 and stock Firefox 158;
     - at least 5 rounds per side, in ABBA order;
     - the base is the build of the P1 live image.
   - The bounds:
     - **F-latin:** the median is within +3 %.
     - **F-icon, F-words and F-dense:** HEAD median − base median is at most 1.5 ms, on each fixture in each engine.
4. **FB4. The refused-index flush.** Before live; this replaces LL9's "index refused" bullet and the "3 %" in LL4.
   - The setup:
     - LL4's state, with the index write refused;
     - at least 3 cache keys totalling a storedLength of at least 900,000;
     - an F-icon write.
   - The bound: HEAD median − base median is at most 1.5 ms in each engine. The base is the same write, with no index.
   - Over it:
     - LL4's fallback is built: the measured sizes are kept in this tab's session while the index is refused;
     - LL4's test pins the fallback;
     - FB4 is re-run.
5. **FB5. LL9's other bounds are unchanged.**
   - The enqueue p95 is at most 1 ms at 10k.
   - The synchronous boot load's median is within +3 %.
   - The boot rotation task is at most 50 ms on a family over the ceiling.
   - "Going over any bound means stop and re-rule. A bound is never waived." still applies, now to FB3 and FB4 as well.
6. **FB6. The landing.** Before develop.
   - FB1 and FB2 land on `feat/page-cache-rotation` after LL7, as one unit.
   - The counter lives in `src/store/page-cache/`, so the following re-run on that head:
     - LL5: C7.3 assertions unedited, and the 26 mutants all killed;
     - LL6's gates, under a timeout, with logs kept.
   - One new mutant restores the run-regex. FB1's ratio, read from the bench run, must flag it.
   - LL8 runs later on the live candidate, which carries FB1. LL8's last bullet already requires that.

## Replacement text for ADR 0056

- **LL3. A realistic flush bench:** re-ruled by ADR 0060. It is FB1 (an exact, flat counter) and FB2 (four fixtures,
  F-latin, F-icon, F-words and F-dense, each at a storedLength of 900k–1M). The units do not change.
- **LL4, last bullet:** "LL9 measures its cost. If FB4's 1.5 ms is exceeded, the measured sizes are kept in this tab's
  session while the index is refused (ADR 0060 FB4)."
- **LL9. The prod-build ABBA, run by the benchmarker:** the setup is unchanged. The bounds:
  - the enqueue p95 is at most 1 ms at 10k;
  - the synchronous boot load's median is within +3 %;
  - the F-latin flush median is within +3 %;
  - the F-icon, F-words and F-dense flushes each add at most 1.5 ms of median (FB3);
  - the refused-index flush adds at most 1.5 ms of median (FB4);
  - the boot rotation task is at most 50 ms on an over-ceiling family.

  Going over any bound means stop and re-rule. A bound is never waived.
- **Conflict 2, "Not slower":** +3 % binds the boot load and the Latin-1 flush. Every non-Latin-1 flush is bound by
  1.5 ms of median increment instead (ADR 0060).

## LL8 and LL10

- **LL8 is unchanged:** 38 cells (RC9 28, J-C7 6, full origin 4), N ≥ 20 per cell, 0 lost, 0 reverts, and pagehide
  durations recorded.
  - Its own last bullet already re-fires it on the counter change.
  - FB1 is what keeps its content unchanged. With a flat counter, the journal's count costs the same whatever the
    content. Under the run-regex, the J-C7 near-cap cell would have needed a dense-runs journal to cover the worst
    pagehide count.
- **LL10 is unchanged.** The report sizes keys through `storedLength` (`report.ts:82`). An exact counter returns the
  same numbers, and LL10 asserts names and sizes, not timing.

## Measured, read, unknown

| Claim | Status | Evidence |
|---|---|---|
| Flush increments per fixture, both counters, Chromium 147 and Firefox 148 | Measured, one run per engine, synthetic pages | devil bench above (`browser-2.log`, `browser-3.log` beside `core.js`) |
| Both counters return the same number on five fixtures | Measured | The run aborts on disagreement and did not |
| WeakMap pass, identity diff and index IO costs | Measured, browsers and node | Same runs |
| +25.0 %, +47.7 %, +1.3 %, 0.26 ms | Read | The bench comment and the builder's logs; not re-run on `generatedTree` |
| Allowance is +∞ until a refusal; ratchet set from exact sizes | Read | `session.ts` `sessionOf`; `roomMaker.ts:81,111` |
| Flush at pagehide, before the keepalive | Read | `pageStore.helpers.ts:322`; `usePageSync.ts:268-269` |
| Journal counted at pagehide against 1,000,000 | Read | `knownDatabaseJournal.ts:32,119` |
| About 7–8 ms for the regex on a pure alternation at the cap | **Extrapolated** | 16–23 ns per run × about 333k runs |
| Stock Firefox 158, the prod build, `generatedTree` in a browser | **UNKNOWN** | FB3 measures them |
| Refused-index increment | **UNKNOWN** | FB4 measures it |
| A keepalive delayed by up to 1.5 ms loses nothing | **UNKNOWN** | LL8 decides it: 0 lost |
| No in-place mutation of a `PageEntry` | **UNKNOWN** | Blocks (a) |

## Residuals

- **R-FB1.** A workspace holding any character above 0xFF pays one flat pass per flushed key. That measured 0.56–0.92 ms
  in the browsers, which is +11–34 % of the base flush. Latin-1 workspaces pay nothing. The upgrade path is (a)'s lift
  conditions.
- **R-FB2.** The bound is per key. A flush that writes k dirty workspaces pays about k times the increment. Base's own flush
  grows with k too, so the ratio stays R-FB1's. A key over the ceiling is counted in full once per
  session (on its first flush), and then skipped (`cacheWriter.ts:60`).

## Risk

| Axis | Score | Why |
|---|---|---|
| Blast radius | 3 | One function. Every durable write's room-maker uses it, and so does the journal at pagehide. |
| Reversibility | 1 | A one-function change on an unpushed branch. Live is gated by FB3 to FB5 and LL8. |
| Cost on failure | **3 (worst)** | A slower flush in idle time and a later keepalive at pagehide. A miscount would mis-size the evictions, which is why FB1 requires the counter to be exact. |
| Confidence | 3 | One run per engine on synthetic pages, on a shared machine. Stock Firefox 158 and the prod build are unmeasured until FB3. |
