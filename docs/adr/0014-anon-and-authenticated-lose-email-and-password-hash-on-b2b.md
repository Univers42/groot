# 0014. On b2b, anon and authenticated hold no privilege on movieverse_profiles and no SELECT on users.password_hash; anon has no users.email

- Status: accepted with conditions (ML-1 to ML-9; containment is user-run on the VM)
- Date: 2026-10-17
- Deciders: devil (risk ruling of 2026-10-17). The user runs every b2b step.

## Context

- public.movieverse_profiles on b2b has 98 rows, all with a non-empty email; 98 match public.users and 90 match
  auth.users. Policy mv_profiles_select is `SELECT TO public USING (true)` and anon holds column SELECT on email
  (orchestrator measurement, 2026-10-17, counts only).
- `GET https://baas.tail10f2ea.ts.net/rest/v1/movieverse_profiles?select=email&limit=5` with the b2b anon key,
  from the public internet, answered 200 with 5 addresses (same measurement).
- No reader of the table exists in source: grobase on b2b at 0ffbe51e mentions it only in
  `scripts/verify/m200-public-tables-rls.sh:112` (`git grep -n movieverse_profiles`); 066/067 and
  `vendor/MovieVerse` were removed (`apps/grobase/CLAUDE.md:476,686-689`; `ls /opt/grobase/vendor` fails).
- public.users: anon and authenticated hold SELECT on every column, password_hash included (16 non-null). The
  only policy is own-row through `auth.current_user_id()`, which falls back to the GUC `app.current_user_id`
  when the JWT has no sub (grobase `scripts/migrations/postgresql/016_unify_rls.sql:21-27`).
- Re-grant sources: grobase `make migrate` re-runs every file each time (`orchestrators/makes/50-migrate.mk:15-16`),
  and `001_initial_schema.sql:91,94` grants table-level SELECT on users to authenticated and anon. Groot
  `models/gdpr-migration.sql:816-817` grants email to anon and authenticated; `scripts/apply-models-migrations.sh:110`
  skips it, `scripts/apply-models.sh` does not.
- Kong and WAF access logs start at 2026-10-17T17:26:05Z and 18:05:25Z (container start, json-file 3x10m). The
  only movieverse_profiles lines in Kong are two 200s at 20:52 and 20:53 UTC from 172.18.0.1.
- Unknown when this was written: whether the b2b anon key was ever in a public artifact, and who fetched the
  table before 17:26Z. Nothing on the VM records it.

## Decision

In one transaction on b2b: REVOKE ALL on movieverse_profiles from anon and authenticated; REVOKE ALL on users
from anon, then grant back SELECT (id, username, is_email_verified); REVOKE SELECT on users from authenticated,
then grant back SELECT on every column except password_hash. The prior ACL is captured first as an executable
rollback file. The SQL was dry-run on postgres:16-alpine: the after-state holds exactly one email/password_hash
SELECT grant (users, authenticated, email), and the rollback restores the before-state.

## Alternatives considered

- **Column grant (id, username, role, status, created_at) on movieverse_profiles**: keeps a surface nobody
  reads, and `role` names the admins among the usernames. No reader exists (git grep above).
- **Leave authenticated's password_hash**: own-row only today, but own-row rests on a GUC fallback (016:21-27)
  and no client reads the hash; the gateway uses the service key (opposite-osiris `scripts/auth-gateway.mjs:240,576`).
- **Revoke the column only (`REVOKE SELECT (email)`)**: a no-op while a table-level SELECT exists. The table
  grant has to go and the columns come back.
- **Drop movieverse_profiles**: removes real emails from a demo table, but it is a one-way door and needs its
  own ruling.

## Consequences

- Any anon `movieverse_profiles` read and any authenticated `users?select=*` now answers 42501. No caller in source does either.
- The next `make migrate` on b2b re-opens users through 001:91,94 until grobase ships a late-sorting migration
  that repeats the revoke. Until then nobody runs `make migrate` or `make apply-models` against b2b (ML-6, ML-7).
- Incident record: emails of 98 users were readable by any b2b anon-key holder for an unknown window. The
  notification decision depends on whether that key was ever public (ML-9).
