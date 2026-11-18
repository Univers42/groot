# 0063. The callout-kind fix goes live as a pin-only hotfix on osionos main once its own gates hold, and never waits for P1

- Status: accepted. This is ADR 0062 L-1: how the callout-kind fix reaches the live osionos build.
  - Path (a), a pin-only hotfix H on main: PROCEED-WITH-CONDITIONS LP1 to LP19.
    - H deploys onto whatever main is live once LP1 to LP10 hold. It never waits for P1.
    - Branch A: P1 is not live yet. H sits on 0333d7966, and develop takes it by a real merge (LP16, LP17).
    - Branch B: P1 went live first. H sits on M′, and P1's evidence is untouched (LP19).
  - Path (b), the pin on develop past M′, live with P1: declined.
  - The three builder deviations from 0062 CK: upheld (V1 to V3).
- Date: 2026-11-18
- Deciders: devil (ruling); builder (H, the gates, the merge into develop); coordinator (push, deploy, groot pin, 0052
  bookkeeping)

## Context

Engine paths are in `packages/markdown-engine` (Univers42/markdown-engine). Host paths are in osionos, read in the
worktree `/mnt/storage/dlesieur/wt/osionos-u3`. Logs are in `/mnt/storage/dlesieur/scratch/u3/`. Every ref below was
read on 2026-11-18.

- **The sink is live in two places.** Engine `674dd65` builds the callout class from the raw kind:
  `renderers/html.ts:145` and `renderers/react.tsx:284` (`git grep 'callout-${node.kind}' 674dd65`).
  - Clipboard: `crossTextOps.ts:95` runs `renderHtml(parse(markdown))` and `useCrossTextSelection.ts:284` writes it
    as `text/html`. A paragraph whose text starts `> [!x" …` breaks out of the attribute (0062 Context).
  - Chat: `assistantMarkdown.ts:83` (`renderAssistantMarkdown`) and `citedAnswer.ts:181` call `renderReact` on
    model output. A kind such as `note fixed inset-0 z-50` adds those utility classes to the callout: a UI redress
    inside osionos, reachable by anyone who can steer the assistant's text.
- **Live and candidate refs.**
  - `git ls-remote`: osionos main `0333d7966`, develop `6de257335` (M′).
  - The gitlink is `674dd65de` in 0333d7966, in M (`e963abc83`) and in M′.
  - Engine main is now `08301d0`. `git merge-base --is-ancestor e5253d2 08301d0` returns rc 0.
- **The fix is e5253d2.**
  - `gh run view 44245031852`: push to main, headSha `e5253d2dbcd1…`, conclusion success.
  - `STEP1.md`: RED at `5f2c958` rc 1, GREEN 11/11, `npm run check` 121 tests rc 0, size check 0 new violations,
    `sec/chromium-step1.log` flags the controls only.
  - `logs/step1-kind-parse-diff.log`: 20000 inputs, 5577 with a word kind, `parse` and blocks equal, HTML equal for
    word kinds.
- **The riders.** `git log 674dd65..e5253d2` has 7 commits: `1d7496f` perf(parser), `055639b` SonarCloud,
  `3d39f46` test loader, two merges, `5f2c958` and `e5253d2`. 17 files, +352 −136.
  - The riders touch no file the fix touches. `comm -12` of the two `git diff --name-only` lists is empty.
  - `055639b` and `3d39f46` change `.sonarcloud.properties`, the engine's own `Dockerfile`, `bench/`,
    `playground/public/app.js` and `tests/`.
  - None of these is in the host's import graph:
    - the host aliases the engine's `.ts` entries (`tsconfig.json:36-43`, `vite.config.ts:119-143`);
    - `tsconfig.markdown-engine.json:9` excludes bench, tests, scripts and playground;
    - `git grep 'markdown-engine/\(playground\|bench\|tests\)'` finds 0 hits;
    - `Dockerfile.prod:19,53` uses only the host's `tsconfig.markdown-engine.json`.
  - Tailwind may still read them. `global.css:13` imports Tailwind with automatic source detection, and
    `tests/callout-kind.test.cjs:32` at e5253d2 contains `fixed inset-0 z-50 bg-white`. 0052 Q3 already treats
    `tests/` as a build input. Whether the submodule is scanned is unmeasured.
- **1d7496f adds two module-level caches keyed by the whole text.**
  - The caches: `failedOpenersCache` (`parserInlineMatchers.ts:514-520`, 4 texts) and `bracketCache`
    (`parserInlineUtils.ts:40-61`, 4 texts).
  - When an emphasis opener finds no closer, every unpaired inner opener it passed is also marked failed (`:596`
    pops the paired ones).
  - That is correct only if a failed outer scan implies that each such inner opener fails on its own scan. Nobody
    has proven it. No log in `scratch/u3/logs` names `674dd65` or `1d7496f`, so no differential against the live
    engine exists.
- **The bench did not compare against live.** STEP1's abGuard ratios (0.974–1.060) are against `bench/reference.json`
  ref `923924c`, which is 18 commits before `674dd65` (`git rev-list --count 923924c..674dd65`).
- **P1 is held.**
  - 0052 Q2: main fast-forwards to M′.
  - Q3: O2–O4 transfer from M to M′ only on byte-identical `dist/`.
  - Q6: CI on M′'s sha.
  - Q7: the gesture, with arms 0333d7966 and M′.
  - Q7 was re-ruled on this branch at d1305258 (0052, "Q7 re-rule"): PROCEED-WITH-CONDITIONS Q7a to Q7g, with O7
    and O8 held until those hold.
  - Q7c's run (N ≥ 150 per arm, the M′ arm serving `q3/dist-rc9-mp`) has no result yet. `p1-cand/q7b/out/` was
    created at 07:00 CET today and is empty.
  - Q7e measures the menu's list latency after typing. The inline parser runs on every keystroke, so the engine
    pin is an input to Q7e.
  - 0062 PO-5 holds osionos develop at M′.
- **A main→develop merge that keeps 674dd65 is already caught.** 0057 BR13b (`:280`) requires `--is-ancestor` inside
  the submodule for a main-side gitlink hunk.
- **A push to main publishes.** `node-pages.yml` publishes one rolling release, built from the newest main that
  built. `src/editor-client` imports no engine module at 0333d7966 (`git grep`: 0).
- Unknown when this was written:
  - whether chat is enabled on the live site;
  - which paste targets run a clipboard attribute (0062 §7);
  - whether `main-0333d796-site` is still on the VM, and where its rollback script is (`find` on this machine
    found no `rollback-web-*.sh`).

## Decision

### 1. Verdicts (blast / reversibility / cost on failure / confidence, 1–5)

| Item | Verdict | Axes | Worst |
|---|---|---|---|
| (a) H = live base + gitlink `e5253d2`, deployed once LP1–LP10 hold, onto whatever main is live | PwC LP1–LP19 | 3 / 2 / 3 / 3 | cost and confidence: `1d7496f` is unmeasured against live |
| (b) pin on develop past M′, live with P1 | declined | — | the sink stays open with no date |
| V1–V3, the builder's deviations | upheld | — | — |

H's axes in detail:
- **Blast radius 3.** H touches every engine call in the host: editor inline parse, paste, clipboard and chat.
- **Reversibility 2.** Rolling back is one image switch while P1 has not served. Reverting main republishes the
  rolling release.
- **Cost on failure 3.** A wrong parse from `1d7496f` renders wrongly, and paste-import stores what it parsed.
- **Confidence 3.**

What each path costs P1's evidence (the coordinator's question):
- **(a), branch A.** Q2's target moves from M′ to M″, and Q3's M→M′ transfer does not cover M″. O2–O4 run again at
  their original N. Q4 and Q6 run on M″. Q7's gating arms become H and M″, and a Q7c run on M′ becomes diagnosis.
  The sink closes once LP1–LP10 hold.
- **(a), branch B.** P1 pays nothing. The sink waits for P1 only when P1 beats H's own gates.
- **(b), with the pin in the candidate.** The cost is the same, because the pin takes the tree past M′ and Q3 fails.
  The sink stays open until P1, which has no date.
- **(b′), the pin after P1.** P1 pays nothing. The sink stays open for all of P1, plus one deploy.
- If Q7 needs a `src/` change, P1 re-earns O2–O4 anyway (0052 O5: develop past the measured tree is a new unit). In
  that case (a) costs P1 nothing extra.

### 2. H, before the main push (builder)

- LP1. **Shape.**
  - H's parent is the base read from the running web image at promotion time (0057 BR9).
  - The expected base is 0333d7966 (branch A), or M′ `6de257335` once P1 serves (branch B). Any other base stops
    this ruling.
  - `git log <base>..H` shows one commit.
  - `git diff --name-only <base> H` prints only `packages/markdown-engine`.
  - The gitlink is `e5253d2dbcd1e091862df171d137c11006a8a878` exactly.
- LP2. **Reach.** After a fresh fetch in the submodule, `git merge-base --is-ancestor e5253d2 origin/main` returns
  rc 0 (0062 PO-3). Engine CI is met: run 44245031852, above.
- LP3. **Host gates on H's tree.**
  - Run typecheck, lint, the full canvas suite and `pnpm exec tsc -p tsconfig.markdown-engine.json --noEmit`
    (`Dockerfile.prod:53`).
  - Run them one after another, each alone, each cited by its own rc line.
  - If a wall-clock canvas test fails, re-run it alone and cite both runs (0052 Q4).
  - Save the proof that the worktree is clean (0052 checklist): `git status --porcelain` is empty, and every
    `git submodule status` line starts with a space.
- LP4. **Corpus differential, `674dd65` against `e5253d2`.**
  - Inputs: the census corpus (`scratch/u3/census.sh`, 3820 files) plus `census-extra`.
  - Calls: `parse`, `parseMarkdownToBlocks` and `parseInlineMarkdown`, then `renderHtml` and `renderReact` through
    `renderToStaticMarkup`.
  - Bar: every AST and block list is equal. Rendered output differs only in the class list of a callout whose kind
    fails `isWordKind`, and the log reports that count.
- LP5. **Fuzz differential aimed at 1d7496f.**
  - Generator: seeded, over `*`, `_`, runs of 2 and 3, `[ ] ( )`, backtick, backslash, `!`, space, punctuation and
    letters. Lengths 1–200. At least 100,000 inputs.
  - Run all inputs in one process, in a seeded order, then the whole set again in another order. The caches persist
    across calls.
  - If the inline parser takes options, interleave every option set the host passes.
  - Bar: `parse` and `parseInlineMarkdown` are equal between the engines, with 0 differences.
  - **Non-vacuity.** The same run against a mutant of e5253d2 with `openersSeen.pop()` (`:596`) deleted reports at
    least 1 difference. So does a run against a bracket-cache mutant, named in the log. If a mutant reports 0, the
    generator does not reach that path and LP5 is not met.
  - Save the seeds, the counts and the mutant diffs.
- LP6. **Bench against live.**
  - Run abGuard with `ref` set to `674dd65` in a scratch copy of `reference.json`, which is never committed, with 2
    rounds.
  - Every ratio is ≥ 0.90, the file's own 10 %.
  - `bench/emphasis-runs.test.cjs` passes at e5253d2.
- LP7. **The PoCs through the host's own path.**
  - The harness is a scratch file and is not committed (0057 BR8). It resolves the engine the way the host does.
  - Clipboard: it runs the host's `serializeCrossText` at H on the two `sec/callout-string.cjs` payloads, then
    `sec/run-chromium.sh` on the output. Only the three controls are flagged.
  - On 0333d7966 the same harness flags the payloads, which is the positive control.
  - Chat: `renderAssistantMarkdown("> [!note fixed inset-0 z-50] t")` gives the callout the class `md-callout`
    alone at H. At 0333d7966 the class includes `fixed`.
- LP8. **The built bundle.**
  - Build both H and 0333d7966 through the live image's build path (`Dockerfile.prod`).
  - Choose a string that only the old renderers emit. The default is `-callout-${` and `-container-${`, the PO-2
    grep.
  - It is in the base build's JS and absent from H's. If it is in neither, pick another string and say why.
  - If it is in both, stop: something else ships the old renderer, possibly 0062 L-2's copy.
- LP9. **CSS.** Diff the CSS of the two LP8 builds selector by selector.
  - Zero differences, or every added selector is traced to a string in an engine file.
  - A removed selector is a BLOCK.
- LP10. **CI.**
  - osionos CI on H's exact sha is green, including the main-only jobs: the prod and bundle builds, and
    `test-bridge-stub` (0057 BR7g).
  - The `node-pages` run on H succeeds.
  - A pass on retry is reported as flaky. A job that did not run is SKIP, and a SKIP blocks.

### 3. Push, deploy, rollback (coordinator)

- LP11. **Push.**
  - Run `git ls-remote` immediately before. Main must still be LP1's base.
  - Push with `git push origin H:refs/heads/main`, with no `--force` (0057 BR11).
  - If main has moved, stop and get a new ruling.
- LP12. **Before the switch.**
  - Record the running image's tag as the rollback target. In branch A that is `main-0333d796-site`. In branch B
    it is P1's image, never a pre-P1 one.
  - `docker image inspect` on the VM shows the image is present.
  - A rollback script for that tag exists, and reading it prints that tag.
  - Deploy H as `main-<H sha8>-site` under the standing go.
- LP13. **After the switch.**
  - The served index chunk's filename equals LP8's local build (0057 BR12).
  - The LP8 string is absent from the served JS.
  - Together these tie live to LP7, so no signed-in UI probe is needed.
- LP14. **Rollback.**
  - Trigger: an LP13 mismatch, a reported render or paste regression, or an engine error in the console. The
    rollback goes to the LP12 tag.
  - It reopens the sink. It loses no stored data: the fix changes no stored format (CK-7), and LP4 and LP5 bound
    `1d7496f`.
  - In branch A, `main-0333d796-site` and H's image are rollback targets only while P1 has not served. Once P1
    serves, neither one is (0052 checklist).
- LP15. **The groot pin.** Pin `apps/osionos/app` to H after the deploy, as cbebd948 did for 0333d796.

### 4. Develop and P1

- LP16. **Branch A: a real merge, the one exception to 0062 PO-5.**
  - When: right after LP13, before any gating P1 run, and before any other commit reaches develop.
  - Do not stop a Q7c run already going on M′. Its result becomes diagnosis.
  - Merge `origin/main` into develop to make M″. Do not use `-s ours` and do not cherry-pick.
  - `git diff M′ M″` is exactly the gitlink line `674dd65` → `e5253d2`.
  - `git merge-base --is-ancestor H M″` returns rc 0.
  - Push as a fast-forward, with no `--force`.
- LP17. **Branch A: P1's targets move to M″,** or to a later candidate that contains it.
  - Q2: main fast-forwards to the candidate. `--is-ancestor origin/main <candidate>` returns rc 0, with main at H.
  - Q3 covered M→M′ only. For M″, O2–O4 run again at their original N, unless a normalised comparison is ruled
    first (0052, Declined A).
  - Q4 and Q6 run on the candidate's sha.
  - Q7's gating arms are H's tree and the candidate. Runs on 0333d7966 and M′ are diagnosis, not the gate.
  - The coordinator records this move in 0052.
- LP18. **The pin guard is standing.** Any commit that moves `packages/markdown-engine` on osionos main or develop
  logs `git -C packages/markdown-engine merge-base --is-ancestor e5253d2 <new gitlink>` with rc 0. The U3 pin
  `08301d0` (648a029dd) passes today.
- LP19. **Branch B: H on top of P1.**
  - H is main (M′) plus the gitlink. LP4–LP6 are engine-only and carry over.
  - LP3 and LP7–LP10 run again on H's tree.
  - Develop is still M′ (PO-5), so it fast-forwards to H. No merge is needed and P1's evidence is untouched.

### 5. The deviations

- V1. **Upheld.** Main lowercases the kind at parse (`parserBlockQuote.ts:116`, at both 674dd65 and e5253d2), so
  `[!NOTE]` gives `md-callout-note`.
  - CK-4's rule, byte for byte as main, stands. Its example was wrong, and 0062 is corrected.
- V2. **Upheld.** `CONTAINER_OPEN_RE` is built from `WORD_KIND` (`blockKind.ts:7,11`). It has the same pattern
  text as the literal it replaces (`parser.ts:180` at 674dd65), so the container parse is unchanged by construction.
  - Calling `isWordKind` after a looser match would widen what parses (CK-7).
  - CK-1 is reworded in 0062: one grammar source, not one call site.
- V3. **Upheld.** This is CK-5 as written.
  - For a word kind and the `md` prefix, `esc()` is the identity, because `[A-Za-z0-9_-]` holds none of `&<>"'`.
  - A `classPrefix` that contains those characters now comes out escaped. The prefix is host configuration, not
    author text.

### 6. UNKNOWN and SKIP

- SKIP: this ruling ran no build, test, bench or probe.
  - Checked by command: the refs, gitlinks and ancestry; CI 44245031852; the file overlap; the import surface; and
    where the bench ref sits.
- UNKNOWN: whether Q7c passes, and so which branch applies. The ruling covers both.
- UNKNOWN: whether chat is enabled live, and which paste targets execute the attribute.
- UNKNOWN: the rollback image and script on the VM. LP12 closes it.
- UNKNOWN: whether Tailwind scans the engine submodule. LP9 closes it.
- UNKNOWN: whether `1d7496f`'s failed-opener propagation is sound. LP4 and LP5 close it.

## Alternatives considered

- **(b), the pin on develop past M′, live with P1.**
  - It costs P1 what (a) costs, because the tree moves past M′ and Q3 fails.
  - It keeps both sinks live until P1, and Q7 gives P1 no date.
- **(b′), the pin held until P1.** P1's evidence survives. But the sink's closing date becomes Q7c's outcome.
  Q7d or Q7e can still BLOCK, and a BLOCK has no date. Branch B gives the same order whenever P1 is first anyway.
- **(a) with an immediate merge into develop, whatever Q7c is doing.** This throws away a Q7c run on M′ even when
  P1 would have landed before H. Branch A does the merge only once H is live.
- **The fix cherry-picked onto 674dd65, without the riders.**
  - It would apply, because no rider touches the fix's files.
  - But the pin would name a commit that no engine main holds. That breaks PO-3, or needs a merge on engine main only
    to make the commit reachable.
  - The fix's tests ran on the new loader (`055639b`, `3d39f46`).
  - The next engine pin brings the riders anyway.
  - It is the fallback only if LP4 to LP6 fail, and it needs its own ruling.
- **A live image from a sha that is not on main.**
  - Main would no longer describe live, and the next main deploy would drop the fix silently.
  - `node-pages` would not carry the fix.
- **A cherry-pick of H onto develop instead of a merge.** Main would not be an ancestor of develop, so Q2's
  fast-forward fails and a BR13 merge is needed later anyway.

## Consequences

- The builder owns LP1–LP10, LP16 and LP19. The coordinator owns LP11–LP15 and LP17's update to 0052.
- Both live sinks close at LP13. A rollback reopens them.
- In branch A, M′ is no longer P1's live candidate, and O2–O4, Q4, Q6 and Q7 run again on M″. If Q7 forces a
  `src/` change, that costs nothing extra.
- In branch B, P1 keeps its evidence. H waits for no one except its own gates.
- A transfer of O2–O4 from M′ to M″ is not ruled. Branch B would already put M′ plus the pin live, measured only by
  LP3–LP10. So a transfer ruling is reasonable to ask for. It needs a chunk map measured on both builds, not a
  regex normaliser (0052, Declined A).
- 0062 L-1 is ruled here, and 0062's CK-1 and CK-4 wording is corrected (V1, V2).
- If LP4, LP5 or LP6 finds a difference, H is BLOCKED. The rider is then the defect, and the cherry-pick fallback
  comes back for a ruling.
