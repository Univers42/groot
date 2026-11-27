# DRAFT: ADR 0067 follow-up, cover-size writer (CS12 re-rule, CS13–CS16 lift record)

- Status: draft, untracked. Ruled by devil 2026-11-23. Full ruling: `/mnt/storage/dlesieur/scratch/cover-writer/RULING.md`.
- Scope: osionos page-shells plan Phase 5 (resizable cover), the half that writes `cover_height` / `cover_width`.

## Q1. CS12 closes by a container run, not by `make all`

**Verdict: PROCEED-WITH-CONDITIONS. All four conditions are met or recorded below.**

Two facts decided it:

- **E2. Dev on this host is production's database.** `make -n -p` gives `DATACENTER_ON := b2b`; with it set, `utils/mk/pipeline.mk:17-21` has no `backend-up` and no local `models-migrate`, and `link-models-migrate` (`utils/mk/grobase-link.mk:117-126`) applies models to the linked VM Postgres. CS10 already verified that database.
- **E4. CS6 has CI proof.** Workflow `models-grants.yml`: run 44589463074 on cc492b81 (2026-11-19 18:35Z) and run 45157295612 on cad7fc17 (2026-11-23 10:34Z) both succeeded, the second with 20 `PASS (fresh|legacy) cs_*` lines.

| Condition | Result | Evidence |
| --- | --- | --- |
| C1.1 clean-worktree run | **PASS** 2026-11-23 14:37:49Z | groot worktree at origin/main fc8b03ad (contains ff55db2c), `apps/grobase` at db2f7ab1. `sh scripts/verify/models-grants.sh` → rc 0, `RESULT: 404 passed, 0 failed`, 20 of 20 `cs_*` rows PASS (10 fresh, 10 legacy). Image `ghcr.io/univers42/grobase-postgres@sha256:41fae831688d42f2eeca18d7d5debaa6d47c2ea6d53482f357694853d0959819`. Log `scratch/cover-writer/c1/c1.1.log`. |
| C1.2 mutant run (closes E7 / U-a) | **PASS as a negative** 2026-11-23 14:41:25Z | Same worktree, `MODELS_DIR` = a copy of `models/` whose cover-size file keeps ADD COLUMN and drops both ADD CONSTRAINT blocks and the VALIDATE step. rc 1, `RESULT: 392 passed, 12 failed`. The 12 failures are all cover checks, 6 per scenario: `cs_validated`, `cs_height_low`, `cs_height_high`, `cs_width_wide`, `cs_constraint_count`, `cs_validated_after_replay`. Log `scratch/cover-writer/c1/c1.2.log`. |
| C1.3 records | this file | E2 and E4 above. |
| C1.4 | standing | Nobody runs `make all`, `make up` or `link-models-migrate` from the main checkout (HEAD 44711366, which lacks the cover-size file) for this purpose. U5 stays unruled. |

No `models-grants-*` container was left behind after either run (`docker ps -a --filter name=models-grants-` → 0 rows).

**Invariant added:** any local-mode bring-up, or desktop build, that carries a size-writer bridge is built from a tree where `git merge-base --is-ancestor ff55db2c <tree>` is rc 0.

Rejected: closing CS12 as vacuous (a future local bring-up from a tree without ff55db2c would lack the columns). Blocked: a real `make all` on this host (it is U5 on production).

## Q2. CS13–CS16 lift record: two units in a fixed order

CS13 holds once item 2 is read: CS6 (E4 + C1.2), CS10/CS11 (`scratch/ps31/RESULT.md`), CS12 (Q1).

| # | Unit | Acceptance criterion |
| --- | --- | --- |
| 1 | Gate 0 | C1.1–C1.3 pass. **Done.** |
| 2 | Gate 0 | CV12 re-read from the running live build at the go: 9bf8f6be0, f5eb51ca0, 80db0f484 each an ancestor. **Met 2026-11-23 20:28Z** for live web `main-d2db4373-site` (`git merge-base --is-ancestor <c> d2db43733` rc 0 ×3); re-read at the go if the web image changes. |
| 3 | A bridge | `coverHeight` integer 120–640, `coverWidth` `full`\|`content`; anything else goes into `ignored` with 200 and the rest of the edit is written; `null` clears; absent key leaves the column; no clamp (CS15 supersedes PS27 for the bridge). |
| 4 | A | Tests for 100, 641, 700, 237.5, `"wide"`, `null`, on insert and update. |
| 5 | A | Row→page mapping emits the fields only for valid values, never a `null` key. |
| 6 | A | `PAGE_LIST_SELECT` names both columns and the CS14 stub gains them in the same commit. |
| 7 | A | `PAT_RESOURCES.pages.attributes` gains both fields; drift test updated. |
| 8 | A | `KEPT_FIELDS` in `bridge-publish-snapshot.mjs` gains no cover size (PH3/PS47). |
| 9 | A | `test-bridge`, `test-bridge-stub`, lint `--max-warnings 0` green on develop. |
| 10 | A | CS16 first record: both `IS NOT NULL` counts immediately before Unit A serves on the production bridge (expected 0/0). The CS3 DOWN window is decided here. |
| 11 | A | Reaches production only through the bridge promotion, as its own cleared unit; served bridge sha recorded, Unit A an ancestor. |
| 12 | A | Probe on a probe-owned page: PATCH 240/`content` → GET has both; PATCH `null` → GET has no key; counts 0/0 again. Status codes and counts only. |
| 13 | B client | Handle clamps to 120–640 and rounds before the store and outbox (PS27 client half). Starts only after item 11. |
| 14 | B | `pageToPatchBody` sends each field only when set; a clear sends `null`; an unresized page's body has no size key (PS28). |
| 15 | B | Measured page-cache delta of a resized page under 64 characters; ledger-suffix delta reported (PS29; estimate 41 + 13). |
| 16 | B | Handle is `role="separator"` with `aria-valuenow/min/max`, keyboard step, axe pass (PS30). |
| 17 | B | PS25, PS26, CV4 and the cover-position tests stay green unedited. |
| 18 | B | CV15 ends narrowly: user pages may carry sizes; the static catalogue test still asserts zero size fields; `templateCopy.ts:3` comment updated in the same commit. |
| 19 | B | No Phase 6 or Phase 7 code reads or writes sizes; public snapshot has none until PS47. |
| 20 | B | typecheck, canvas, lint, test-bridge, test-bridge-stub, e2e shards; RED first. |
| 21 | B | CS16 second record: counts at the Unit B go. |
| 22 | B | Beta probe: resize, reload keeps it; a live tab shows it after its fetch; zero console errors. |
| 23 | B | Reaches live only inside a promotion with its own clearance. This ruling clears develop and beta only. |

**Amendment to item 3 (2026-11-23, reviewer on 8a1095d22):** `ignored` applies to PATCH. POST create drops an invalid size and answers the stored page (201, no size key). Reasons: the parent commit dropped every size on create, so this is additive; `createdReply` (`bridge-pat-middleware.mjs:68`) would strip an `ignored` key for PAT callers and the client would spread it into the page entry (`pageStore.actions.ts:300-302`); create already normalises title, icon and cover position silently. Unit B note: `ignoredWarning` (`outboxRecovery.ts:42-45`) words every non-parent `ignored` field as a sharing change, which is wrong for a cover size.

**Promotion checklist addition (security review):** confirm both columns exist on the target database before the bridge swap; `PAGE_LIST_SELECT` names them, so a backend without them answers 502 on every page list.

## Q3. Client writer before the bridge serves the fields: BLOCK

Today's bridge answers 200 to a write carrying the size fields and stores neither; the client confirms the stamp, so the size is stranded in one browser's cache with no error. Recorded in `.out-of-scope/cover-size-client-before-bridge.md`. Rollback order is client, bridge, then the manual DOWN only while both counts are 0.

## Still unknown

- U-b: the served live web sha (item 2).
- U-c: the production bridge's served sha and deploy branch (item 11).
- U-e: whether a desktop install built from a tree without ff55db2c exists; binds only if a desktop build carries Unit A.
