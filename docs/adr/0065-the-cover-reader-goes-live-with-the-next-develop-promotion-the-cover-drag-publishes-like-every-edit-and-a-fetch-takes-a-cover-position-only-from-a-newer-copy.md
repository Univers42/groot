# 0065. The cover reader goes live with the next develop promotion, the cover drag publishes like every other edit, and a fetch takes a cover position only from a newer copy

- Status: accepted. Three questions under ADR 0064 (page shells), PS24 and PS50.
  - Q1, how the Phase 5 reader reaches live: (b) the next develop→main promotion is PROCEED-WITH-CONDITIONS CV8 to CV13. (a) a standalone cherry-picked reader unit on main is BLOCKED now; CV13 says when it reopens.
  - Q2, whether Phases 1.1–1.3, engine PS11–PS16 and Phases 2–4 may land on develop before the reader is live: PROCEED-WITH-CONDITIONS CV14 to CV17.
  - Q3, Finding A (a cover reposition alone is never published): (ii) a timestamped cover drag plus a fetch gate on `coverPosition` is PROCEED-WITH-CONDITIONS CV1 to CV7. (i) `coverPosition` in the page stamp is BLOCKED (`.out-of-scope/cover-position-in-the-page-stamp.md`).
  - ADR 0064 F8 is corrected for `cover_position` (see Context).
- Date: 2026-11-19
- Deciders: devil (ruling); builder (CV1 to CV7, CV15); coordinator (the CV1 query, the promotion, CV12)

## Context

All refs were read on 2026-11-19 after `git fetch`. `git ls-remote`: osionos main `6de257335` (M′), develop `f5eb51ca0`, 61 commits apart. Source was read in `/mnt/storage/dlesieur/wt/osionos-cover-reader` with `git show origin/develop:<path>`. Nothing was run against a database or the VM.

- **Scores** (1 to 5).
  - Q1 (a): blast 2, reversibility 4 (a main push, a served image, a service-worker rollover, open tabs that never reload), cost 2, confidence 3. Worst: reversibility. Q1 (b): nothing moves now.
  - Q2: blast 3 (beta serves develop on production data, ADR 0040), reversibility 3, cost 3, confidence 3. The phases' own PS conditions govern; the cover question adds little.
  - Q3: blast 2 (one cosmetic field per page), reversibility 2, cost 2, confidence 3 (the production column check is UNKNOWN until CV1).
- **Main's queue is already full and ordered.** T `ba24e781e` (O8, a test-only child of M′, not pushed; `scratch/ci-main-shard2/FIX-RESULT.md`) must come first, and every later main unit is parented on T (O8c). After it: H′ re-created on T (ADR 0063), fence fix F after O9 (FF ruling), and R-BR5 PR13 with the user's go (ADR 0061).
- **The reader already ships a regression on develop, and so on beta.**
  - The fetch now takes the server's `coverPosition` for any clean page: `...(takeServer ? readCoverFields(server) : {})` with `takeServer = clean || isNewer(...)` (`mergeServerPages.ts` in `resolveFetchedPage`, develop).
  - `clean` is computed over the stamp (`isPageClean`), and `coverPosition` is not in the stamp. So `clean` is no evidence that a local position was published.
  - A reposition is never published on its own (Finding A, below). A device that repositions a cover, and whose server row already holds an older `cover_position`, snaps back to the server value at the next content fetch of that page.
  - The develop test codifies this as intended: `tests/canvas/cover-reader.test.ts`, "a cover position change alone is still taken from a clean page's fetch". Same `updatedAt`, local 50, server 20, result 20.
  - Before the reader, the local position survived on that device. No server row is written by the snap-back (`recordSynced` only re-records an unchanged stamp).
- **Finding A, verified.**
  - The drag commits once, on save with a changed value (`useCoverReposition.ts` `save` → `onCommit`).
  - `changeCoverPosition` calls only `patchPage` (`usePageHeaderActions.ts:89`), and `patchPage` never sets `updatedAt` (`usePageStore.ts:437-460`).
  - The stamp has no `coverPosition` (`pageStamp.ts` `pageStamp`), and the outbox publishes only on a stamp difference (`packages/outbox-ledger` 792d250 `computeSyncActions`: `ledger[id] !== stamp`).
  - The body carries `coverPosition` whenever it is a number (`pageOutbox.ts:88`), so it reaches the server only with some other stamp-changing edit.
  - Title and block edits go through `withTimestamp` (`pageStore.helpers.ts:517`, used at `usePageStore.ts:256-381,468`). A page move bumps `updatedAt` "so the offline outbox syncs" (`pageStore.actions.ts:851-856`). The cover drag is the odd one out.
  - The `pageStamp.ts:15-16` header ("folds every field the bridge persists") is false: `coverPosition` is persisted (`bridge-api.mjs:893`) and not folded.
- **Finding B (recorded, not ruled).** Icon and cover edits also skip `withTimestamp` (`usePageHeaderActions.ts:45,51,70,77,83`). They are published, because both are in the stamp, but with the old `updatedAt`, which the bridge stores as `updated_at` (`pageUpdatedAtFromPayload`). Another device's list hydrate only takes a newer row (`mergeServerPage`, `isNewer`), so those edits reach it only through a clean-page content fetch.
- **ADR 0064 F8 corrected for `cover_position`.** F8 said no `.sql` creates it. Groot does:
  - `models/osionos-page-cover-position-migration.sql:7-8`: `ALTER TABLE public.osionos_pages ADD COLUMN IF NOT EXISTS cover_position real`.
  - The runner is `scripts/apply-models-migrations.sh` (added 8dfeed85, run by `make all` models-migrate and `scripts/datacenter.sh:51`).
  - Its header (`:15-20`) records the failure F8 feared, measured: a missing `cover_position` made every PATCH carrying `coverPosition` fail 502 PGRST204 and stopped the whole outbox batch.
  - Live and develop bridges both name `cover_position` in `PAGE_LIST_SELECT` (`bridge-api.mjs:1713` on both refs), so a working live page list implies the column exists on production. The running bridge's sha was not read, so this is inference, not proof (CV1).
- **The reader cherry-picks clean today.** `git diff --stat origin/main 02189e502 --` the ten files that 9bf8f6be0 and f5eb51ca0 touch, plus `usePageHeaderActions.ts` and `usePageStore.ts`, is empty.
- **Neither the reader nor CV2–CV5 changes a persisted format.** `coverSizeStamp` returns `""` when both size fields are undefined, so every existing stamp is byte-identical by construction. The `.omd` writer names `cover_height`/`cover_width` only when present (`pageFileMeta.ts` `put`), and `readCoverPosition` is the removed `percent()` unchanged.
- **Unknown when written:**
  - whether production `osionos_pages` has `cover_position` (CV1);
  - how many server rows hold a `cover_position`, which bounds the pages where a stranded local reposition can differ from the server;
  - how many stranded local repositions exist on live devices. They are local-only, so no server query sees them;
  - which build beta serves at this moment.

## Decision

1. Readers still go live before writers (0064 decision 3). The reader rides the next develop→main promotion. The Phase 5 writer, on develop as well, waits until a served live build contains the reader.
2. A committed cover reposition is an edit like any other: it advances `updatedAt` through the existing `withTimestamp`, so the stamp changes and the outbox publishes it. The stamp format does not change.
3. A content fetch takes the server's `coverPosition` only from a newer copy, or when the page has none. A field outside the stamp cannot use "clean" as its licence.

### Conditions

**Q3, the cover drag publishes (ii) plus the fetch gate (PwC; (i) BLOCKED)**

- CV1. Before CV2 reaches develop, the coordinator runs this read-only query on production and reports the output (counts and column names only):

  ```sql
  BEGIN READ ONLY;
  SELECT column_name, data_type FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'osionos_pages' AND column_name LIKE 'cover%'
   ORDER BY 1;
  SELECT count(*) AS pages,
         count(*) FILTER (WHERE cover IS NOT NULL AND cover <> '')                AS with_cover,
         count(*) FILTER (WHERE cover_position IS NOT NULL)                       AS with_position,
         count(*) FILTER (WHERE cover_position IS NOT NULL AND cover_position <> 50) AS off_center,
         count(DISTINCT owner_id) FILTER (WHERE cover_position IS NOT NULL)       AS owners_with_position
    FROM public.osionos_pages;
  ROLLBACK;
  ```

  - `cover_position` must be present. If it is absent, CV2 is BLOCKED, and today's piggy-backed PATCHes are a separate critical (apply-models-migrations.sh:15-20).
  - `cover_height` and `cover_width` must be absent; that is recorded as the PS31 baseline.
  - The counts are recorded, not gated.
- CV2. One store action applies a header patch through `withTimestamp` and `canEditPage`, shaped like `updatePageTitle` (`usePageStore.ts:462-468`). `changeCoverPosition` uses it.
  - `patchPage` itself is not changed. `git grep "patchPage(" -- src` finds 35 sites, and they include remote applies that must never touch `updatedAt` (`usePageStore.ts:391-396`).
  - One committed drag gives exactly one bump.
- CV3. The tests run in the canvas `node:test` suite, RED first on `f5eb51ca0`:
  - a committed reposition changes `pageStamp`, `computeSyncActions` lists the page, and the patch body carries `coverPosition`;
  - a cancel, or a save at the same value, leaves `updatedAt` and the stamp unchanged;
  - a mutant that drops the timestamp fails the first test.
- CV4. `resolveFetchedPage` takes `server.coverPosition` only when `isNewer(server, current)` or `current.coverPosition === undefined`. `coverHeight` and `coverWidth` keep the clean-or-newer rule, because they are in the stamp.
  - The test "a cover position change alone is still taken from a clean page's fetch" is inverted: equal `updatedAt`, clean, local 50, server 20 → 50 kept. A newer server copy → 20.
  - The PS25 alternation tests are re-stated with their new rewrite counts, and the counts are reported.
- CV5. In the same commit, the `pageStamp.ts` header states what the stamp folds, and that `coverPosition` is excluded (old ledgers, F7) and reaches the server through the `updatedAt` bump. The `coverSizeStamp` comment says the same. The stamp's output does not change, and the PS26 tests stay green unedited.
- CV6. (i), `coverPosition` in the stamp, is BLOCKED. Every device holding a positioned page would see an old-format ledger entry at boot and re-PATCH. An unclean page republishes its local metadata with no version check (title, icon and properties carry no `baseVersion`; `pageOutbox.ts` `pageToPatchBody`). That is the P1a stale-metadata class (0064 F7), and its size lives in browsers, so no server count bounds it.
- CV7. CV2–CV5 land on develop as one unit (RED + GREEN allowed) with the develop gates green: typecheck, canvas, lint `--max-warnings 0`, `test-bridge` and `test-bridge-stub`. No main push.

**Q1, the reader reaches live (b) PwC; (a) BLOCKED now**

- CV8. 9bf8f6be0 and f5eb51ca0 reach osionos main only inside the next develop→main promotion, which is ruled on its own: O8c-9, BR13, the FF order, and PR13 with the user's go. There is no standalone reader unit and no separate serve step. Serving live is permitted only as that promotion's own swap.
- CV9. That promotion must contain CV2–CV5. A main candidate that holds the reader without CV4 is BLOCKED, because it would ship the snap-back to live. Proof: `git merge-base --is-ancestor <CV4 sha> <candidate>` returns rc 0.
- CV10. The rollback target is the promotion's own: a post-P1 image only (K7, PR16). The reader and CV2–CV5 add no key and no format.
  - A rollback loses nothing. Positions published after the promotion stay on the server, and the older build shows them through the list hydrate.
- CV11. No FF-2 snapshot re-take is required for the reader or CV2–CV5, because neither writes a new format (Context). A fresh full snapshot of `osionos_pages` is required at PS31, before the cover-size migration and before any writer. That snapshot is the writer's restore source.
- CV12. This is added to the PS31 lift. The Phase 5 writer, including on develop and so on beta, waits until the served live build contains the reader and CV4.
  - The served sha is read from the running build at that moment (the baked `VITE_APP_VERSION` / image label). For 9bf8f6be0, f5eb51ca0 and CV4's sha, `merge-base --is-ancestor` returns rc 0.
  - Residual, named: open live tabs older than the promotion never reload (`appWorker.ts:36`, FF facts). They keep writing `.omd` without the size keys. The user attests this; it is not measured.
- CV13. (a) reopens only if PS31 holds and the writer is otherwise ready while no promotion is scheduled. Then the reader plus CV2–CV5 are re-submitted as a unit parented on main's tip at that time: after T (O8c), and after whatever the H′/F rulings have put there. Re-check the clean cherry-pick then.

**Q2, Phases 1.1–1.3, engine PS11–PS16 and Phases 2–4 on develop before the reader is live (PwC)**

- CV14. They may land on develop, and so on beta, each under its own conditions. That includes PS5 and PS15 censuses before develop, PS16 and FF-17 order, PS10's flag, PS17–PS23, and ADR 0061 for Phase 4.
- CV15. None of them produces `coverHeight`, `coverWidth`, `cover_height` or `cover_width` on any page, seed, shell, section, template, snippet or console completion. Shells and sections carry no cover-layout fields at all until the Phase 5 writer.
  - A test asserts this over the shell/section catalogue and `SEED_PAGES`.
  - PS20's template copy copies only keys the source page has.
- CV16. CV2–CV5 land on develop before Phase 1.1. The snap-back is on beta now, and it is one queue slot.
- CV17. PS50 is amended. Step 3 becomes "the reader plus CV2–CV5 on develop", and its "then to live" moves to "before step 8" (CV12). Every other step and ruling in PS50 is unchanged.

## Alternatives considered

- **(a) Cherry-pick the reader onto main now, like ADR 0063's H.**
  - Main is M′, and O8c parents every later unit on T, which is not pushed.
  - It adds a fifth unit (CI, image, service-worker rollover) to a queue that already holds T, H′, F and R-BR5.
  - Its benefit is zero until a writer exists, and the writer is blocked on PS31 (step 8).
  - As built, it ships the snap-back to live users.
  - 0063's H was justified by a live XSS sink. No live harm waits on this reader.
- **(i) `coverPosition` in the stamp when defined:** CV6. It rescues stranded local positions, but at the price of an unbounded, unmeasurable stale-metadata republish.
- **(ii) alone, without the CV4 gate:** this leaves the snap-back for every position stranded before (ii) on a page whose row holds another value. The bound is `with_position` (CV1), but the stranded side is unmeasurable. The gate costs one line.
- **Bump `updatedAt` inside `patchPage`:** it would make remote applies and sync patches publish (`usePageStore.ts:391-396`), a PATCH loop.
- **Hold Phases 1–4 until the reader is live:** they write no cover field (CV15), and the reader's live date is tied to an undated promotion. Holding them buys no safety.

## Consequences

- Live keeps today's behaviour until the promotion: a reposition is local-only until another edit publishes it, and the content fetch ignores the server's position. That is a degradation, not a loss.
- After CV2–CV4, a reposition reaches the server and other devices like a title edit. Positions stranded before it stay local until that page's next published edit (residual).
- PS31's "migration owner named with its file" can now be met by a sibling `models/` file under `apply-models-migrations.sh`. The column checks on prod, dev, CI and fresh-clone backends still bind, including the CI stub's column list (`tests/bridge/support/embed-postgrest.mjs:28`).
- Finding B (icon and cover publish with an old `updatedAt`) is open. Adopting the CV2 action for those five calls is allowed as its own commit with CV3-style tests. It is not required here.
- Rejected concept: `.out-of-scope/cover-position-in-the-page-stamp.md`.
