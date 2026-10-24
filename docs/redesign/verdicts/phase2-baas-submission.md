# Phase 2 re-submission: seed the Arlet demo straight into baas, additive only

For the devil, 2026-10-16. It replaces L1 of [phase1-devil.md](phase1-devil.md) Verdict A.

## What changed since the re-ruling

- **The user ruled (D-039)** that there is no local grobase. The seed goes straight into the baas
  VM, additive only: "we want to accumulate information not destroy them". It may go ahead when
  the other session agrees.
- **groot-69 does not object**, and is not the authority. Its constraints:
  - no write at HH:00–HH:07 (b2b-backup `pg_dump`);
  - not during gc at 00:39:55;
  - not while `deploy-mountlist-baas.sh` runs (tenant-control is recreated, and `/v1/tenants/*`
    can answer 502 for up to about 11 min);
  - stay under the shared Kong bucket (120/min, 3000/h), and stop on 429;
  - keep the databases small (VM MemAvailable is 6372 MiB, measured 00:01);
  - don't touch `.env.local`, `.env.grobase-link`, the image tags or the link stack;
  - no vault42 push.
- **This session cannot read or write the VM's databases.** The classifier refused even a
  `tenant_databases` count ("Production Reads", 2026-10-16 00:02). Every privileged step is
  therefore in **one human-run script**.

## The plan

`scripts/demo/seed-baas.sh` runs on the host, and the user starts it with `!`:

1. Generates the dataset (`scripts/demo/generate.mjs`, deterministic: seed 42, anchor date in the
   manifest) into a git-ignored bundle under `scripts/demo/out/`.
2. Pipes the bundle and `scripts/demo/vm-bootstrap.sh` to `ssh b2b bash -s`. Inside the VM:
   - **Guards first:**
     - refuses at minutes 00–07;
     - refuses unless the uid8 is 8 hex digits;
     - refuses every name outside `^demo_[0-9a-f]{8}_(crm|activity)$`;
     - refuses if `demo_<uid8>_*` exists but is not in the passed manifest, which makes a re-run
       on its own manifest the only idempotent path;
     - refuses if the tenant has no `mongodb` engine allowed (402/403 on register: stop).
   - **Counts before:** `auth.users`, `tenants`, `tenant_databases`, `osionos_pages`,
     `osionos_workspace_members`, `osionos_workspaces`.
   - **Postgres, as the superuser, bootstrap only:**
     - `CREATE ROLE demo_<uid8>_crm LOGIN` with a password generated inside the VM;
     - `CREATE DATABASE demo_<uid8>_crm OWNER` that role;
     - `REVOKE CONNECT … FROM PUBLIC`;
     - schema and data applied with `SET ROLE demo_<uid8>_crm`, so the role owns every object;
     - one transaction for the data.
   - **Mongo:** `createUser demo_<uid8>_activity` with `readWrite` on its own database only, then
     import as that user from a sibling `mongo` container (the `seed-live-demo.sh:181-193`
     OOM precedent).
   - **Mounts:**
     - `POST http://127.0.0.1:8000/admin/v1/databases` inside the VM, with the Kong service key
       read from the kong container's env (never printed) and `X-Tenant-Id: agency` (the bridge's
       tenant: `VITE_BAAS_TENANT_ID=agency` in `.env.local`, the compose default);
     - the DSN uses the demo role, never `postgres` or `mongo`;
     - 409 means it is already registered: look the id up by name and do not overwrite.
   - **GoTrue users** `ines.caradec@arlet.example.com` and `jules.marchand@arlet.example.com`:
     - `POST /auth/v1/admin/users` with `email_confirm: true`;
     - an existing address is looked up and **not** modified;
     - passwords are generated on the host and stored in git-ignored `.env.demo-arlet` (mode 600,
       through `lib/envfile.sh`), never printed.
   - **Workspaces:**
     - "Arlet — Operations" and "Arlet — Finance review", owned by Inès;
     - Jules is a viewer member of Finance review only;
     - `osionos_workspace_databases` rows link the two mounts to Operations only;
     - all `INSERT … ON CONFLICT DO NOTHING`.
   - **Directory:** `directory_opt_out` is set for both users (condition 10), if the column
     exists; otherwise a DECISIONS line.
   - **Counts after:** each counted table differs by exactly the expected demo delta. Otherwise
     the script exits 1 and says which table (condition 9).
   - Prints the manifest (ids only) on stdout. The host stores it at
     `scripts/demo/manifests/baas.json` (git-ignored).
3. **Pages and object databases go through the running bridge as Inès:**
   - `https://localhost:4000`, the link stack, used as a client and never modified;
   - one `POST /api/pages` per page, looked up by `seed_key` first, paced at ≤ 60/min, honouring
     429 `Retry-After`;
   - `[[seed:x]]` is swapped for `[[page:<id>]]` in a second pass.
4. **Verify (`--verify`)**, read-only, also human-run:
   - counts against `stats.json`;
   - KPI views reconciled with the row sums;
   - links per record ≥ 3 and 0 orphans;
   - `select 1 from pg_authid` fails as the demo role, and the mongo demo user cannot read
     `admin` (G2: SKIP fails);
   - Jules gets 403 from the bridge on every demo mount id, and the shared page opens for him
     (L3).

**Dropped for baas:**
- **reset** (the user: accumulate, never destroy). Reset and its L4 guards stay local-only and
  out of scope until a local grobase exists.
- the `/admin/v1/migrate` ledger runner (condition 3). The schema is applied once as the owning
  role, in one transaction, and is idempotent (`IF NOT EXISTS`, `CREATE OR REPLACE VIEW`,
  upserts). The **spike** (condition 1) becomes the first run with `--only spike` (one record per
  mapping), checked in osionos before the bulk run.

## Assumptions

- A1. The bridge reads mounts registered in tenant `agency` on baas. Unverified on baas; the
  spike proves it.
- A2. `mini-baas-postgres` superuser is `POSTGRES_USER` and `mini-baas-mongo` root is
  `MONGO_INITDB_ROOT_*` on baas, as in compose. Read inside the VM, never printed.
- A3. The adapter-registry reaches `postgres:5432` and `mongo:27017` by compose DNS.
- A4. Mount-backed board/gallery/calendar views work. Unproven; the spike gates it.
- A5. The size is about 15 MB of pg data and about 1 MB of mongo, small next to 6.4 GiB free.

## Failure modes

- A half-run, for example ssh dropping mid-way: every step is idempotent, and a re-run with the
  manifest resumes. No step deletes.
- A wrong tenant: the mounts are invisible to the bridge. Harmless, and re-registering under the
  right tenant is additive.
- Rate limit: pages stop on 429 and resume from the manifest.
- The password file leaks: these are demo users on `arlet.example.com` with no admin role.
  Mitigation: mode 600, git-ignored, covered by `make secrets-scan`.

## Unknown

- Whether GoTrue on baas has SMTP autoconfirm. `email_confirm: true` makes it moot.
- Whether `osionos_*` on baas has the `directory_opt_out` column (D-039 records the fallback).

---

## Verdict (2026-10-16)

### Steel-man

Additive-only removes the worst hazard of the last two hearings, which was a reset that could
delete a shared tenant. Loading the schema directly in the VM avoids the Kong `/admin/v1/migrate`
caps (256 KB, 30/min, `kong.yml:647`) and the ledger complexity that only reset needed. Every
privileged step sits in one human-run script that has a name pattern, a time guard, counts and a
spike. Writing pages through the running bridge as Inès is what any user does. The mount
registration follows the working precedent (`osionos-extra-engines.sh:115-128`).

### What the source says that the submission does not

| # | Finding | Evidence |
|---|---|---|
| P1 | The precedent derives the tenant from the app key's verify response. The plan instead takes `agency` from the host's **frontend** var `VITE_BAAS_TENANT_ID`, while the bridge uses `OSIONOS_BAAS_TENANT_ID`. With no reset on baas, a mount registered under the wrong tenant stays there for good and counts against that tenant's `max_mounts` quota | `osionos-extra-engines.sh:107`; `docker-compose.yml:90`; `register.go:107-110` |
| P2 | `directory_opt_out` is a column of `osionos_bridge_identities`, and that row exists only after the user's first bridge login. If the VM step runs `UPDATE` before then, it changes **0 rows** without an error, and both users stay listed: the directory reads `public.users` LEFT JOIN that table. The bridge does expose `PATCH /api/profile/me {directoryOptOut}` | `osionos-people-directory-migration.sql` view (`COALESCE(bi.directory_opt_out,false)`); `osionos-social-migration.sql:19`; `bridge-profile.mjs:178,246` |
| P3 | The session token carries `workspace_ids` from the time it is signed, and the mount ACL reads `osionos_workspace_members` only, so the owner has no access without a member row. The VM step must insert **Inès's owner row** in both workspaces before her first login | `bridge-api.mjs:403-416,3055-3065,3620-3641` |
| P4 | `osionos_workspaces.id` defaults to `gen_random_uuid()` and `slug` is UNIQUE. "ON CONFLICT DO NOTHING" with server-generated ids never conflicts, so a re-run creates duplicate workspaces | `osionos-bridge-migration.sql:28-32` |
| P5 | Resume deadlock: the manifest is printed only at the **end**. If ssh drops after `CREATE DATABASE`, the re-run's "exists but not in the manifest" guard refuses for good. There is no reset, so the uid8 is burned and its role and database are orphaned. A 409 does not update the DSN, so a lost role password needs `ALTER ROLE` | submission §2; `osionos-extra-engines.sh:137-138` |
| P6 | Exact total deltas on a live, shared platform give false failures: the other session's e2e writes users, pages and members on the same baas | submission "Counts after"; ADR 0003 |
| P7 | Both precedents put secrets in argv (`apikey: ${SERVICE_KEY}`, the Mongo root password), where `ps` shows them | `osionos-extra-engines.sh:118-121`; `seed-live-demo.sh:186-191` |
| P8 | Logging in a user created through GoTrue admin goes through the bridge, then the auth-gateway, which was coded against legacy `public.users` columns. Whether this works is UNKNOWN | `bridge-api.mjs:3748`; `auth-gateway-users-reconcile-migration.sql:5-29` |

### Rulings on the four questions

- **Dropping reset and the ledger runner on baas: sound.** The trade-off is that `IF NOT EXISTS`
  silently ignores a schema edit made after the spike (condition 5).
- **Superuser bootstrap: sound, if it is limited to the bootstrap.** `SET ROLE` keeps a superuser
  session underneath, so one quoting bug in the generated data SQL runs as superuser (condition 4).
- **Using the host bridge as a client: sound.** It is the only path that makes pages the way the
  product makes them.
- **Human-run boundary: sound.** It stays.

### Risk

| Axis | Score |
|---|---|
| Blast radius | 3 (superuser and service key on the shared platform; writes are limited by name) |
| Reversibility | 3 (no reset; an orphan from a failed run is permanent) |
| Cost on failure | 2 |
| **Confidence** | **3 (worst):** P1, P8 and view support rest on the spike |

### Verdict: **PROCEED-WITH-CONDITIONS**

1. **Manifest before any write.** The host writes uid8, every name and the deterministic
   workspace ids and slugs before ssh. The VM appends ids to a state file with no secrets. Resume
   rules: if the role exists and the mount does not, `ALTER ROLE … PASSWORD` is allowed for
   `^demo_[0-9a-f]{8}_crm$` only; if the mount exists (409), nothing is changed. A bats test kills
   the run after `CREATE DATABASE` and checks that the re-run completes.
2. **Tenant from the bridge's own key, or from its `OSIONOS_BAAS_TENANT_ID`, read only.** The run
   refuses unless that tenant already holds the `osionos-*` mounts.
3. **Workspaces get UUIDv5 ids and fixed slugs.** Owner rows for Inès and Jules's viewer row are
   written before the first login.
4. **Schema and data are loaded by a session that logs in as the demo role**, with
   `ON_ERROR_STOP=1 -1`, not by superuser plus `SET ROLE`. Mongo is loaded as the demo user.
5. **Schema fingerprint.** A `demo_schema` table (file, sha256) lives inside the demo database. A
   changed file is refused, and changes ship as new files that only add.
6. **No secret in argv** on the host or the VM: stdin, `--config -` or `-H @file`. A
   mutation-tested bats test checks this, on the a66dba9a precedent.
7. **Directory opt-out goes through `PATCH /api/profile/me`** as each user, right after that
   user's first login. Verify reads the people list and asserts both users are absent.
8. **Invariance is scoped.** The demo rows' delta must be exact. Non-demo ids that existed before
   the run must all still exist. A static bats check: the bootstrap contains no `DELETE`,
   `DROP`, `TRUNCATE`, or `UPDATE`/`ALTER` outside conditions 1 and 7.
9. **Windows are checked before each phase and each page batch, not only at the start.** Pause at
   :58 and resume at :08. No writes 00:30–00:50. Refuse while `deploy-mountlist-baas` runs on the
   host or the VM.
10. **Spike first, as `--only spike`.** It proves P8 (Inès logs in and sees both workspaces), P1
    (the bridge lists the spike mount) and the view support, before bulk. Fallbacks go to
    DECISIONS. Leftover spike objects stay unless the user records otherwise (D-039).
11. **Re-runs insert row data with `DO NOTHING`**, so edits made while recording survive.
12. **G2 is extended:** as the demo role, connecting to `postgres` and reading `auth.users` must
    fail.

Record owed: ADR 0005's Status and Consequences are superseded for baas (no reset, VM bootstrap,
conditions 1–12). Its amendment was not written here, because this file was the only write the
caller named.
