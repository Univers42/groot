# 0028. A second role reaches account-plane tables, through RLS and column grants

- Status: proposed (P0-1 spec, devil ruling PROCEED-WITH-CONDITIONS, 2026-10-22); not yet built
- Date: 2026-10-22
- Deciders: owner, after a devil ruling on `docs/account-platform/wp/P0-1.md` (osionos app repo)
- Numbered 0028 because `origin/develop` already holds 0027 (embed unfurler).

## Context

- Today every `osionos_*` table is reachable by `service_role` and nothing else
  (`models/osionos-service-role-only-migration.sql:3`, `scripts/verify/models-grants.sh:6-7`). The
  bridge holds the service key and enforces ownership in JavaScript.
- Account data (sessions, then profiles, settings, emails) needs a second wall: a bug in one bridge
  handler must not hand user A's rows to user B. The app ADR `apps/osionos/app/docs/account-platform/adr/0001-account-jwt.md`
  defines the per-user token the bridge mints for this.
- Measured on a throwaway `--network none` PG 16.15 with grobase 001/012 and the real runner (devil, 2026-10-22):
  the uid helper returns NULL for every forged claim set tried; column grants refuse `select=*`;
  `(SELECT uid())` plans as an InitPlan; a replay leaves no ACL drift. Also reproduced: a hand-made
  role with `BYPASSRLS` survives a `pg_roles`-guarded CREATE and reads B's rows; taking the audit
  table's lock before the identities index deadlocks a concurrent sign-in (`40P01`).

## Decision

A dedicated role `osionos_account_user` (NOLOGIN, NOINHERIT, NOBYPASSRLS, normalized on every run)
reaches tables marked `COMMENT … 'osionos:account-plane'` and nothing else, through column grants
and RLS policies keyed on `public.osionos_account_uid()`. Only the bridge signs tokens for it; GoTrue
never issues that role. Every other `osionos_*` table stays service-role-only.

## Consequences

- The invariant of `osionos-service-role-only-migration.sql` gains one exception, checked by k1–k8 of
  `models-grants.sh` (role reach limited to marked tables; RLS on, policies keyed on the helper; role
  shape; exact column set; isolation and forged-claim rows).
- The 12 conditions of the ruling are acceptance criteria of P0-1: `users-pii-grants-migration.sql`
  stays last in `ORDERED_LAST`; the role is normalized each run; indexes before audit columns, ADD
  COLUMN only when missing, `lock_timeout 5s`; a standalone-apply check; the audit table's realtime
  trigger dropped; the checks made load-bearing; the helper comment corrected (non-JSON claims raise
  22P02 and still fail closed); orphan identities counted before P0-4; `ip_hash` is keyed HMAC;
  desktop wiring owned by P0-4; the ledger runner's behaviour in the header; `models-first-run.sh` as a gate.
- `ON DELETE CASCADE` on `auth.users` deletes session rows instead of revoking them: the bridge
  treats a missing `jti` row as revoked.
- Rolling back is a manual DOWN block, valid only while nothing reads these objects; the role is
  cluster-wide.
- Found on the way, not part of this decision: `anon` can execute `auth_record_audit_event`
  (`auth-security-migration.sql:178` revokes from roles that never held the grant; PUBLIC does).
  Filed separately.
