# DRAFT. A page id re-created after a hard delete continues its content version; it never restarts at 0

- Status: proposed (draft, unnumbered). devil 2026-11-23, osionos #344: (b) PROCEED-WITH-CONDITIONS P344-1–P344-10; (a), (c) and (d) BLOCK.
- Date: 2026-11-23
- Code read: osionos worktree `osionos-am-l14` at 1fe84e440; groot `develop`.

## Context

- The version is `bigint NOT NULL DEFAULT 0` (`models/osionos-page-version-migration.sql:76`). Only a BEFORE UPDATE trigger moves it: `+1` when content changes, otherwise unchanged (`:85-86`, `:93`). Nothing fires on INSERT.
- Restore cannot move it backwards. Unarchive is a PATCH of `archived_at` alone, so content is unchanged and so is the version (`scripts/bridge-api.mjs:4598-4650` with migration `:86`). Restoring older content is a content PATCH, which adds 1. The issue body's "restore" wording does not describe a path that lowers the version.
- Delete forever followed by a create with the same id restarts at 0. `handlePageDelete` hard-DELETEs the rows (`bridge-api.mjs:5153-5174`). A create may carry its own id (`:850`, C156) and is a plain INSERT (`:4407`). With no row left there is no 23505, so `replayOrConflict` (`:4387`) never runs, and the new row gets DEFAULT 0 plus whatever content the creator sent.
- Who sends a client id: the osionos-ai builder, which mints a plan's ids once (`services/osionos-ai/src/builders/plan.ts:6`) and retries them. Any API caller can also send one. The app's own create sends no id. Its copy recovery makes a new page (`src/store/sync/refusedEditDeps.ts:91`).
- After the reset, writes take the new row back to the stale base version. A client still holding base vN (the outbox carries it, `src/store/sync/pageOutbox.ts:111`) then passes the `version=eq.N` precondition (`bridge-api.mjs:4637`), gets a 200, and replaces the whole content array. Nothing records the loss.
- The bridge is not the only deleter. Deleting a workspace cascades to its pages (`models/osionos-bridge-migration.sql:51`), and account erasure runs `DELETE FROM osionos_pages` (`models/osionos-account-erasure-migration.sql:725`). A fix in the bridge alone would miss both.
- The undo probe compares versions by order (`page.version > baseVersion`, `services/osionos-ai/src/approvals/undoProbe.ts:36`), so the version must only go up for a given id. `undoBlocks.ts:68` reads the version fresh before each PATCH and does no arithmetic on it.
- The bridge test mock acts as the trigger (`tests/bridge/support/bridge-harness.mjs:183`). A mock-only bridge test therefore cannot be a real RED for a database fix.
- Not known when this was written: the bug has not been reproduced. Hard deletes made before the migration leave no record of their last version.

## Decision

(b) is adopted. An AFTER DELETE trigger writes each deleted id and its final version to a tombstone table. A BEFORE INSERT trigger then sets `NEW.version` to the tombstone's version + 1 when one exists, and to 0 when none does, whatever the payload carried. Versions for a given id therefore only go up, across every delete path. The bridge, old clients and the API surface do not change.

## Alternatives considered

- **(a) Tombstone that refuses the re-create with 409 or 410**: BLOCK. It needs the same tombstone as (b). It also breaks the C156 replay contract (`tests/bridge/bridge-idempotent-create.test.mjs`) and adds a status the builder does not handle. It fixes a different question, whether a deleted page may come back, not the version. That question needs its own ruling.
- **(c) A global sequence behind the version**: BLOCK. It changes what every content write's version means, on the hot trigger. It also leaks to every tenant the instance-wide rate of content writes, because the gap between your own two versions counts other tenants' writes. To lift it: show the version is opaque per tenant, or that this rate is not sensitive.
- **(d) Client only**: BLOCK. Only the server knows that a deletion and a re-create happened. A client that never saw them cannot detect them, and old clients would stay exposed.

## Consequences (conditions P344-1–P344-10)

1. P344-1. Write the RED test first, as check c10 in `scripts/verify/page-version/` on a throwaway database. Create page X, make 2 content updates (v2), DELETE X, INSERT X with the same id, then run `UPDATE … WHERE id=X AND version=0`. It must touch 0 rows, and X.version must be 3. Today it touches 1 row. A bridge test may follow, but a test that turns green only because the mock changed does not count.
2. P344-2. The tombstone is written in the database, not in the bridge. c10 covers all three delete paths: a PostgREST DELETE, the workspace cascade and `osionos_account_erase`. The trigger runs under each of their roles without a permission error.
3. P344-3. The tombstone keeps `GREATEST(existing, OLD.version)`. Use a statement-level trigger with `REFERENCING OLD TABLE` so that deleting a 5,000-page workspace costs one statement.
4. P344-4. No per-id `pg_advisory_xact_lock` in the delete path. Every advisory lock takes a slot in the shared lock table (`max_locks_per_transaction` × connections), and a large cascade can exhaust it.
5. P344-5. Close the race lock-free. A BEFORE INSERT trigger running while the DELETE is still uncommitted reads no tombstone. An AFTER INSERT recheck must therefore raise SQLSTATE 40001 when `tombstone.version >= NEW.version`, and the bridge answers that with a retryable status, never a 201. c10 tests it with two sessions.
6. P344-6. The BEFORE INSERT trigger always overwrites `NEW.version`, so no payload can set it.
7. P344-7. The migration is additive and safe to replay: `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE`, `DROP/CREATE TRIGGER`, and no row updates. Check c6 extends to cover it. The rollback SQL in `scripts/rollback/` drops the triggers and the table.
8. P344-8. The tombstone holds only `(page_id uuid PK, version bigint)`: no owner, title or timestamp, so erasure leaves nothing personal in it. It is never pruned, because pruning reopens the bug for any client whose base is older than the cutoff. Estimated size, not measured: under 100 B per hard-deleted id.
9. P344-9. A `Caveat:` in the migration states that ids hard-deleted before it was applied have no tombstone and can still restart at 0.
10. P344-10. c1–c9, the bridge suite and `services/osionos-ai` undo tests pass unchanged. The trigger order block in the migration header lists the two new triggers.

## Evidence (2026-11-23, branch fix/page-version-344, commits 4f97d9db + cad7fc17)

| Condition | Proof |
| --- | --- |
| RED | `scripts/verify/page-version.sh` before the migration: `FAIL c10 … re-created id reads version 1 (expected 3); stale write at version 0 touched 1 row(s)` |
| GREEN | same command after: `RESULT: 10 passed, 0 failed` (c1–c9 unchanged, c10 new) |
| Grants | `scripts/verify/models-grants.sh`: `RESULT: 404 passed, 0 failed` (rc=0) |
| P344-5 | the AFTER INSERT recheck raises 40001; PostgREST 12.2.3 retries it, the client gets 201 at the correct version |
| P344-10 | the bridge suite and the osionos-ai undo tests run on mocks that load no groot model, so the migration cannot change them; last develop run green apart from the known ws-lane EADDRINUSE flake |
| Size | 5,000-page workspace delete writes 5,000 tombstones in 103 ms |

Not covered: the erasure path is exercised by its DELETE statement, not by calling the erase function. Live apply is a separate step (backup, `scripts/apply-models-migrations.sh`, rollback SQL ready, probe).
