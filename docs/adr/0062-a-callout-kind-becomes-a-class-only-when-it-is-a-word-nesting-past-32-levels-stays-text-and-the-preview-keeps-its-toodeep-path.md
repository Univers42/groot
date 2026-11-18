# 0062. A callout kind becomes a class only when it is a word, nesting past 32 levels stays text, and the preview keeps its tooDeep path

- Status: accepted. These are the three decisions that block any push of the U3 markdown engine (ADR 0058 U3-1 to U3-11).
  - D1, callout kind: PROCEED-WITH-CONDITIONS CK-1 to CK-8. Option (b) ships as a standalone `fix/callout-kind` from engine main.
  - D2, nesting cap: PROCEED-WITH-CONDITIONS NC-1 to NC-3. The value is 32. Past the cap the source stays as text.
  - D3, host tests EP5 and EP21: PROCEED-WITH-CONDITIONS TD-1 to TD-7. This is a contract change. The tooDeep path stays.
  - Push order: PROCEED-WITH-CONDITIONS PO-1 to PO-5.
  - Not ruled here: closing the sink that is live on osionos main (L-1). Ruled 2026-11-18 in ADR 0063.
- Date: 2026-11-18
- Deciders: devil (ruling); builder (engine `fix/callout-kind` and `feat/html-subset`, host worktree `osionos-u3`); coordinator (push order)

## Context

Engine paths are in `packages/markdown-engine` (Univers42/markdown-engine). Host paths are in osionos. The engine was
read at main `ca5dbee84` and at `feat/html-subset` HEAD `d2cc07f`. The host was read at worktree HEAD `46fb7e1ca`.
Logs are in `/mnt/storage/dlesieur/scratch/u3/logs/`.

- **Finding #1 (MEDIUM): the callout kind lands in the HTML unescaped.**
  - The parser takes any text except `]` as the kind (`markdown/parserBlockQuote.ts:96` on main, `parser.ts:247` on
    the branch).
  - `renderers/html.ts:147` puts the kind into the class attribute as is. The container case next to it escapes
    (`:179`), and the container parser only accepts a word (`parser.ts:150`).
  - `sec/callout-string-after.log`: both PoCs break out of the attribute on d2cc07f. The first is an `<img onerror>`
    inside a quote. The second is a plain paragraph whose text is `> [!warning" onclick=…]`.
  - No callout block is needed to carry the attack. A copy joins each block's raw text behind a per-type prefix with
    no escaping (`crossTextOps.ts:36-47`, `:89`), so a paragraph whose text starts `> [!` is enough.
  - `sec/chromium-after.log` re-parses the copied HTML in Chromium. Both callout cases are flagged, along with the
    three controls, which are flagged by design.
- **The sink is live.**
  - osionos main `0333d7966` pins engine `674dd65`, which has the same line (`html.ts:145`).
  - Copying a block selection puts `renderHtml(parse(markdown))` on the clipboard as `text/html` (`crossTextOps.ts:95`,
    `useCrossTextSelection.ts:284`). Any paste target that keeps the HTML receives the attribute.
- **Finding #2 (MEDIUM): the kind adds class tokens in React.**
  - `renderers/react.tsx:285` builds `className` from the kind. React escapes the value. But a space inside the kind
    adds classes the author chooses, on a README that every viewer sees.
  - `:389` does the same for containers. Containers are safe only because their parser restricts the kind.
- **Nothing consumes a kind class.**
  - The host styles only `.md-callout` (`src/features/ide/ui/markdownDocument.css:39`).
  - The only kind-class rules in the engine are in the playground (`playground/public/styles.css:393-409`).
  - The React renderer draws no icon (`react.tsx:284-299`).
- **The kind is user data.**
  - A callout block stores its kind as `block.color` (`markdown/shortcuts.ts:417`).
  - The host writes `> [!${block.color || "💡"}]` (`pageMarkdownSerialize.ts:94-96`), so an emoji kind is the default.
- **Nesting (findings #3 and #4, fixed).**
  - `markdown/nestingDepth.ts` keeps one module counter with `MAX_NESTING_DEPTH = 32`. Block levels
    (`parser.ts:310-317`) and inline levels (`parserInline.ts:86-96`) share it, and both release it in `finally`.
  - Past the cap, block input becomes one paragraph holding the remaining lines as a text node
    (`parserBlockContext.ts:30-34`). Inline input becomes one text node.
  - `tests/nesting-depth.test.cjs:33-53` pins the exact remainder.
  - A 2,000-deep quote throws RangeError on main and parses on the branch (`sec/stack-after.log`).
  - HTML elements stay capped at 16. The deepest DOM measured is 49 levels: `<b>` x15 plus 40 colour runs
    (`sec/depth-after.log`).
- **The census.**
  - It parsed 3,818 markdown files: package READMEs, groot and osionos. No parse changed at a cap of 32, 16, 12 or 8
    (`logs/census-cap{32,16,12,8}.log`).
  - The deepest file is 10 levels by the census's own count, which counts a list and its item separately
    (`probe/nesting-census.cjs`, its Caveat).
  - The trees compared were snapshots of the cap commit (`scratch/u3/engine-cap*`). They differ from d2cc07f in
    `parser.ts`, `parserInline.ts`, `parserInlineMatchers.ts` and `htmlSubset/tree.ts` (`diff -rq`).
- **The two host tests.**
  - On the new pin, canvas passes 5,700 of 5,702 tests (`logs/host-canvas-d2cc07f.log`).
  - The failures are exactly two:
    - EP5 (`tests/canvas/markdown-preview-shortcut.test.ts:139-144`) expects `tooDeep` for 5,000 list levels.
    - EP21/G8 (`tests/canvas/markdown-preview-worker.test.ts:69-80`) expects `structuredClone` to throw on 500 levels.
  - Both pass on the engine just before the cap commit and fail on the cap commit (`logs/ep5-ep21-engine-precap.log`,
    `logs/ep5-ep21-engine-cap.log`). They assert a crash the engine no longer has.
- **The tooDeep path.**
  - `src/features/ide/model/previewDocument.ts:91-96` maps any parse throw to `tooDeep`.
  - `:111-115` maps a failed post, which is the clone, to `tooDeep`.
- **The host pin was orphaned once already.**
  - The worktree gitlink `3727285` is on no remote ref and is not in d2cc07f's history.
  - Only the local branch `backup/html-subset-3727285` holds it: `git branch -r --contains 3727285` prints nothing.

## 1. Verdicts (axes: blast / reversibility / cost on failure / confidence, 1–5)

| Decision | Verdict | Scores, worst | Reason |
|---|---|---|---|
| D1 callout kind | PwC, option (b) | 3/2/**3**/2, cost | The fix goes at the shared sink, and no stored data changes. Option (a) silently turns stored callouts into quotes. Option (c) leaves a live injection. |
| D2 cap 32 | PwC | 2/1/2/**3**, confidence | Four times the headroom the corpus needs, far below any stack limit. The census ran on the cap commit, not the head. |
| D3 EP5, EP21 | PwC as a contract change | 2/1/2/2 | The precap and cap logs prove that the cap commit changed the contract. The tests are rewritten to the new contract, not deleted. |
| Push order | PwC | 3/**3**/2/2, reversibility | Engine main is a shared library, and a gitlink to a rebased commit dangles (`3727285`). |

## 2. D1: callout kind (option b)

- CK-1. **One predicate in one place.** A single exported function decides whether a kind is a word. It uses the
  container grammar `[A-Za-z][A-Za-z0-9_-]*` (`parser.ts:150`). Both renderers call it, and the container opener is
  built from the same pattern source (ADR 0063 V2). No second copy of the regex exists.
- CK-2. **A non-word kind adds no class.** The class list is `md-callout` alone. There is no fixed
  `md-callout-custom`: nothing styles it (see Context), so it would be a public class with no consumer.
- CK-3. **Both renderers emit the same class list for every kind,** callouts and containers alike (`html.ts:147,179`,
  `react.tsx:285,389`). The parity suites stay green.
- CK-4. **A word kind renders byte for byte as on engine main.** This branch adds no lowercasing and no other
  normalisation. Main already lowercases at parse (`parserBlockQuote.ts:116`), so `[!NOTE]` gives
  `md-callout-note` (example corrected by ADR 0063 V1).
- CK-5. **No author text enters the HTML string without `esc()`.** The class attribute value goes through `esc()`
  even though the predicate already limits it.
- CK-6. **No new attribute carries the kind:** no `data-kind`, no `title`, no `aria-*` built from it. Every attribute
  fed by author text is one more sink in clipboard HTML bound for unknown paste targets. The escaped container params
  that exist today are not widened.
- CK-7. **No parser or data change.** `parserBlockQuote.ts` and `parser.ts:247` keep `[^\]]+?`.
  - Test inputs: `> [!💡] t`, `> [!⚠️] t` (two code points) and `> [!x" onmouseover=y] t`.
  - Each one parses to a callout, reaches `color` through `shortcuts.ts` unchanged, and serializes back to the same
    line.
- CK-8. **RED first, from the PoCs.** Write these tests on `fix/callout-kind` before the fix:
  - the attribute breakout from `sec/callout-string.cjs`, in the HTML string;
  - a kind with spaces that adds a class, in React;
  - a kind containing `"`, `<`, `>` and `&`.

  All of them fail before the fix and pass after it. After the fix, `sec/run-chromium.sh` flags only the three
  controls.

## 3. D2: the nesting cap

**The value 32 is upheld.**
- No corpus file changed even at a cap of 8, so 32 is four times the needed headroom.
- 32 levels of recursion sit far below the point where main overflowed (2,000 quotes) and below the clone limit
  (about 350 levels on node 22, `previewDocument.ts:106`).
- A lower value buys nothing that was measured, and it is one constant if it ever must change.

**Keeping the rest as literal text is upheld.**
- Dropping it would remove author text from a page every viewer reads, with nothing to show that it happened.
- Text keeps every character (`nesting-depth.test.cjs:37,52`).
- Text renders through the text-node escape path, so markup in the remainder never runs (U3-5).
- Text shows the author where the cap was hit.
- The HTML subset's 16-element cap fails the same way (U3-5 g), so both caps share one direction.

Conditions:
- NC-1. **The primitive is tested on its own.** 32 calls to `enterNesting()` return true and the 33rd returns false.
  After 32 calls to `leaveNesting()`, it returns true again.
- NC-2. **The counter does not leak across parses.**
  - Test: in one module, parse a 2,000-deep quote, then a document whose deepest path is `MAX_NESTING_DEPTH − 1`.
  - The second tree must equal the tree that the same document gives in a fresh parse.
  - The `finally` blocks already cover the throw path by construction. This test covers the balance.
- NC-3. **The census runs again on the head.**
  - Run `census.sh` on the rebased head from PO-2, against the same head with the constant set to 8.
  - Pass: 0 changed.
  - The file list includes a synthetic file nested 9 levels deep, and it must show CHANGED, so the run cannot pass
    vacuously.
  - Save the log next to the old ones.

## 4. D3: EP5 and EP21

This is a contract change, not editing a test so a gate passes. The precap log passes and the cap log fails, and
nothing else differs between them. The house rule forbids making a broken behaviour pass. Here the asserted behaviour,
a crash, is the defect that #3 and #4 fixed.

**The tooDeep path stays.** It is not dead by construction:
- The catch in `parsePreviewDocument` is the only guard against any engine throw, from depth or anything else
  (`previewDocument.ts:91-96`).
- The browser owns the clone limit (`:106`). Another repo owns the cap, and the host reads it through a gitlink. A
  later pin that raises or removes the constant shows no diff in the host.
- Nothing proves a bound on AST depth under the cap for every node type. The 49 levels were measured on the probe
  inputs only.
- The path costs about 8 lines.

Conditions:
- TD-1. **The pin and both tests land in one commit.** The gitlink move, EP5 and EP21 go into one host commit. Its
  message names the contract change, the engine commit that made it, and this ADR. No bisect sees the new pin with the
  old tests.
- TD-2. **EP5 asserts the new contract.**
  - With the same 5,000-level input: `ok: true`; the remainder appears in the rendered output as text; the "too deeply
    nested" message is absent.
  - Add the largest list input under `PREVIEW_MAX_CHARS`, with the same assertions.
  - Rename the test to what it now proves.
- TD-3. **EP21 keeps its guard, with a tree built by hand.**
  - Call `answerPreviewRequest` with a `post` whose first call clones a hand-built nested object, deep enough that
    `structuredClone` throws RangeError.
  - Assert that precondition first.
  - Then assert exactly one delivered response: `{ id, document: { ok: false, reason: "tooDeep" } }`.
- TD-4. **The old input proves the change.** The 500-level list now arrives through the answering harness as `ready`
  with `ok: true`, and `structuredClone` of it does not throw.
- TD-5. **The new tests cannot pass vacuously.** The rewritten EP5 and TD-4 fail against `scratch/u3/engine-precap`.
  TD-3 passes against both engines. Save the logs.
- TD-6. **The Caveats tell the truth.**
  - `previewDocument.ts:81-88` and `:102-108` say a list overflows the parser at about 1,000 levels and the clone
    fails from about 350. On the new pin, the first is false and the second no longer has a known source input.
  - Rewrite both in the same commit: the engine caps nesting at 32, and tooDeep now means an unexpected engine throw
    or a clone failure.
- TD-7. **Host gates.**
  - Run typecheck, lint and full canvas one after another, each cited by its rc line.
  - Canvas has 0 failures, and the test count changes only by the tests added here.
  - If a wall-clock test fails under load, run it again alone and cite both runs.

## 5. Push order

The coordinator's order is upheld:
1. `fix/callout-kind` to engine main.
2. Rebase `feat/html-subset` onto it and run the engine gates.
3. The host pin, with EP5 and EP21.

- PO-1. **Step 1 ships alone.**
  - `fix/callout-kind` branches from `ca5dbee84` and holds only CK-1 to CK-8.
  - The U3-10 suites are green.
  - `git ls-remote origin refs/heads/main` prints the merged sha.
  - Engine CI on that sha is green. A check that did not run is reported as SKIP.
- PO-2. **Step 2.** After the rebase:
  - `grep -n 'callout-${node.kind}\|container-${node.kind}' markdown/renderers/` prints nothing, which shows the
    predicate survived the conflicts.
  - The U3-10 suites, nesting, fuzz and the U3-6 bench are green.
  - The `sec/` probes run again (callout-string, chromium, stack, depth, regress), and their logs are saved.
- PO-3. **The pin names only what the remote holds, and only what main holds before develop.**
  - The host gitlink names a commit that `git ls-remote` shows on the engine remote.
  - Before the host commit reaches osionos develop, `git merge-base --is-ancestor <pin> <engine origin/main>` returns
    0. The reason is `3727285` (see Context): a feature branch gets rebased.
- PO-4. **Host gates.** TD-7 runs on the commit that moves the gitlink.
- PO-5. **Nothing reaches osionos develop before main is at M′.** Any commit past M needs its own ruling before it
  goes live (ADR 0052 Q5). This ruling does not lift that.

## 6. Open, not ruled here

- L-1. **The live sink stays open** until osionos main pins an engine that meets CK-1 to CK-8.
  - The U3 feature carries the fix only when the feature itself lands.
  - A standalone host pin bump from `674dd65` to step 1's sha on osionos main also brings in `1d7496f`, `055639b`
    and `3d39f46` (`git log 674dd65..ca5dbee84`). Their effect on the host is unmeasured.
  - That bump needs its own ruling (Q5). Request it right after PO-1, not after U3.
  - Ruled 2026-11-18: ADR 0063, a pin-only hotfix on osionos main, PROCEED-WITH-CONDITIONS LP1 to LP19.
- L-2. **The host's copy of the engine has the same sink**
  (`src/shared/notion-database-sys/src/lib/markdown/renderers/html.ts:93`, `react.tsx:149`).
  - Nothing calls it today: only `parseInlineMarkdown`, `parseMarkdownToBlocks` and `detectBlockType` are imported
    (grep).
  - A future import of its renderers reopens #1.
- L-3. `pageMarkdownSerialize.ts:94-96` does not escape `]` or a newline in `block.color`, so such a kind does not
  survive the round trip. After CK this is an integrity issue, not an injection.
- L-4. `renderers/terminal.ts:126-128` prints the kind raw, control characters included. No host code calls it.
- L-5. `previewDocument.ts:91-96` labels every parse failure "too deeply nested". This predates U3.

## 7. UNKNOWN and SKIP

- SKIP: this ruling ran no test, build or probe. Every result above was read from logs the builder produced.
- UNKNOWN: a bound on AST depth under the cap for every node type. This is why the tooDeep path stays.
- UNKNOWN: whether real user documents nest deeper than the corpus. This machine has no user corpus.
- UNKNOWN: the census result on d2cc07f. NC-3 closes it.
- UNKNOWN: the worker clone limits in Chromium, Firefox and WebKit. Only node figures exist (`previewDocument.ts:106`).
- UNKNOWN: which real paste targets keep the class attribute and run it. The Chromium probe models a target that
  re-parses the HTML into a live page.

## Alternatives considered

- **(a) The parser accepts a word or one emoji.**
  - It would fix every renderer at once.
  - Cost: "one emoji" is a grapheme heuristic. ⚠️ is two code points, and flags and ZWJ sequences are longer. A
    misjudged kind silently re-imports as a plain quote and loses its callout, and the host writes an emoji kind by
    default. The sink also stays open for any AST that does not come from this parser.
  - Rejected: `.out-of-scope/callout-kind-restricted-at-the-parser.md`.
- **(c) Accept the risk.** That leaves a live MEDIUM injection into clipboard HTML. Rejected.
- **Escape the kind but keep the class for any kind (HTML only).** This closes the breakout. But React must still
  drop spaced tokens, so the two renderers would differ. Rejected for CK-3.
- **`md-callout-custom` for non-word kinds.** It has no consumer. Rejected (CK-2).
- **A `data-kind` attribute.** Rejected (CK-6).
- **A cap of 16 or 8.** The census changes nothing at either value, and no gain over 32 was measured. 32 leaves room
  for documents the corpus lacks.
- **Dropping the content past the cap.** That is silent loss of author text. Rejected (§3).
- **Deleting EP5 and EP21, or the tooDeep path.** That removes the only catch between an engine throw and the preview.
  Rejected (§4).

## Consequences

- The engine push order is binding: PO-1, then PO-2, then PO-4.
- The clipboard sink on osionos main stays open until ADR 0063 LP13 holds.
- A callout with a non-word kind loses its kind class in both renderers. No stylesheet uses such a class.
- A document nested deeper than 32 levels shows its innermost part as source text.
- tooDeep becomes rare. When it fires for a reason other than depth, its message misleads (L-5).
