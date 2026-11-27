# DRAFT. Apply the AI-modes schema live, then promote osionos-ai b0506a1d4 with flags off

- Status: proposed (devil ruling, numbered when taken)
- Date: 2026-11-23
- Deciders: devil (risk ruling); the controller session that runs the apply and promotion carries the conditions
- Plan ruled on: `/mnt/storage/dlesieur/scratch/ai-modes/live-plan.md`
- Parent ruling: `docs/adr/DRAFT-ai-modes-ruling.md` (AM1–AM20, 2026-11-22)

## Verdict

| Part | Verdict | Worst axis |
| --- | --- | --- |
| (a) schema apply | **PROCEED-WITH-CONDITIONS** (AM-L1–AM-L5, AM-L12) | confidence 3: A4 (which DB) not proven |
| (b) image promotion | **PROCEED-WITH-CONDITIONS** (AM-L6–AM-L11, AM-L13–AM-L15), only after AM-L5 passes | cost on failure 4: latent taint hole at a later flag-on |

## Steel-man

The plan is better than most live schema changes:
- The migration is additive and idempotent.
- It was dry-run on a copy of the three live tables: 66/2/203 rows, max statement 3.4 ms, second pass idempotent (`am7-dryrun.log`).
- It runs under `lock_timeout 5s` with `ON_ERROR_STOP`.
- The new image's modes feature is off unless `OSIONOS_AI_MODES === 'on'` (`src/modes/modesConfig.ts:49`), and that env name is absent from the live container.
- The old image uses explicit column lists everywhere, so a rollback needs no schema down.
- The gates on b0506a1d4 are green, develop CI included.

The case for proceeding is strong. What follows narrows it; it does not reverse it.

## Context (facts)

### Migration (`models/osionos-ai-modes-migration.sql`, md5 1653e48c…, identical on groot origin/main)
- `SET lock_timeout='5s'` at :29. There is **no BEGIN**. psql stdin without `-1` runs in autocommit, so each statement is its own transaction.
- :43–51: add the provenance columns with a `'legacy'` default, then set the default to NULL. PG 16 stores the add-time default as attmissingval, so the existing rows read `'legacy'` and later inserts get NULL.
- :53–54: `ai_approvals.decided_by` and `ai_runs.turn_id`, both nullable.
- :56–77: three CHECKs added `NOT VALID` (ACCESS EXCLUSIVE, metadata only), then `VALIDATE` (SHARE UPDATE EXCLUSIVE).
- :80–81: `CREATE INDEX IF NOT EXISTS ai_approvals_auto_turn … WHERE decided_by LIKE 'auto:%'`. It is **non-concurrent**, so it takes SHARE and blocks writes to ai_approvals while it builds. With 2 rows that takes ms.
- Header :20–22 claims "old image on the new schema is safe (additive)". That is true for availability and **false for the taint invariant** (see "The failure nobody mentioned").

### Dry run (`am7-dryrun.log`, `am7-dryrun.sh`)
- The source was a `pg_dump --no-owner --no-privileges` of the 3 tables into a networkless postgres:16-alpine. Restore errors: 1 relation, 3 role.
- So the copy had **no FK targets, no grants, no event triggers**. It proves the DDL shape and timing. It does not prove lock interaction with ai_messages FKs, PostgREST, or live triggers.
- Pass 1 took 50 ms, pass 2 took 41 ms. legacy 66/66, defaults NULL, constraints validated, index 1.

### Service delta 68ed56642..b0506a1d4 (A1), read in the worktree at b0506a1d4
Flag-gated (inert when off):
- `routes/conversationMode.ts:60`, `routes/turnUndo.ts:80`, `routes/appliedList.ts:86`: 404 before auth.
- `modes/autoGate.ts:59`: undefined, so no auto writes.
- `modes/effectiveMode.ts`: manual unless flag + allowlist + run kind + credential all allow a mode.
- `runs/planPrompt.ts`: changes the prompt in plan mode only.
- `builders/undoApproval.ts:42`: `not_a_plan` when the flag is off.
- `modes/writeBudget.ts`: settle is immediate with no tracked writes.

**Ungated** (these reach every user):
1. `provenance/runStart.ts` `markRunStart`: with the flag off it runs `markProvenanceTaint(db, id, 'legacy')` on **every run** (`provenance/repo.ts`: `update ai_conversations … where id=$1 and provenance_tainted_at is null`). If it throws, `runs/runMode.ts` returns null and `runs/runner.ts` refuses with **503 `provenance_unavailable` after the user message is appended**. This is a new failure mode on the hot path.
2. `runs/repo.ts` insertRun writes `turn_id = coalesce($N::uuid, $1)`. `approvals/claim.ts` writes `decided_by`, and `approvals/repo.ts` COLUMNS reads it. On the old schema all three fail with 42703, which is why schema-first is mandatory.
3. `approvals/describe.ts` adds `decidedBy`, `undoneAt`, `undoable`. `isUndoable` (`approvals/undoApplied.ts:139`) is **not flag-gated**, so a card can say `undoable: true` while the undo route answers 409 `not_a_plan`. Live web ignores the field today, but a client that reads it would show a dead button.
4. `approvals/apply.ts` rename_page now reads `select title from public.osionos_pages` for previousTitle, and a failed read becomes null. `approvals/applyAppend.ts` sends the same single bridge write with the same single retry; the recorded result is a superset (tool, block ids, sha256).
5. `approvals/execute.ts` is refactored into `applyClaimed` + `continueRun` (`continuation.ts`). The may-train gate is preserved, and runKind 'decided' carries the credential.
- Build closure: no diff to `package.json`, `pnpm-lock.yaml`, `tsconfig.json` or the 13 `scripts/*.mjs` the Dockerfile copies. The `scripts/` names new in src are comments only.

### Old image on the new schema (A2)
- `conversations/repo.ts:42` inserts `(owner_id, workspace_id, title)`. `runs/repo.ts:97/101` and `approvals/repo.ts:69` use explicit columns. The only `r.*` is over osionos_pages (`workspace.ts:78`).
- New columns are nullable or NOT NULL with a default (`assist_mode 'manual'`), so the old INSERTs succeed.
- The bridge scripts (`bridge-chat-ai.mjs`, `bridge-chat-autopost.mjs`) read ai_runs through PostgREST with an explicit `select=`.
- Conclusion: **available**, yes. **Invariant-preserving**, no (see below).

### Live (read-only)
- `track-binocle-osionos-ai-1` runs `boost-68ed5664`, image id prefix `sha256:09345515b9e7`. The chain ends `…ai-boost.yml:ai-silent-stop.yml`.
- The only modes-related env name present is the DB URL. No `OSIONOS_AI_MODES*` and no `OSIONOS_AI_AUTO*`.
- The service DB endpoint is a tailnet address on :15433. The plan applies through `ssh b2b … docker exec mini-baas-postgres`. **Nothing proves these are the same cluster and database** (A4 open).
- The indexer (`5224ebc45f86`, `node src/indexer/main.ts`) shares the DB. Its code does not reference the three tables (empty `git grep`).
- groot `docker-compose.public.yml` passes no `OSIONOS_AI_MODES`. The groot-ai-modes worktree commit cb62cdd8 pins it to `""`.
- `scripts/verify/ai-public-smoke.sh` runs unauthenticated checks only; every session check prints SKIP. **It exercises none of the changed paths.**
- `DEPLOY-NOTES.md` has no entry for the silent-stop promotion that is live now.

### Unknown when written
- A4: DB identity across the two paths.
- Event triggers and grants on the live tables, which the copy lacked.
- Live write traffic at apply time.
- Whether PostgREST reloads its schema cache on this DDL, and what that costs given `postgrest-oom-verdict`.
- The node patch version the floating `node:22-bookworm-slim` resolves to today, compared with boost-68ed5664.

## Risk scores

| Axis | Score | Why |
| --- | --- | --- |
| Blast radius | 3 | every AI run, through the new per-run UPDATE and 503 path; not the bridge or web |
| Reversibility | 2 | image back in seconds; columns, constraints and index stay (harmless, additive) |
| Cost on failure | 3 now / **4 latent** | 3: a run outage or 503s, data intact. 4: NULL-provenance conversations escape the legacy taint at a future flag-on (AM3/F1 injection surface) |
| Confidence | 3 | A4 unproven; the dry run lacked FKs, triggers and grants; the smoke proves nothing on changed paths |

## The failure nobody mentioned

**The rollback path silently breaks AM3's taint invariant.**
- AM3 means: every pre-modes conversation is sticky-tainted `legacy`. The migration stamps only the rows that exist **at apply time**.
- Any conversation the **old** image creates after the apply gets `provenance_tainted_at = NULL`, because the default was dropped and the old image never calls `markRunStart`. Two windows produce such rows:
  - the gap between schema apply and image recreate;
  - any time after a rollback to `boost-68ed5664`.
- With the flag off, the new image stamps `legacy` lazily on the next run of such a conversation, so the hole closes for conversations that are used again.
- It stays open for:
  - conversations that are not run again before a flag-on;
  - the first run of each such conversation after a flag-on, when `markRunStart` takes the modes branch for allowlisted users instead of the legacy stamp.
- That conversation's history was built without provenance tracking and may carry member page content. That is exactly the injection source F1 names.
- At ~66 conversations total, a 10-minute rollback window yields a handful of rows. The count is small; the class is the one the parent ruling scored 4.
- The fix costs one UPDATE and binds the flag-on step (AM-L12).

**Second-order:** the new image adds a write on every run. If the provenance UPDATE ever fails (lock wait behind a later DDL, role grant, statement timeout), the user sees 503 after their message is stored. The old image had no such path. AM-L11 watches for it.

## Decision

- (a) The schema applies live under AM-L1–AM-L5.
- (b) The image promotes only after AM-L5 passes, under AM-L6–AM-L11 and AM-L13–AM-L15.
- AM-L12 binds the future flag-on ADR, not this deploy.

## Alternatives considered

- **`psql -1` (single transaction).** It would make a partial state impossible. It loses because it holds ACCESS EXCLUSIVE on all three tables until the end, so the lock chain spans every statement instead of each one. The file's guards already converge on re-run, and a failed non-concurrent CREATE INDEX leaves no invalid index. Acceptable either way; per-statement autocommit is fine **given** AM-L4/AM-L5 block the image on a partial schema.
- **Keep the `'legacy'` defaults until flag-on.** This closes the taint hole at the source. It loses for now because the new image relies on NULL to mean "not yet decided" (`provenance/repo.ts` `where provenance_tainted_at is null`), and a default of 'legacy' would stamp every new conversation legacy forever, including under modes. AM-L12 (re-stamp before flag-on) gets the same safety without changing the design.
- **`CREATE INDEX CONCURRENTLY`.** Not worth it at 2 rows, and it cannot run inside the file's guards. Rejected.
- **Promote the image without the schema.** 42703 on every run and every approval read. Rejected.

## Consequences: conditions (acceptance criteria)

Before the apply (a):
- **AM-L1, DB identity.** `select system_identifier from pg_control_system()` plus `current_database()`, taken through the service's own connection (exec into osionos-ai, a read-only query) and through the `ssh b2b … mini-baas-postgres` path, must be equal. Print only the comparison result, never the DSN. If they differ, BLOCK.
- **AM-L2, pre-checks (read-only).**
  - None of the 8 new columns, 3 constraints or the index exist. If any does, it must have the exact expected type or definition.
  - `select * from pg_event_trigger` is listed and empty, or reviewed.
  - `pg_stat_activity` shows no pg_dump and no transaction older than 5 s.
  - Grants on the three tables for anon/authenticated are recorded, so AM-L5 can compare them.
- **AM-L3, backup.** Dump the three tables (or the DB, per the existing backup practice) to the osionos-ai-records backups directory, mode 600, and record the row counts, before the apply.

Apply and verify (a):
- **AM-L4, apply.** Run with `ON_ERROR_STOP=1` and record the exit code. On non-zero, re-run (idempotent) until 0, or stop. Never proceed to (b) on a partial schema.
- **AM-L5, post-apply verification.** This is the gate for (b). All of these must hold:
  - 8 columns with the expected types.
  - Provenance defaults NULL; `assist_mode` NOT NULL default `'manual'`.
  - 3 constraints `convalidated = true`; the index exists.
  - `count(*) where provenance_reason='legacy'` equals the pre-apply conversation count.
  - Row counts on all three tables are unchanged.
  - Grants are unchanged.
  - PostgREST shows 0 restarts, and its memory stays under its 512m cap for 5 min.

Image (b):
- **AM-L6, build provenance.**
  - Build from a clean worktree at exactly b0506a1d4 with the same Dockerfile and `--frozen-lockfile`.
  - Record `node --version` in the new image and in boost-68ed5664. A major/minor difference must be stated.
  - `:pre-modes` must resolve to the same image id as the running container (`sha256:09345515b9e7…`), checked before the recreate.
- **AM-L7, rollback dry check.** `rollback-ai-modes.sh` uses the live chain minus `ai-modes.yml`, ending `ai-boost.yml:ai-silent-stop.yml`. `docker compose … config` over that chain renders image `boost-68ed5664` and an env set identical to the live one (names only).
- **AM-L8, env after recreate.** No `OSIONOS_AI_MODES*` and no `OSIONOS_AI_AUTO*` names in the container env; RestartCount 0 after 5 min. If an allowlist value is ever set without a valid UUID, the service throws at import and crash-loops, so the names must stay absent.
- **AM-L9, quiet recreate.** Recreate only when `ai_runs` has 0 rows `status='running'` and `ai_approvals` has 0 rows `status='executing'`. Keep the gap between AM-L5 and the recreate as short as practical (it is a taint window, AM-L12).
- **AM-L10, authenticated smoke.** Use a test account on its own scratch page, and end with `scripts/revoke-automation-sessions.sh`. All of these must hold:
  - One run completes, and its row has `turn_id = id`.
  - Its conversation has `provenance_reason='legacy'`.
  - Approval list/describe answer 200.
  - Manual approve sets `decided_by='user'` and the bridge write lands.
  - The non-build_plan undo answers 409 `not_a_plan`.
  - `/conversations/:id/mode`, `/runs/:id/undo-writes` and `/conversations/:id/applied` answer 404.
  - `ai-public-smoke.sh` passes, and the live and beta probes pass.
  - The SKIP lines of the public smoke are not counted as passes.
- **AM-L11, log watch.** 10 min after the recreate: zero `42703`, `provenance_unavailable`, `provenance_check_failed` and `mode_read_failed` in the osionos-ai logs. Any one means rollback.

Bound to later steps:
- **AM-L12, re-stamp before flag-on.** Immediately before any `OSIONOS_AI_MODES=on`, run `update ai_conversations set provenance_tainted_at=now(), provenance_reason='legacy' where provenance_tainted_at is null` and record the count. The flag-on ADR must cite this result. Run it again after any rollback to an image older than b0506a1d4.
- **AM-L13, records.** Add a DEPLOY-NOTES entry for this promotion **and** the missing silent-stop entry, with image ids, chain, rollback command, and schema apply time.
- **AM-L14, `undoable` field.** Record that `describe.ts` `undoable` is not flag-gated. It must be gated on `config.modesEnabled`, or documented as advisory, before the web flag `osio.ai.modes` goes on anywhere.
- **AM-L15, indexer.** The indexer stays on `5224ebc45f86` (its code does not touch the three tables). If it is rebuilt from b0506a1d4 later, that is a separate promotion with its own smoke.

## Lock risk (for the record)
- Each ACCESS EXCLUSIVE statement waits at most 5 s.
- While it waits, new readers and writers on that table queue behind it. That includes FK checks from `ai_messages` inserts, which take a row lock on `ai_conversations`.
- Worst case visible to users: a ≤5 s stall on AI requests, then the statement fails and the queue drains.
- A long transaction or a running pg_dump makes the ALTER fail, not hang. That is safe, so re-run later.
- The dry run measured statements, not queueing. At 06:00Z traffic, accept this.

## Re-rule triggers
- AM-L1 mismatch.
- Any non-empty `pg_event_trigger` on the target tables.
- A node major/minor difference.
- Any AM-L11 hit.
- A request to set `OSIONOS_AI_MODES` (that is the flag-on ADR, not this one).
