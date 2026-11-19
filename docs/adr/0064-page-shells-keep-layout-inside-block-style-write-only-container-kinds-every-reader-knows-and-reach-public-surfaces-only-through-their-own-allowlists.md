# 0064. Page shells keep layout inside block style, write only container kinds every reader knows, and reach public surfaces only through their own allowlists

- Status: accepted. Plan `~/.claude/plans/delightful-dazzling-kay.md`, Gate 1.
  - Phases 1 to 5: PROCEED-WITH-CONDITIONS, in the order PS50.
  - Two parts are BLOCKED: a writer that emits new `:::` kinds, and shells registered as `SEED_PAGES`.
  - The Phase 5 writer and bridge part is BLOCKED until PS31 holds.
  - Phase 6: PROCEED-WITH-CONDITIONS for beta only. Live stays off.
  - Phase 7: PROCEED-WITH-CONDITIONS for containers and style. A cover in the public snapshot is BLOCKED until PS47 holds.
- Date: 2026-11-19
- Deciders: devil (ruling); osionos main session / builder (lives with it)

## Context

All facts were read on osionos `origin/develop` 50406aa92 (engine pin 08301d0) and live engine 674dd65. The source was read only. The probes ran on archives in the devil scratchpad (`ps/probe-container.cjs`, `ps/real.ts`).

- **Scores** (1 to 5): blast 4, reversibility 3, cost on failure 4, confidence 3. The worst are blast and cost.
  - Beta serves develop against production data and the production bridge (ADR 0040). A develop format change therefore reaches live data.
- **F1, proved.** The real `blockStyle.ts`, run under node 26, throws `TypeError` on `{"constructor":1}` and on `{"__proto__":…}`.
  - Cause: `PROP_SCALE[key]` is a plain-object lookup (`blockStyle.ts:89`).
  - Values are safe: `{"gap":"4;background:url(x)"}` comes out as `{}`.
  - The stored `style` is an opaque record on the bridge (`bridge-content-validation.mjs:20-31`) and in the overlay (`blockOverlay.ts:124`).
  - `PublicPageView.tsx:42` renders with no error boundary.
- **F2, measured on both pins.** `::: grid {cols=3}` wrapping two `:::column` parses to two orphan `column` blocks, and the `column_list` is gone (`shortcuts.ts:333-334`, "nothing is lost" is wrong for layout).
  - `:::columns {layout=grid cols=3}` and `:::column 0.5 {span=2}` keep their structure and the ratio. The attributes are ignored.
- **F3, measured on both pins.** A `:::` line inside a fenced code block inside a column closes the container. The code is split and a stray `:::` paragraph appears (`parser.ts:164-178` does not track fences).
- **F4, publish snapshot.** `column_list` and `column` are not in `ALLOWED_TYPES` (`bridge-publish-snapshot.mjs:43-59`), and `style` is not in `KEPT_FIELDS` (`:65`).
  - So today a published page drops every column together with its content.
  - The plan's line "Phase 1 styles already render through PageBlocksRenderer" is false for `/p/`.
- **F5.** `flattenColumns` hoists a `column` whose only child is a `column_list` (`blockTreeUtils.ts:21-26`, used by `ReadOnlyBlock.tsx:385` and `BlockEditorSurface.tsx:1781`). A section that holds only a grid would render flattened into the section's row.
- **F6.** `resolveBlockStyle` also maps the flat `textColor`/`backgroundColor` tints to `data-s-text`/`data-s-surface` (`blockStyle.ts:128-136`), and `block-style.scss:75` paints `background-color` on that element.
  - Wiring it onto every wrapper restyles every tinted block that exists today. "Defaults look exactly like today" is unproven.
- **F7.** `pageStamp` (`pageStamp.ts:74-89`) is stored in the persisted outbox ledger (`:26,39`).
  - Any change to its format makes every page unclean at the next boot.
  - Unclean pages republish with stale metadata (the P1a class, ADR 0056), and a newer server body is refused (`mergeServerPages.ts:34,145`).
- **F8.** `PAGE_LIST_SELECT` names its columns (`bridge-api.mjs:1713`), and the bulk hydrate uses it (`:2967`).
  - If it names `cover_height` on a backend without that column, every page list fails.
  - No `.sql` file in osionos develop or groot creates `cover_position`. **The migration owner is UNKNOWN.**
- **F9.** Built-in templates are `SEED_PAGES` (`seedPages.ts:127-150`). They are merged into the page cache (`pageStore.actions.ts:66-69`) or POSTed as pages.
  - The page cache is the ADR 0056 LRU: a 1M-unit ceiling, with 344,898 characters free measured after eviction.
  - The byte size of 37 shells is UNKNOWN.
- **F10.** The README projection turns any block deeper than 12 levels into an empty paragraph (`bridge-readme-bindings.mjs:36,46`).
  - Only `README_BINDABLE_FIELDS` can be bound (`:29-32`), and avatar is not one of them.
  - Visitors get README content only through the card (`useProfile.ts:107-113`). The card carries no cover.
- **F11.** A gradient cover is passed raw as `style.background` (`CoverMediaElement.tsx:134`). `linear-gradient(…), url(https://x)` loads a third-party URL in every viewer's browser.
  - The profile banner is guarded today by `isSafeImageSource` (`ProfileShell.tsx:34`).
- **F12.** `content === undefined` means "not loaded yet" (`mergeServerPages.ts:144`).
  - If the empty-page starter treats it as empty, it writes a shell over a body the server has not delivered yet.
- `coverPosition` is dropped on read-back (`mergeServerPages.ts:146-152`, `seedToEntry`). The bridge already maps it (`bridge-api.mjs:758,893`).
- **Unknown when written:**
  - the migration owner for the page columns;
  - whether an anonymous reader can fetch an uploaded cover asset;
  - whether live's `osilayout` fence keeps unknown cell keys;
  - the production count of blocks that already carry `style`;
  - the shell catalogue size.

## Decision

1. All layout data lives inside `Block.style`. Live's overlay already carries that field opaquely, so live round-trips it.
   - The writer emits only `:::columns` and `:::column`.
   - `row | stack | grid | section` are input sugar only, normalised on read.
2. Every surface a stranger can reach validates layout and cover values against its own allowlist on the server, never on trust.
3. Readers ship to live before writers.

### Conditions

**Phase 1.1, BlockStyle wired to the DOM (PwC)**

- PS1. `sanitizeBlockStyle` uses `Object.hasOwn` (or null-prototype maps) for `PROP_SCALE` and `STYLE_SCALES`.
  - A test feeds every `Object.prototype` name plus `__proto__` from `JSON.parse` and gets `{}` with no throw.
  - A seeded fuzz runs 10k random records and never throws.
- PS2. Stored values reach the DOM only as `data-s-*` enum attributes. No inline `style`, no CSS custom property and no class token is built from a stored string.
- PS3. A per-block error boundary sits in `PageBlocksRenderer`, so one bad block shows a fallback and the rest of the page renders. It covers `PublicPageView` and the profile README.
- PS4. The wrapper gets the resolved style only when `block.style` holds a key. The flat-tint fallback stays where it is today (F6).
  - Proof: Playwright screenshot parity, 0 changed pixels on a fixture of tinted, colored and button blocks, in dark and light.
- PS5. A census (counts only, no values) of production blocks that already carry `style` is taken before develop. If the count is nonzero, PS4's parity runs on those pages too.

**Phase 1.2–1.3, container modes and inspector (PwC)**

- PS6. New keys are enum scales inside `style` (`layout`, `wrap`, `cols` 1–6, `minCol`, `stackAt`, and `span` on `column`). There is no new top-level Block key, so live's `.omd` overlay keeps them.
- PS7. `flattenColumns` and the `columnLayout` invariant leave a styled `column_list` alone (F5). A section that holds a grid renders as a section that holds a grid; a test proves it.
- PS8. Absent `layout` renders byte-identical DOM to today, shown by a snapshot test.
- PS9. Canvas `layout` cells gain `stackAt` only after a test shows live's (engine 674dd65 plus main) `osilayout` round-trip keeps an unknown cell key. Otherwise `stackAt` waits.
- PS10. The Phase-1 rendering ships behind a flag that is beta on and live off. Live renders styled lists as plain columns and loses no data.

**Phase 1.4, markdown sugar in the engine (writer of new kinds BLOCKED; the rest PwC)**

- PS11. The canonical writer (`pageMarkdownSerialize.ts`, `pageToFile`) emits only `columns` and `column`. Attributes go after the ratio (`:::column 0.5 {span=2}`).
  - Both pins already keep that structure (F2). Writing `::: grid` is BLOCKED (F2).
- PS12. Pages without style serialise byte-identical, so the `pageToFile` sha16 is unchanged.
  - Checked on the FF-2 snapshot (176 rows) and on every existing template.
- PS13. The engine parses `{k=v …}` into a null-prototype record of strings and knows no scale. The app validates through the one `sanitizeBlockStyle`, with numbers coerced per scale.
  - Limits: ≤ 256 characters and ≤ 16 pairs; extra input is dropped and reported, and nothing throws. The pattern is linear (no nested quantifiers), and a 1 MB input test finishes in < 50 ms.
- PS14. When the markdown carries attributes, they win over the overlay `style` for layout keys, in both `rawSave` (`rawSave.ts:33`) and `fileToPage`. When it carries none, the overlay applies.
  - Test: a live-written file (no attributes, overlay only) loses nothing.
- PS15. The container scan becomes fence-aware (F3) before the sugar ships.
  - That changes how existing pages parse, so a census of pages with a `:::` line inside code inside a container is taken first, the same way as FF-1. A nonzero count is a re-rule.
- PS16. The engine change lands on engine main as its own commit after the fence engine line (a34736f / 08301d0). The pin is an ancestor of engine main (PO-3, FF-8), and it is never in the same pin bump as fence fix F.
- PS17. Shells and sections nest at most 8 block levels, which is under the README cap of 12 and the shared budget of 32 (ADR 0062). Every shell has a test that asserts this.

**Phase 2, sections and shells (shells as `SEED_PAGES` BLOCKED; code catalogue PwC)**

- PS18. Shells and sections are a lazy code catalogue that the gallery reads directly. They are never `SEED_PAGES`, never in the page cache and never POSTed (F9).
  - Proof: on a fresh boot, the page-cache `storedLength` is equal before and after.
- PS19. The starter shows only when `content` is a loaded `[]` and the page's server fetch has completed (F12). Applying a shell is one undo step.
- PS20. `createPageFromTemplate` copies the cover fields. It copies `properties` only when the template and the target are in the same database; a cross-database copy is UNKNOWN and stays out.
- PS21. Every shell round-trips through `serializeBlocksToMarkdown`→`parse` and `pageToFile`→`fileToPage` unchanged, under both the develop and the live engine.

**Phase 3: PROCEED** under PS17–PS21. Saved shells and sections are the user's own pages.

**Phase 4, console (PwC)**

- PS22. Monaco is a lazy chunk loaded only by the Advanced toggle, under the ADR 0061 preload recovery. The prod-perf boot numbers stay within the existing baseline.
- PS23. Diagnostics come from the same engine parse used by the save (PS13). There is no second grammar.

**Phase 5, cover size (reader PwC; writer and bridge BLOCKED until PS31)**

- PS24. The reader goes first and reaches live main before any client writes the fields:
  - `resolveFetchedPage` and `seedToEntry` read back `coverPosition`, `coverHeight` and `coverWidth`;
  - `.omd` reads `cover_height` and `cover_width`.
- PS25. On inbound, an absent key leaves the field unchanged.
  - Test: 10 alternations between a writer that has the key and one that lacks it keep the value, and the number of rewrites is reported.
- PS26. `pageStamp` appends cover fields only when they are defined. A stamp is byte-identical for every page without them (F7).
  - Checked on a corpus that includes the FF-2 snapshot.
- PS27. Values are clamped on both sides: height 120–640 integer, width `full|content`. The bridge allowlists them like `cover_position` (`bridge-api.mjs:853-856,893`). PAT permissions are decided explicitly (`bridge-pat-permissions.mjs:63`).
- PS28. The outbox sends the fields only when they are set. Clearing is an explicit null, and that is tested.
- PS29. The fields cost under 64 characters per resized page in the page cache. This is measured, not estimated.
- PS30. The resize handle is `role="separator"` with a value and a keyboard step, and passes axe.
- PS31 (lift). The migration owner is named with its file. The nullable columns exist and are verified on prod, dev, CI and fresh-clone backends.
  - Only after that may `PAGE_LIST_SELECT` name them (F8).
  - Until then the bridge reads them only through `*` selects and attaches them to a PATCH only when the column is proven. A PostgREST unknown-column error on a content PATCH is a loss path.

**Phase 6, profile as a page (PwC for beta; live BLOCKED)**

- PS32. Visitors see content only through the existing card projection, with no new endpoint. A cover added to the card goes through PS35's validator.
- PS33. Bindings use only `README_BINDABLE_FIELDS`. Avatar needs its own ruling. Bindings resolve by userId, never by username (the 2026-11-18 cross).
- PS34. The README page is created only by an explicit owner action, never on a view.
- PS35. Covers shown to anyone other than the owner pass a validator:
  - images through `isSafeImageSource`;
  - gradients through a strict grammar with no `url(`, the same function on the client and the bridge (F11).
- PS36. There is no write migration of the banner. The client reads `cover ?? bannerUrl`.
  - While the flag is not live, `BannerUpload` writes `bannerUrl` and also the cover, so turning the flag off loses nothing.
- PS37. With the flag on and the account having no username or no README, the visitor gets today's `ProfileShell`, never an empty page.
- PS38. The rollback is a test: flag off shows today's DOM, after a beta session that changed the banner.

**Phase 7, publish (containers and style PwC; cover BLOCKED)**

- PS39. `column_list` and `column` join `ALLOWED_TYPES`. `style` is copied only through a bridge sanitizer generated from `STYLE_SCALES` (or a shared JSON), with a drift test.
- PS40. The publish dialog says that a re-publish now includes column content. That content was dropped before (F4), and old snapshots stay as they are.
- PS41. The added per-node bytes are ≤ 200. The snapshot size of every shell is measured, and `MAX_NODES` and `MAX_DEPTH` are unchanged.
- PS42. The PS1 and PS3 tests also run against the public view.
- PS47 (lift for the cover). It must be shown, by an unauthenticated fetch, whether an anonymous reader can fetch an uploaded cover asset.
  - If yes, re-rule: publishing it is an exposure decision.
  - If no, ship gradients and https covers only, under PS35.

**Order**

- PS50. The order is:
  1. Step 0 under its own rulings. ADR 0061 and the FF ruling are unchanged here, and FF-17 still blocks Unit B.
  2. PS1–PS3. They are invisible and ship alone.
  3. Phase 5 reader PS24–PS26, then to live.
  4. Phase 1.1–1.3.
  5. Engine PS11–PS16.
  6. Phase 2 and 3.
  7. Phase 4.
  8. Phase 5 writer, after PS31.
  9. Phase 6.
  10. Phase 7.

## Alternatives considered

- **Write `::: grid` and the other new kinds:** live parses them into orphan columns (F2, measured). A ping-pong between live and beta (ADR 0058 U4b) then saves the loss with no undo.
- **A new top-level `span` key, or new Block fields:** live's overlay allowlist drops them on an `.omd` write. `style` already round-trips on live (`blockOverlay.ts:124` on main).
- **Shells as `SEED_PAGES` ("gallery for free"):** they cost an unmeasured slice of a budget that has 345k characters free. A code catalogue costs 0.
- **A one-time owner-side banner migration:** it is a write on production data from beta, and flag-off then shows a stale banner. A read-time fallback writes nothing.
- **Cover fields in `PAGE_LIST_SELECT` with "prefer no migration":** the select names columns. Without the column every list fails.

## Consequences

- Live keeps rendering plain columns for styled lists until Phase 1 goes live. That is a degradation, not a loss.
- Each phase's PS items are its acceptance criteria. A BLOCKED part is re-submitted with its lift fact; it is not routed around.
- Rejected concepts: `.out-of-scope/new-container-kinds-in-written-markdown.md`, `.out-of-scope/page-shells-as-seed-pages.md`.
- Residual: `KEPT_FIELDS` copies `textColor` and `backgroundColor` unvalidated into public snapshots (`bridge-publish-snapshot.mjs:65-77`). This predates the plan; it is for the `security` agent.
