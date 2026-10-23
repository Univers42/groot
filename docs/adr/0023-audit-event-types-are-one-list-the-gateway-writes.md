# 0023. Audit event types are one list, and the gateway is its only writer

- Status: accepted
- Date: 2026-10-19
- Deciders: owner, after a devil ruling (2026-10-19, BLOCK of the first plan, then pre-ruled PROCEED-WITH-CONDITIONS)

## Context

- The auth gateway (`apps/opposite-osiris`) records security events through the RPC
  `auth_record_audit_event`. It never inserts into `auth_audit_events` directly.
- `models/auth-security-migration.sql` kept the list of accepted event types twice, 36 names each: the
  table's CHECK, and an `IF event_type NOT IN (...)` inside the function that raises SQLSTATE 22023
  before the INSERT. A third copy sat in `CREATE TABLE` and was dropped later in the same file.
- The first plan widened only the CHECK. That was a no-op: the function refused first, and the test
  proposed for it compared the writers to the CHECK alone, so it would have passed while the function
  refused.
- The gateway at opposite-osiris 47ca59e writes 35 types the 36 do not hold, not the 8 first counted.
  The verdict listed 32; the three `login_approve_*` ones passed to `otp.revoke` from
  `scripts/auth/login-approve.mjs` were missed there and found by the test.
- A refused write loses the event and logs one WARN. The request carries on, so nothing alerted. The
  gateway's own tests mock the RPC, so its CI cannot see the drift either.
- groot's pin of the gateway (8559d6dd) is 39 commits behind its main and writes only 35 types in total,
  so a test that reads the pin alone exercises almost none of the missing ones.
- groot's migration runner never applies this file (it assumes an INTEGER `users.id`), and grobase's
  `apply-project-sql.sh` re-applies it on every run. Prod's live definitions are therefore of unknown
  origin.

## Decision

- **One list.** The function loses its `IF ... NOT IN` block. Its INSERT is wrapped so that a
  `check_violation` on `auth_audit_events_event_type_check` re-raises as
  `Unsupported audit event type` with SQLSTATE 22023, and any other violation re-raises unchanged. The
  documented contract (public docs, `gdpr-auth-security-migrations.xmd`) is kept. Signature, SECURITY
  DEFINER, `search_path`, grants and return shape are untouched.
- **71 types**: the 36 existing, the 32 the verdict listed and the 3 the test found. None is removed:
  historic rows may hold the nine that nothing writes today.
- The inline CHECK in `CREATE TABLE` is deleted.
- `scripts/tests/auth-audit-event-types.bats` reads the gateway's `scripts/auth-gateway.mjs` and
  `scripts/auth/*.mjs` (`OSIRIS_SRC` overrides the checkout) and asserts writers are a subset of the
  list, and that the list has no missing or doubled comma. Under `CI=true` a missing source fails the
  job instead of skipping it, and `fresh-machine.yml` passes `-e CI` into the bats container.
- `scripts/tests/auth-audit-runtime-check.sh` applies the three models to a throwaway
  `postgres:16-alpine` and proves 71 of 71 recorded and 22023 on an unknown type.

## Alternatives

- **Widen the CHECK only.** A no-op, because the function's own list refused first.
- **Drop the allowlist for a format CHECK `^[a-z][a-z0-9_]{2,63}$`.** Ends the cross-repo drift for good,
  at the price of the "no garbage types" guard. Viable, since only `service_role` can write
  (`rls-hardening-migration.sql`). It is the option to take if the drift recurs.
- **A lookup table with a foreign key.** A new type becomes an INSERT instead of DDL, at the cost of one
  more table and one more seed path.

## Consequences

- Every new audit type in the gateway needs a line in this list, in the same change cycle. The bats test
  is the guard, and it only sees a gateway checkout that is recent enough: bump the pin or run it with
  `OSIRIS_SRC`.
- The extractor is regex over six call shapes (`scripts/tests/lib/audit-event-writers.sh`). A name
  routed through a seventh helper is missed, which under-reports.
- The repo change does not touch prod. The apply on the baas VM is operator-run (conditions C10-C14 of
  the ruling): read-only pre-checks, one transaction with `lock_timeout = 3s`, a rolled-back smoke over
  all the types, then `VALIDATE CONSTRAINT`. It starts from the live definitions, never from the repo
  body pasted over them. Anything on the VM that re-applies an older copy of the file at boot must be
  updated first, or the next restart narrows the list again.
- Until ML-6/7 lifts the bar on the runner, that apply stays a hand-run on b2b.
