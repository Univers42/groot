# 0067. The next osionos promotion is a frozen candidate cut after T serves, Phases 6 and 7 stay live-locked on develop, and the cover-size columns land as one guarded single-file migration

- Status: accepted.
  - Decision 1, fast-forwarding osionos main to develop 6e19a378f now: **BLOCK**. The lift is the RP1–RP24 path. RP re-rules FF-9 and PR13 and supersedes their wording for the next promotion.
  - Decision 2, Phase 6 (profile as a page, PS32–PS38) and Phase 7 containers/style (PS39–PS42, no cover) on develop, in parallel with the promotion and PS31: **PROCEED-WITH-CONDITIONS** PH1–PH8.
  - Decision 3, PS31 (the `cover_height` / `cover_width` columns): **PROCEED-WITH-CONDITIONS** CS1–CS16.
- Date: 2026-11-19
- Deciders: devil (ruling). The coordinator, CI and the user live with it; who does each step is in Consequences.

## Context

The facts were read on 2026-11-19 against the following state:

- osionos develop 6e19a378f, CI green (run 44568708998);
- osionos main 6de257335 (M′), main CI red on shard 2 (the harness race, O8c);
- live web `main-0333d796-site` (pre-P1).

Both tips were re-read with `git ls-remote origin` at the end of the ruling and had not moved. VM probes were read-only (`BEGIN READ ONLY`), run through the `ssh -o ControlPath=none -o BatchMode=yes -o ClearAllForwardings=yes b2b 'bash -s'` pattern. They printed counts only. The probe scripts are in the session scratchpad (`ps31-probe.sh`, `p3.sh`–`p6.sh`).

### Decision 1, the promotion

**Scores** (1–5): blast 5, reversibility 1, cost on failure 4, confidence 2. **Reversibility is the worst.**
- A main push publishes node-pages and cannot be undone (BR13d, ADR 0057:279-284).
- The first post-P1 serve is forward-only (K7).

| Condition | State on 6e19a378f | Evidence |
| --- | --- | --- |
| O8c-9: T served before anything past M′ | **not met** | T = ba24e781e (parent 6de257335), on `fix/e2e-wait-predicate` in `/mnt/storage/dlesieur/wt/osionos-e2e-wait`, not pushed. Develop adds 2 more async `waitForFunction` predicates: `blockLayoutModes.spec.mjs:39` and `blockStyleParity.spec.mjs:54`. They are vacuous: playwright-core 1.59.1 `frames.js:1267` tests the predicate's truthiness, and a promise is always truthy. |
| O8 deploy / O9 lift note (ADR 0052) | **not met** | Live is still `main-0333d796-site`, which is pre-P1. |
| K7 / CV10 / PR16: rollback is a post-P1 image | **not met** | No post-P1 image has served. `main-6de25733-site` was superseded and never served. Serving develop first leaves no rollback target. |
| BR13a: no `+` gitlinks, main is an ancestor of develop | met | `merge-base --is-ancestor origin/main origin/develop` rc 0. |
| BR13d: every unit in the range cleared for live, with the go at that moment | **not met** | 115 commits are in `origin/main..origin/develop`. The units below are not cleared. |
| FF-9: F gets its own swap after T, H′ and O9 | **superseded** | Develop already holds the reader (engine b6dc3fd ⊇ a34736f) and the FF-7(e) interim 3-backtick writer (50406aa92). The F that FF-9 describes can no longer be built without un-merging. |
| FF-10: a page-file-path test that sees the engine bug | **not met** | No develop test uses the `[x]: https://example.com` fixture. `git grep` hits only `layout-sugar.test.ts` and `markdown-fidelity.test.ts`. |
| FF-11: the attach guard | not on develop | No legacy-form guard exists in `reconcileOnAttach.ts`. |
| PR13: R-BR5 gets its own fast-forward after O9 | **impossible as worded** | 94066bd09 contains a673ffbe5 but not 50406aa92. R-BR5 cannot reach main alone. |
| PR14 / PR15 (stock Firefox 158, bfcache) | UNKNOWN | Never run on a promotion candidate. |
| LP18: is-ancestor e5253d2 → the gitlink | met | b6dc3fd ⊇ e5253d2. |
| LP24: engine bench cache fix before any pin past e5253d2 reaches main | **not met** | Engine b6dc3fd `bench/benchmarks.cjs` still keys `${safeName}.${process.pid}.cjs` and skips existing files. The LP20–LP22 split A/B is therefore required. |
| U3-8 CSP `img-src` / U3-9 disclosure (ADR 0058:91-95, order :223) | **not met** | osionos `nginx.conf:22/33/41` and `public/_headers` carry only `frame-ancestors 'none'`. `git grep` finds no disclosure on develop. Yet the README HTML subset renders on develop (engine b6dc3fd `htmlSubset/tree.ts`, `renderers/html.ts`). |
| PS10: layout flag off on live | met for env only | `featureFlags.ts:236-243` defaults to false. `osionos-beta/update.sh:44` sets it for beta only. Resolution is URL → localStorage → env → fallback (`featureFlags.ts:44`), so `?osio.layout.modes=1` turns it on in a live build. |
| PS22: boot within the baseline | UNKNOWN | Never measured on a candidate. |
| CV9: CV4 is in the candidate | met | 80db0f484 is an ancestor of develop. |
| BS10–BS12 | N/A | The boot fix (ADR 0066) is not on develop. The condition binds if it is on develop when D is cut. |
| LL8 | N/A | Develop has no page-cache (ADR 0056). |

The coordinator may treat the user's go as given:

- the go of 2026-11-19 ~18:30 CET ("continue and all the CI should be clean and all the phases or new things should be tested and of course continue until phase ultimate is done");
- the standing blanket go of 2026-10-30.

That go counts as the human go for each step, at the moment the step's own conditions hold. A go cannot lift a BLOCK. It also cannot stand in for the steps only the user can perform: closing or reloading tabs (FF-17), and a mobile A/B on a real device (BS10).

### Decision 2, Phases 6 and 7

**Scores**: blast 2, reversibility 4, cost on failure 3, confidence 3. **Cost on failure is the worst.**
- Beta serves develop against production data and the production bridge (ADR 0040). A beta write lands on real pages.
- Phase 7 is bridge-side. PS39 changes `ALLOWED_TYPES` and the style copy in `bridge-publish-snapshot.mjs`, and the production bridge serves live as well.
- 6 call sites on develop read the layout and profile flags (`git grep isLayoutModesEnabled|…`).

### Decision 3, PS31

**Scores**: blast 3, reversibility 4 before any writer and 2 after, cost on failure 2 for the DDL, confidence 4. **Blast is the worst**, because of the batch stop below.

Production `osionos_pages`:
- PostgreSQL 16.15, 10,098 rows, 63 MB total relation size;
- 353 pages with a cover, 17 with a `cover_position`;
- `cover text NULL` and `cover_position real NULL` exist, `cover_height` and `cover_width` are absent.

Constraints are 3 CHECKs (surface, template_surface, visibility), 2 FKs and the pkey. None names a cover column.

Grants:
- The table grants go to `postgres` and `service_role` only. `anon` and `authenticated` hold 0 column privileges (`osionos-service-role-only-migration.sql`).
- `cover_position`'s column privileges come only from the table grants. A new column inherits them, and no column GRANT is needed.

Triggers:
- There are 8 triggers. The UPDATE triggers read named fields only:
  - `osionos_page_bump_version` compares `content` (`osionos-page-version-migration.sql:84-85`);
  - `osionos_publish_unhold` reads `archived_at`, `owner_id` and `workspace_id` (`osionos-publish-migration.sql:111-113`).
- No trigger copies a whole row, so an added column changes no trigger.
- No view depends on the table.

Lock and space:
- The longest open transaction at the probe was 0 s.
- `b2b-backup.timer` runs hourly (last run 19:01, next 20:00). Its `pg_dumpall` holds ACCESS SHARE for the whole dump, so an `ALTER` during it waits.

**The precedent** is `models/osionos-page-cover-position-migration.sql`: a bare `ADD COLUMN IF NOT EXISTS cover_position real`. The pattern to follow is `models/osionos-account-readme-migration.sql:53-89`:

- `BEGIN`;
- `SET LOCAL lock_timeout = '5s'` with a Caveat;
- a dependency `DO` block;
- the `ALTER`;
- `COMMIT`;
- `NOTIFY pgrst, 'reload schema'` after the commit;
- a manual DOWN that rolls back the code first.

**The snapshot trap.** `/var/backups/b2b/dumps` looks like the natural private place for the snapshot. But `/usr/local/sbin/b2b-backup:17` and `:177` run `rm -f "$DUMPS"/*` every hour, so a snapshot left there is deleted within 60 minutes. `/var` has 67 G free and the database is 282 MB.

**The replay trap.** `groot_meta.models_state` does not exist on the VM (probe: `relation … does not exist`).
- `models_converge` therefore sees a hash mismatch (`scripts/lib/datacenter-models.sh:43-55`).
- The next `make all` from any machine replays all 89+ `models/*.sql` files on production after `dump_postgres`.
- `--check` cannot see column gaps (`apply-models-migrations.sh` header). Whether a full replay leaves production unchanged is UNKNOWN.

**The batch-stop failure.**
- `publishResultFor` maps every status except 403, 404 and 413 to `"failed"` (osionos develop `src/store/sync/publishResult.ts:55-60`).
- `"failed"` stops the whole flush batch and backs off (`src/store/sync/pageFlush.ts:25`).
- Three things therefore turn into "no page edit persists" for that tab:
  - a CHECK violation (23514);
  - a fractional height in an integer column (22P02);
  - a column a backend lacks (PGRST204).
- This happened before, with `cover_position` (`apply-models-migrations.sh` header, "WHY THIS EXISTS").

**CI and fresh-clone.**
- `.github/workflows/models-grants.yml` runs on `models/**` for develop, main and feat/fix. `make models-grants-verify` (`utils/mk/baas.mk:73-80` → `scripts/verify/models-grants.sh`) applies the REAL runner to throwaway databases, fresh and upgraded.
- The osionos CI PostgREST stub declares `osionos_pages` columns at `tests/bridge/support/embed-postgrest.mjs:28-31`, which include `cover_position` and no size columns. It throws on an undeclared column.

### Unknown when this was written

- **U1.** The dev backend's columns. No `mini-baas-postgres` runs on this host (`docker exec` → "No such container").
- **U2.** PS22 boot numbers, PR14 and PR15 on any candidate.
- **U3.** Whether the README HTML subset image rendering on develop can be switched off on a live build, or is always on.
- **U4.** Whether `@osionos/feature-flags` can ignore the URL and localStorage overrides for a named flag.
- **U5.** Whether a full `models/*.sql` replay on production is a no-op.

## Decision

### Decision 1. The promotion is a frozen candidate D, cut after T serves (BLOCK now; the lift is RP1–RP24)

Order of record: T serves, then H′, then O9, then main is merged into develop, then D is cut, gated, fast-forwarded and swapped.

- **RP1.** T (ba24e781e or its O8c successor) meets O8c-4..8 and is served as O8c rules: green on its own main run, attempt 1, with T's own image, BR12 and the O-series checklist (ADR 0052 O1–O9 as amended). T is the first post-P1 image and becomes the rollback target for everything after it.
- **RP2.** H′ is re-created on T (O8c-10). It passes LP20–LP23, the split A/B against the live pin, because LP24 has not landed. H′ is served with its own BR12. Rollback is T. RP2 may be skipped only if RP15 carries the H′ evidence for D instead. The XSS sink stays live until one of the two serves (ADR 0063).
- **RP3.** O9's lift note is written (ADR 0052).
- **RP4.** Main is merged into develop under BR13a–c, never develop into main by hand.
  - Log `is-ancestor <main tip> <develop>` rc 0 and no `+` gitlinks.
  - Log `is-ancestor e5253d2 <engine gitlink>` rc 0 (LP18).
- **RP5.** The two develop async predicates, `blockLayoutModes.spec.mjs:39` and `blockStyleParity.spec.mjs:54`, become synchronous store reads as T fixed them. A repo-wide guard test fails on any `waitForFunction(async` in `tests/`. Develop CI is green after RP4 and RP5.
- **RP6.** D is a named sha. It is cut from develop after RP5 and never "develop tip at swap time". Every RP7–RP17 measurement names D's sha. Work that lands on develop after the cut is not in this promotion.
- **RP7 (re-rules FF-9).** F's separate swap is withdrawn. The long-fence reader reaches live inside D, with the interim 3-backtick writer (FF-7(e), 50406aa92) still in force.
  - Holds while the writer emits only 3-backtick fences. A writer that emits long fences, and so needs the FF-11 guard, gets its own ruling.
  - Proof: the 3-backtick writer is in D (`git merge-base --is-ancestor 50406aa92 D` rc 0), and `git grep` finds no long-fence emission in `pageMarkdownSerialize.ts`.
- **RP8.** FF-10's test is added and passes on D. It must fail on the e5253d2 engine, with the log saved.
- **RP9.** FF-12 runs reader-only: old = T's tree (engine 674dd65 or e5253d2 as served), new = D, with FF-10's fixture.
  - Content must be equal after both sequences.
  - Positive control: engine e5253d2 goes red on the fixture.
  - The no-guard mutant control is dropped, because there is no guard.
- **RP10 (re-rules PR13).** R-BR5 reaches live inside D, not in its own fast-forward. PR14 and PR15 run on D's production build, with their pass bars unchanged. PR16 is satisfied by RP19–RP21.
- **RP11.** LP24's engine cache fix has landed on engine main and D's gitlink contains it. If not, D carries an LP20–LP22 split A/B against the pin live at that moment, with a gating run, a mutant and a ratio of at least 0.90.
- **RP12.** U3-8 and U3-9 are resolved for D. Either:
  - (a) `img-src 'self' https: data: blob:` is in every CSP header in one commit, Report-Only first as ADR 0058:223 orders, plus the U3-9 disclosure and choice; or
  - (b) README HTML subset image rendering is shown to be off on D's live build, by a test against the built bundle.

  U3 is unresolved until one is shown.
- **RP13.** PS22: the `boot-ab.sh` ABBA comparison of D against T's build on the same host stays within the prod-perf baseline. Monaco must not be in the boot graph (the chunk list of the first navigation).
- **RP14.** CV9 is logged: `is-ancestor 80db0f484 D` rc 0.
- **RP15.** The full gate set runs on D's tree: typecheck, lint, quality, test-canvas, test-bridge and the e2e shards. D's own main run is green on attempt 1, with no reruns (O8c). Nothing is carried from T unless the dist is byte-equal.
- **RP16.** If the ADR 0066 boot fix is in D, BS10–BS12 bind. BS10 is the mobile A/B and needs the user with a device.
- **RP17.** Every unit in `T..D` is listed once, each marked either "cleared for live" (with its ruling) or "flag-off on live". A flag-off unit must also meet PH2. That list is BR13d's clearance.
- **RP18.** Main is fast-forwarded to D after a fresh `ls-remote`. The go counts at that moment only if RP1–RP17 hold.
- **RP19.** The image is built from D (`deploy-web-main.sh` STAGE=build) and its build meta recorded. The swap is STAGE=swap. BR12 checks that the served index chunk equals the local build of D.
- **RP20.** The probes after the swap:
  - the O-series checklist where applicable;
  - FF-4 clean;
  - a reload that shows D's build meta under `/sw.js?v=2` (ADR 0053);
  - one cover-reader probe on a positioned page (the position is kept after a reload);
  - zero console errors on boot.
- **RP21.** Rollback is the image that was live just before D (H′ or T). It is never `main-0333d796-site` and never `main-6de25733-site`.
- **RP22.** The groot pin `apps/osionos/app` moves to D after RP20 passes.
- **RP23.** The user reloads or closes every live and beta tab opened before D, and says so (FF-17).
- **RP24.** FF-17 closes after one further live deploy following D, with FF-4 clean throughout.

### Decision 2. Phases 6 and 7 continue on develop, live-locked (PwC PH1–PH8)

- **PH1.** Every Phase 6 and Phase 7 surface sits behind a flag that is off in every live build: the env is unset in the live deploy scripts, and the fallback is false.
- **PH2.** URL and localStorage overrides must not turn on anything ruled live-BLOCKED (Phase 6 per ADR 0064:6-8) in a live build. Either:
  - the flag reads env only when the build is live, with a test on the built bundle that `?<flag>=1` stays off; or
  - the code is not in D (RP17).

  U4 decides which is cheaper.
- **PH3.** No Phase 6 or Phase 7 code reads or writes `cover_height`, `cover_width` or a cover in the public snapshot until PS31 (CS16), CV12 and PS47 hold.
- **PH4.** Beta writes only formats that the currently served live reader round-trips.
  - Container kinds stay the existing ones (ADR 0064). `layout-sugar.test.ts` covers this.
  - The test runs against the engine pin of the build that is live at the time: today's 674dd65, then T's, then D's.
- **PH5.** The Phase 7 bridge changes (PS39 `ALLOWED_TYPES`, the style sanitizer) are not deployed to the production bridge until the client carrying PS40's publish-dialog notice is served live. If they must deploy earlier, they sit behind a bridge env switch that stays off. A production bridge serves live users' re-publishes.
- **PH6.** `MEDIA_URL_ENFORCE` is not flipped by this work.
- **PH7.** PS22 also binds Phases 6 and 7: neither adds to the boot chunk graph. This is checked in RP13 if they are in D.
- **PH8.** Phase 6 and Phase 7 commits that are on develop when D is cut appear in RP17's list. Commits after the cut wait for the next promotion and its own ruling.

### Decision 3. PS31 is one guarded single-file migration, applied alone (PwC CS1–CS16)

The owner is the new sibling file `models/osionos-page-cover-size-migration.sql`. The runner `scripts/apply-models-migrations.sh` picks it up in the alphabetical pass. It sorts after `osionos-bridge-migration.sql` (ORDERED_FIRST), which creates the table, so no ORDERED_* change is needed.

- **CS1. File shape**, following `osionos-account-readme-migration.sql`. Transaction 1:
  - `BEGIN; SET LOCAL lock_timeout = '5s';` with a Caveat line;
  - a `DO` block that raises if `public.osionos_pages` is missing;
  - `ALTER TABLE public.osionos_pages ADD COLUMN IF NOT EXISTS cover_height integer, ADD COLUMN IF NOT EXISTS cover_width text;` with no default, so the change is metadata-only and rewrites no rows;
  - two named constraints, each added only when `pg_constraint` lacks the name:
    - `osionos_pages_cover_height_check CHECK (cover_height BETWEEN 120 AND 640) NOT VALID`;
    - `osionos_pages_cover_width_check CHECK (cover_width IN ('full','content')) NOT VALID`;
  - `COMMIT`.

  Then, as transaction 2: `ALTER TABLE … VALIDATE CONSTRAINT` for both, under its own `lock_timeout`. VALIDATE takes SHARE UPDATE EXCLUSIVE and scans 10,098 rows, all NULL. Last: `NOTIFY pgrst, 'reload schema'`.

  Inline `CHECK` on `ADD COLUMN IF NOT EXISTS` is not allowed. If the column already exists on some backend, the inline constraint is skipped silently and the backend stays unconstrained.
- **CS2.** No GRANT and no REVOKE. The table grants (`service_role`) cover new columns. `osionos-service-role-only-migration.sql` runs last and is unaffected.
- **CS3.** The header names:
  - the PGRST204 / 23514 / 22P02 → `"failed"` → batch-stop chain (`publishResult.ts:55-60`, `pageFlush.ts:25`), and why no writer may name the columns before CS13;
  - a manual DOWN: roll back any code that names the columns first, then `DROP CONSTRAINT` ×2 and `DROP COLUMN` ×2, then NOTIFY. The DOWN is allowed only while CS15's count is 0.
- **CS4.** A replay is a no-op. Applying the file twice on a fresh database exits 0 both times and ends with exactly 2 new constraints, both validated.
- **CS5.** `scripts/verify/models-grants.sh`, or the fresh path it drives, gains these assertions:
  - after a fresh apply, both columns exist with the right types and are nullable;
  - both constraints have `convalidated = true`;
  - `cover_height = 100` and `cover_width = 'wide'` are rejected with 23514, while NULL is accepted;
  - a second runner pass is clean.
  - The mutant check: removing the constraint block must fail the gate.
- **CS6.** `models-grants.yml` is green on the commit's own push. This is the CI and fresh-clone evidence.
- **CS7.** A snapshot is taken on the VM before the DDL (CV11):
  - Command: `pg_dump -U postgres -d postgres -Fc` of the whole postgres database.
  - Location: a new root-only directory `/var/backups/b2b-ps31/` (mode 0700, file 0600, `umask 077`). **Never** `/var/backups/b2b/dumps`, which b2b-backup empties hourly (`b2b-backup:17`, `:177`).
  - Verification, the same way `dump_postgres` verifies (`datacenter-models.sh:11-24`):
    - `pg_restore -l` lists `TABLE DATA public osionos_pages`;
    - `pg_restore -f /dev/null` rc 0.
  - The report gives only the file size, its sha256 and the `osionos_pages` row count.
  - The file stays on the VM and is not copied off.
  - The snapshot is kept until the writer has served for 7 days. Its deletion is the user's call.
- **CS8.** The window opens only when all of these hold:
  - `systemctl is-active b2b-backup.service` is inactive;
  - more than 10 minutes remain before the next timer run;
  - the longest `xact_start` age in `pg_stat_activity` is under 5 s.
- **CS9.** The file is applied alone:
  `sudo -n docker exec -i mini-baas-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 < osionos-page-cover-size-migration.sql`.

  It is **not** applied through `make all` or `models_converge`. With no `groot_meta.models_state` on the VM, those replay every models file (U5), and that is not this ruling. If the run aborts on `lock_timeout` (55P03), nothing was written; retry once in a later CS8 window.
- **CS10.** Verification on production, read-only:
  - `information_schema.columns` shows `cover_height integer YES` and `cover_width text YES`;
  - `pg_constraint` shows both names with `convalidated = t`;
  - the `osionos_pages` row count equals CS7's count, give or take concurrent creates;
  - the counts of `cover_position IS NOT NULL` (17) and `cover IS NOT NULL` (353) are unchanged.

  The report gives counts only.
- **CS11.** The PostgREST reload is proven: a service_role read that names `cover_height,cover_width` with `limit=1` returns 200 with no PGRST204. The read goes through the bridge's own path or the PostgREST container, and its output is reduced to the status code.
- **CS12.** The dev backend (U1) shows the same CS10 query result after its next `make all`, or after a fresh dev bring-up. Until then, dev is unverified, and the PS31 lift is not met.
- **CS13.** The PS31 lift (ADR 0064 PS31) is met when CS6, CS10, CS11 and CS12 hold. Only then may `PAGE_LIST_SELECT` name the columns.
- **CS14.** The osionos CI stub `tests/bridge/support/embed-postgrest.mjs:28-31` gains `cover_height` and `cover_width` in the same commit that first names them in `PAGE_LIST_SELECT` or a PATCH. Not earlier: the stub's throw on undeclared columns is the guard against a column a backend lacks.
- **CS15.** The writer is still blocked by CV12. When it comes, the bridge validates both fields before PostgREST: an integer from 120 to 640, `full` or `content`. Anything else is declined into `ignored`, a partial apply that returns 200 and never reaches a 23514 or 22P02 from the database. The tests send 100, 700, 237.5, `"wide"` and `null`, and each must return 200 with the field in `ignored` or applied. The database CHECK is the backstop, never the first line, because a 400 stops the batch.
- **CS16.** The counts `cover_height IS NOT NULL` and `cover_width IS NOT NULL` are recorded at the writer's go. CS3's DOWN is allowed only while both are 0.

## Alternatives considered

- **Fast-forward main to 6e19a378f in one swap now**: lost.
  - It serves P1 with no post-P1 rollback image (K7).
  - It ships two new vacuous waits into the main CI that O8c exists to make honest (`blockLayoutModes.spec.mjs:39`, `blockStyleParity.spec.mjs:54`).
  - It carries the README HTML subset to live without U3-8 or U3-9 (`nginx.conf:22`).
  - It ships an engine pin past e5253d2 with no valid perf A/B (LP24).
  - Cost: an irreversible node-pages publish plus a forward-only P1 serve, both resting on four UNKNOWNs.
  - Recorded in `.out-of-scope/promoting-osionos-develop-to-main-before-t-serves.md`.
- **Keep FF-9 and PR13 as worded** (F's own swap, R-BR5's own fast-forward): lost. Neither unit can be built on main without reverting develop history: 94066bd09 ⊉ 50406aa92, and develop already holds the F reader. It would cost two extra irreversible pushes and swaps, each needing a cherry-pick tree that never ran on develop.
- **Fold H′ into D**: allowed by RP2, not preferred. The callout XSS sink stays live for the whole of RP4–RP19 instead of the one deploy H′ needs.
- **Apply PS31 through `make all`**: lost. It replays every models file on production with no marker (U5), so a one-file decision grows into an unruled whole-schema replay.
- **Inline CHECK in `ADD COLUMN IF NOT EXISTS`**: lost. The constraint is silently skipped wherever the column already exists.
- **No database CHECK, bridge validation only**: lost. A backfill or a direct SQL writer gets no guard. The CHECK costs about 0 on 10,098 NULL rows.
- **`real` for `cover_height`, matching `cover_position`**: lost. A height is a pixel count in 120–640, and `integer` plus CS15's validation makes 237.5 an `ignored` field instead of silent drift. `real` would accept 120.0001 forever.
- **Snapshot in `/var/backups/b2b/dumps`**: lost. It is deleted within 60 minutes (`b2b-backup:17`).

## Consequences

Execution checklist ("me" = the coordinator, CI = GitHub Actions, the user = the human):

| # | Who | Step | Gate |
| --- | --- | --- | --- |
| 1 | me | Write `models/osionos-page-cover-size-migration.sql` (CS1–CS3) and the CS5 assertions | — |
| 2 | CI | `models-grants.yml` green on that push (CS4–CS6) | blocks 5 |
| 3 | me | CS8 window check on the VM (read-only) | blocks 4 |
| 4 | me | CS7 snapshot to `/var/backups/b2b-ps31/`; report size, sha256 and row count | blocks 5 |
| 5 | me | CS9 single-file apply (the go of 2026-11-19 counts) | — |
| 6 | me | CS10 and CS11 verification; record CS16's zero counts | — |
| 7 | me / the user | CS12 dev backend: whoever runs the next `make all` on a dev machine | PS31 lift (CS13) |
| 8 | me | T: O8c-4..8, push T to main (fresh `ls-remote` first) | — |
| 9 | CI | T's own main run green on attempt 1 | blocks 10 |
| 10 | me | Build and swap T, BR12, O-series checklist (RP1) | — |
| 11 | me + CI | H′ on T, LP20–LP23, serve (RP2), or defer to RP15 | — |
| 12 | me | O9 lift note (RP3) | — |
| 13 | me | Merge main into develop, fix the 2 async waits plus the guard test (RP4, RP5) | — |
| 14 | CI | Develop green | blocks 15 |
| 15 | me | Cut D (RP6); RP7–RP14 and RP17 evidence on D | — |
| 16 | the user | BS10 mobile A/B, only if the boot fix is in D (RP16) | blocks 17 |
| 17 | me | Fast-forward main to D (RP18) | — |
| 18 | CI | D's own main run green on attempt 1 (RP15) | blocks 19 |
| 19 | me | Build and swap D, BR12, RP20 probes; rollback = H′ or T (RP19–RP21) | — |
| 20 | me | groot pin to D (RP22) | — |
| 21 | the user | Reload or close every pre-D live and beta tab and say so (RP23) | FF-17 |
| 22 | me | One further live deploy, then FF-17 closure (RP24) | — |
| — | me | Phases 6 and 7 on develop at any point, under PH1–PH8; nothing in them may touch cover sizes before step 7 plus CV12 | — |

D's main run exists only after the push in step 17. Until step 18 is green, step 19 does not start. A red run means a forward fix on main, never a force-push.

Blocking UNKNOWNs, each a FAIL until shown:

- U2 PS22, PR14 and PR15 on D: they block step 17.
- U3, the README image rendering on a live build: it blocks step 17 unless RP12(a) lands.
- U4, the flag override lock: it decides PH2's route and blocks Phase 6 code from entering D.
- U1, the dev columns: it blocks the PS31 lift (CS13), not the production apply.
- U5, the whole-models replay: not blocking here. The next `make all` against the VM is an unruled production schema replay and should face its own ruling before anyone runs it.

What becomes harder:

- D is frozen, so a late develop fix waits for the next promotion or needs a new cut and the whole RP7–RP17 set again.
- Removing the CHECKs later is a migration of its own.

Reverse this when:

- T has served and the H′ and O9 rulings are closed, so RP1–RP3 fall away;
- LP24 lands, so RP11 shrinks to LP18;
- `@osionos/feature-flags` gains a live lock, so PH2's test becomes a one-liner.
