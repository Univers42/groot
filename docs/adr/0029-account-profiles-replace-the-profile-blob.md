# 0029. Account profiles replace the profile blob

- Status: proposed (P1-1 spec, devil ruling PROCEED-WITH-CONDITIONS, 2026-10-22); not yet built
- Date: 2026-10-22
- Deciders: owner, after a devil ruling on `docs/account-platform/wp/P1-1.md` (osionos app repo)
- Numbered 0029 because `origin/develop` already holds 0028 (a second role reaches account-plane tables).

## Context

- A profile today is a jsonb blob on `osionos_bridge_identities.profile`, written read-modify-write by
  the bridge (`apps/osionos/app/scripts/bridge-profile.mjs:120-134,182-206`): two concurrent edits lose
  one, and nothing in the database can tell the two writers apart.
- The people directory is a view that recomputes `to_tsvector()` per row over a three-way join
  (`models/osionos-people-directory-migration.sql:45-63`; its own header called that a "ponytail" note).
  Every search is a sequential scan over three tables.
- Usernames have two homes: `public.users.username` (the gateway enforces `^\w[\w.-]{2,31}$`,
  `apps/opposite-osiris/scripts/auth/identity.mjs:11`) and `osionos_bridge_identities.username` (the
  bridge accepts any 48 characters). Nothing holds a username's history, a user's settings, or a
  deletion request.
- The account plane already has a role and a uid helper (`docs/adr/0028-a-second-role-reaches-account-plane-tables-through-rls.md`).
  This package adds the tables that role needs and nothing else.

## Decision

Four account-plane tables and one rebuilt view, all in
`models/osionos-account-profiles-migration.sql`:

- `public.osionos_profiles` — one row per user (`user_id` PK, FK to `auth.users` ON DELETE CASCADE).
  The profile's own columns: `display_name`, `username`, `pronouns`, `headline`, `bio`, `location`,
  `company`, `website`, `links`, `timezone`, `orcid`, `patreon`, `avatar_url`, `banner_url`,
  `directory_opt_out`, `version`, timestamps, and a stored `search_doc` tsvector.
- `public.osionos_user_settings` — one row per `(user_id, section)`, so a write to one section never
  contends with a write to another. `public.osionos_user_settings_merge(text, jsonb)` merges a patch
  in one statement.
- `public.osionos_username_history` — the 90-day hold on a name a user gave up.
- `public.osionos_account_deletion_requests` — the 14-day grace before an account goes.
- `public.osionos_people_directory` — the directory view, rebuilt over `osionos_profiles`. The old
  file (`models/osionos-people-directory-migration.sql`) becomes a tombstone: nothing re-creates the
  old view, and the view's `NOTIFY pgrst` moved with the file that owns it.

The username is one name per user, and the name's rules are the gateway's, not the bridge's:
`^[A-Za-z0-9_][A-Za-z0-9_.-]{2,31}$`, never a reserved route word, unique on `lower(username)`.

## Consequences

The five conditions of the PROCEED-WITH-CONDITIONS ruling are the acceptance criteria of P1-1, and
each one is a consequence of this decision:

1. **The settings merge needs table-level UPDATE, not a column grant on the merged value.** The
   `ON CONFLICT (user_id, section) DO UPDATE` path reads the arbiter columns and writes `version` and
   `updated_at`, so the role holds SELECT on `(user_id, section, value, version, updated_at)`,
   INSERT on `(user_id, section, value)` and UPDATE on `(user_id, section, value, version, updated_at)`.
   With less, every merge call fails with `permission denied`. (D-P1-1 condition 1)
2. **A function a CHECK calls is re-checked for EXECUTE at DML time.** The username's reserved list
   and the ORCID check digit live in functions (a CHECK may not contain a subquery), so EXECUTE on
   `osionos_username_reserved(text)` and `osionos_orcid_valid(text)` is granted to
   `osionos_account_user` and `service_role`. Without it the account role's own
   `UPDATE … SET display_name` and the service-role legacy sync both fail with
   `permission denied for function`. (D-P1-1 condition 2)
3. **The backfill is two passes.** One statement with `ON CONFLICT (user_id)` aborts the whole
   statement on a single username collision — every boot, and nobody gets a profile. Pass 1 inserts
   the chosen usernames with a bare `ON CONFLICT DO NOTHING` (any constraint); pass 2 inserts every
   source user still without a profile with `username = NULL`. The backfill only ever inserts: it
   never overwrites a profile the trigger or the user already wrote. (D-P1-1 condition 3)
4. **The index check is expression-, predicate- and uniqueness-aware.** `k4` compared the key columns
   only, so an index on an expression was invisible (`indkey` holds 0 for an expression column) and a
   unique index made plain still passed. The comparison is now on the whole shape: the key columns
   with their expressions, the access method (and the opclass where it is the point), the uniqueness
   and the partial predicate. (D-P1-1 condition 4)
5. **The `NOTIFY pgrst` moved after the `COMMIT`.** The tombstone takes the old file's NOTIFY with
   it, and the view is dropped and recreated, so PostgREST must reload the schema only once the new
   view exists — before the commit it would cache the dropped view's OID. (D-P1-1 condition 5)

Other consequences:

- The migration file is over the 300-line house rule: the spec mandates one ORDERED_LAST file, and it
  holds four tables, nine functions, five triggers, the directory view and the backfill.
- The lock order is the hot paths' order: registration takes `public.users` and then
  `osionos_profiles`, sign-in takes `osionos_bridge_identities` and then `osionos_profiles`, and the
  file takes `users`, `identities`, then the new tables, under a 5 s `lock_timeout`. A registration
  waits for the whole file (about 250 ms at 10K rows), and a writer that holds a lock for more than
  5 s makes the replay abort on `lock_timeout` (55P03), failing that boot until the next one.
  `scripts/verify/account-lock-race.sh` races the three against each other and reports the
  deadlocks and the timeouts apart.
- The account role may SELECT every column of a profile (they are all public profile fields) and
  UPDATE only the thirteen the user owns. The avatar and banner columns stay out of reach until
  P0-6 owns them, and `version` and the timestamps stay the server's.
- Other people's profiles are read through the directory view by the bridge's service role. ADR 0001
  ("not decided here") still governs who may read what over HTTP.
- The hold on a released name is enforced where the name is claimed (a BEFORE trigger on
  `osionos_profiles`), and the history is the record of it. The owner may reclaim their own name.
- A user keeps their place in the directory: the backfill gives every `public.users` row with an
  `auth.users` row a profile, and a new user gets one from a trigger on `public.users` that never
  raises — a registration must not fail, and the next boot's backfill heals the gap.
- The legacy path stays until P1-2: an AFTER trigger on `osionos_bridge_identities` copies the
  profile blob's `headline`, `bio` and `location` into the profile's own columns, and takes a valid,
  free username. It never touches `display_name` and never raises.
- The legacy path copies only what changed, field by field. The identities row is written on every
  sign-in and whenever one field of it moves; a copy of everything would overwrite a value the user
  typed through the new account route with an older value from the blob. On an UPDATE each field of
  the blob is copied only when its own key moved — a write that moves the avatar key (the avatar
  package rewrites it for every user with a data: avatar) leaves the headline, the bio and the
  location alone; on an INSERT everything is copied, because there is nothing to compare against.
- A write that changes nothing changes nothing: the trigger's own UPDATEs skip a row they would not
  change, and the profile's version moves only when the row really changed. A version that moves on
  a no-op makes the next If-Match fail for nothing.
- The directory view keeps the old column order (the old bridge image selects them by name) and
  adds `headline` at the end. `display_name`, `username`, `search_doc` and `headline` are the
  profile's own columns, with no COALESCE, so the indexes apply.
- Two details of the view and the indexes are load-bearing, not taste:
  - The `user_profiles` join is a LATERAL. A plain LEFT JOIN lets the planner hash-join the whole
    legacy table — a sequential scan of every `user_profiles` row — where a nested loop with the
    unique index on `user_id` finds the one row. The directory lookup is the query that must not
    scan a legacy table, and the plan is pinned rather than left to the cost model.
  - The GIN indexes are created with the fast update technique off. A GIN index that keeps a
    pending list holds its newest rows outside the index proper, so the planner's cost model and the
    index's statistics describe an index the query will not walk, and the directory search falls
    back to a sequential scan of the profiles. The profiles are written a few times per user, so
    the batching the pending list buys is worth nothing here. An install that already has the index
    without the option gets it from the one ALTER that only runs when the option is missing.
- The rare-term directory search is gated on the plan, not only on the timing: the harness's
  `require_plan_nodes` budget key says the plan has to come back as a bitmap index scan, because a
  btree walk that removes 4001 rows passes a no-sequential-scan budget in O(N) and never touches a
  GIN index.
- Out of scope, each with the package that first reads it: emails (P3-1), follows (P2-3), presence
  (P0-5), `readme_page_id` (P2-1), and avatars in storage (P0-6 — the avatar columns exist here but
  stay NULL, and the view keeps the legacy fallback).
- Rolling back is a manual DOWN block in the migration file, valid only while nothing reads these
  objects: the view is the bridge's directory, and the moment the profiles are gone the People panel
  is empty.
