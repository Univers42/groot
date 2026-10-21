# Eval Data Plane

**What this is:** an isolated Docker Compose project that mirrors the live BaaS stack — Postgres + GoTrue +
PostgREST + an nginx edge, plus a TEI embedder and the AI indexer behind the `rag` profile. The AI tables
live in the *same* database as `osionos_pages` (per `models/osionos-ai-migration.sql:2-3`), so the AI modules
can be exercised against the full schema, seeded with demo users, without touching the live public BaaS.

Same image TAGS as live, same migration sources (grobase's own `scripts/migrations/postgresql/*.sql` and this
repo's `models/*.sql`), same roles and the same RLS shape.

---

## The scripts

| script | what it does |
|---|---|
| `gen-secrets.sh` | writes `infrastructure/eval/.env` (mode 600): the postgres and authenticator passwords, the JWT secret, and the anon / service_role keys. Refuses to overwrite an existing `.env`; `FORCE=1` overwrites it. Prints the variable NAMES it wrote, never a value. |
| `migrate.sh` | the ONE way to migrate the eval database: grobase's `db-bootstrap.psql`, then GoTrue healthy, then grobase's migrations, then this repo's models migrations. Fails on the first broken step. Idempotent. |
| `seed-users.sh [N]` | creates N demo users (default 12) through the edge. Their passwords land in `infrastructure/eval/.users` (mode 600, gitignored) and are never printed. Idempotent. |
| `smoke.sh [--allow-skip]` | the gate: eleven checks, PASS/FAIL per line, exit 1 when a check fails. |
| `pg-init.sh` | run ONCE by the postgres image, on a fresh data directory: creates the `auth` schema and sets the postgres role's `search_path` to `auth, public`. GoTrue's migrator records its versions in an *unqualified* `schema_migrations` table, so without this it would take the name `public.schema_migrations` — and grobase's own `001_initial_schema.sql` could then not create its tracker there. |

Every script is POSIX `sh` and resolves its paths from `$0`, so it works from any checkout.

## Deploy locally (throwaway project, offset ports)

```bash
# The ports must be the SAME in every command below: the scripts talk to
# the edge on EVAL_EDGE_PORT.
export EVAL_EDGE_PORT=38000 EVAL_PG_PORT=35432

# 1. Generate secrets (writes infrastructure/eval/.env, mode 600)
sh infrastructure/eval/gen-secrets.sh

# 2. Bring up the stack
docker compose -p ai-eval-smoke -f infrastructure/eval/compose.yml up -d

# 3. Migrate the eval DB (idempotent)
sh infrastructure/eval/migrate.sh

# 4. Seed the demo users
sh infrastructure/eval/seed-users.sh 12

# 5. Run the gate
sh infrastructure/eval/smoke.sh

# 6. The rag profile (embedder + AI indexer), optional
OSIONOS_AI_IMAGE=track-binocle/osionos-ai:ai-dev \
  docker compose -p ai-eval-smoke -f infrastructure/eval/compose.yml --profile rag up -d
sh infrastructure/eval/smoke.sh --allow-skip
```

`migrate.sh` reads grobase from `${GROBASE_DIR:-$REPO_ROOT/apps/grobase}` (the submodule, read-only). Set
`GROBASE_DIR` when the submodule is not checked out where the script lives.

## Deploy on the data-center VM (the orchestrator path)

```bash
# SSH tunnel (local only — never sets DOCKER_HOST)
ssh -N -L 18000:127.0.0.1:18000 -L 15432:127.0.0.1:15432 b2b

# Then, with the same compose file and .env on the VM:
DOCKER_HOST=ssh://b2b docker compose -f infrastructure/eval/compose.yml \
  --env-file infrastructure/eval/.env up -d

# Then, ON the VM:
sh infrastructure/eval/migrate.sh
sh infrastructure/eval/seed-users.sh 12
sh infrastructure/eval/smoke.sh
```

The scripts only ever use `docker exec` / `docker start` / `docker restart` on `eval-pg`, so they work
unchanged with `DOCKER_HOST` set. The compose project name is `eval` by default and `ai-eval-smoke` for the
local throwaway; `migrate.sh` accepts both and refuses any other.

## Teardown

```bash
docker compose -p ai-eval-smoke -f infrastructure/eval/compose.yml down -v
```

## What the gate checks

1. the edge's `/health` → 200
2. GoTrue's health THROUGH the edge (`GET /auth/v1/health`) → 200
3. the `vector` extension is present
4. `osionos_pages`, `osionos_workspaces`, `ai_chunks`, `ai_index_queue`, `ai_runs` exist
5. PostgREST `GET /rest/v1/osionos_pages?limit=1` with the service key (`apikey` + `Authorization: Bearer`) → 200
6. a JWT signed with a WRONG secret → 401
7. a seeded user's password grant → an `access_token`, and PostgREST accepts it → 200. `osionos_pages`
   itself answers 403 for a user token: that table is service-role-only by design (the bridge is its only
   reader), and the check says so.
8. every PUBLISHED port of the project binds `127.0.0.1` (an exposed port with no host binding is fine)
9. `eval-pg` is on exactly one network, `<project>_eval-net`
10. the migrate guard: `PG_CONTAINER=mini-baas-postgres` or `PG_DB=other` makes `migrate.sh` exit 1 before it
    runs a single docker command
11. (rag profile only) a page inserted through the service role reaches `ai_chunks`

A check that is in scope but cannot run prints `SKIP` and fails the gate unless `--allow-skip` is given. A
check that is out of scope (11 without the rag profile) prints `N/A` and is not counted.

## Caveat

Same image tags as live but not necessarily the same digests; no realtime, no storage/MinIO, no query
router — features needing them answer 503 in eval.

---

## Gates (run locally, on this machine's Docker daemon only)

- `docker compose -f infrastructure/eval/compose.yml config -q` (and with `--profile rag`); `sh -n` +
  shellcheck (`docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:stable -s sh infrastructure/eval/*.sh`)
- The smoke output all PASS
- `migrate.sh` second run succeeds
- `PG_CONTAINER=mini-baas-postgres sh infrastructure/eval/migrate.sh` → exits 1 before any docker command
- Every file ≤ 300 lines
- Never print a secret value (names and set/unset only)
- Commits `fix(eval): …`, no trailers (no Co-Authored-By, no "Generated with"). Do not push.
