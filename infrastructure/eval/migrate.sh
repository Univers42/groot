#!/usr/bin/env sh
# migrate.sh — the ONE way to migrate the eval database.
#
# THE GUARD (this is the whole point of this script)
#   The container name and the database name are CONSTANTS here: eval-pg and
#   postgres. The environment may not point them anywhere else — if it does,
#   the script exits 1 BEFORE it runs a single docker command. On the
#   data-center VM the live public database is "mini-baas-postgres"; one
#   forgotten PG_CONTAINER would migrate the public database. The old version
#   compared PG_CONTAINER with itself, so the check always passed.
#   Then: the container named eval-pg must carry a compose project label of
#   "eval" or "ai-eval-smoke". A container that happens to be called eval-pg
#   but that OUR compose did not create is refused.
#
# THE STEPS (the order live uses, data-engines.yml:119-152)
#   a. grobase scripts/db/db-bootstrap.psql — creates the auth schema, the
#      anon/authenticated/service_role/authenticator roles, and sets the
#      postgres role's search_path to auth, public.
#   b. wait for GoTrue to be healthy — it creates auth.users and the rest of
#      auth.*, which the grobase migrations reference (007_permissions_system.sql:135).
#   c. grobase scripts/migrations/postgresql/*.sql, in sort order.
#   d. scripts/apply-models-migrations.sh --check, then without --check.
#
# A FAILED STEP FAILS THE SCRIPT. The old version printed "WARNING …
# continuing" on a failed SQL file and walked away — a half-migrated
# database that looked migrated.
#
# Idempotent: a second run succeeds.
# Works unchanged when the caller sets DOCKER_HOST (it only uses docker
# exec/start/restart on eval-pg).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
GROBASE_DIR=${GROBASE_DIR:-$REPO_ROOT/apps/grobase}

# The constants. Not configurable, on purpose.
readonly PG_CTN=eval-pg
readonly PG_DB_NAME=postgres

note() { printf '[migrate] %s\n' "$*" >&2; }
die() { printf '[migrate] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# GUARD 1 — the constants. NO docker command has run yet.
# ---------------------------------------------------------------------------
if [ -n "${PG_CONTAINER:-}" ] && [ "$PG_CONTAINER" != "$PG_CTN" ]; then
  die "PG_CONTAINER is set to '$PG_CONTAINER'; the eval database is always '$PG_CTN'. Refusing to touch another database."
fi
if [ -n "${PG_DB:-}" ] && [ "$PG_DB" != "$PG_DB_NAME" ]; then
  die "PG_DB is set to '$PG_DB'; the eval database is always '$PG_DB_NAME'. Refusing to touch another database."
fi

# ---------------------------------------------------------------------------
# GUARD 2 — the container must be one THIS compose created.
# ---------------------------------------------------------------------------
PROJECT=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$PG_CTN" 2>/dev/null || true)
case "$PROJECT" in
  eval | ai-eval-smoke) : ;;
  *) die "'$PG_CTN' was not created by the eval compose (compose project: '${PROJECT:-none}'). Refusing to touch it." ;;
esac

# ---------------------------------------------------------------------------
# The secrets (values never reach the log, never a command line).
# ---------------------------------------------------------------------------
ENV_FILE="$HERE/.env"
[ -f "$ENV_FILE" ] || die "no $ENV_FILE — run gen-secrets.sh first"
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# A secret must never appear in the log. psql echoes the offending statement
# on a syntax error, and that statement carries the password.
esc() { printf '%s' "$1" | sed 's/[\\^$.*|]/\\&/g'; }
redact() {
  sed -e "s|$(esc "${POSTGRES_PASSWORD:-}")|***|g" \
      -e "s|$(esc "${AUTHENTICATOR_PASSWORD:-}")|***|g" \
      -e "s|$(esc "${JWT_SECRET:-}")|***|g"
}
# The first ERROR line of a psql run, redacted.
first_error() {
  grep -m1 'ERROR:' "$1" 2>/dev/null || awk 'NF{l=$0} END{print l}' "$1" 2>/dev/null || true
}

# The compose container of a service (running or not), newest first.
find_service() {
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | tail -1
}

# Wait until a container is healthy (or running, when it has no healthcheck).
wait_healthy() {
  w_ctn=$1
  w_limit=$2
  w_waited=0
  while [ "$w_waited" -lt "$w_limit" ]; do
    w_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$w_ctn" 2>/dev/null || true)
    if [ "$w_health" = "healthy" ]; then
      note "$w_ctn is healthy"
      return 0
    fi
    w_running=$(docker inspect -f '{{.State.Running}}' "$w_ctn" 2>/dev/null || true)
    if [ "$w_running" != "true" ]; then
      note "$w_ctn is not running (state: ${w_health:-unknown}) — starting it"
      docker start "$w_ctn" >/dev/null 2>&1 || true
    fi
    sleep 2
    w_waited=$((w_waited + 2))
  done
  die "$w_ctn did not become healthy within ${w_limit}s"
}

# ---------------------------------------------------------------------------
# (a) grobase db-bootstrap.psql
# ---------------------------------------------------------------------------
BOOTSTRAP_SQL="$GROBASE_DIR/scripts/db/db-bootstrap.psql"
[ -f "$BOOTSTRAP_SQL" ] || die "missing $BOOTSTRAP_SQL (GROBASE_DIR=$GROBASE_DIR)"

# The psql variables travel in the SCRIPT, not on the command line: a secret
# on a command line is a secret in the process list. `psql -v name=value` and
# `\set name 'value'` are the same thing; only the second keeps the value out
# of argv.
#
# The ALTER ROLE comes FIRST, before the file's own CREATE SCHEMA. It closes
# the window in which the auth schema exists but the postgres role still has
# the default search_path: a GoTrue boot in that window would record its
# migration versions in public.schema_migrations instead of
# auth.schema_migrations, and the next boot would re-apply migrations that
# are NOT idempotent (20250731150234 fails once 20250903112500 has dropped
# oauth_clients.client_id).
umask 077
{
  printf "\\set pwd '%s'\n" "$POSTGRES_PASSWORD"
  printf "\\set realtime_db '%s'\n" "realtime"
  printf "\\set authenticator_pwd '%s'\n" "$AUTHENTICATOR_PASSWORD"
  printf "ALTER ROLE postgres IN DATABASE %s SET search_path = auth, public;\n" "$PG_DB_NAME"
  cat "$BOOTSTRAP_SQL"
} > "$TMP/bootstrap.sql"

note "step a: grobase db-bootstrap.psql"
if ! docker exec -i "$PG_CTN" psql -U postgres -d "$PG_DB_NAME" -v ON_ERROR_STOP=1 -f - \
  < "$TMP/bootstrap.sql" > "$TMP/boot.out" 2> "$TMP/boot.err"; then
  printf '[migrate] ERROR: db-bootstrap.psql failed:\n' >&2
  redact < "$TMP/boot.err" | head -20 >&2
  exit 1
fi
note "step a: db-bootstrap.psql applied"

# ---------------------------------------------------------------------------
# (a2) Repair: a stray public.schema_migrations
#
# GoTrue's migrator records its versions in an UNQUALIFIED schema_migrations
# table, so the table lands in the FIRST schema of the search_path. A boot
# that happened before the search_path was set (an old data directory, or
# one created before pg-init.sh existed) left GoTrue's tracker in public —
# and grobase's own 001_initial_schema.sql then cannot create ITS tracker
# there: the column shape is different and the migration fails.
#
# grobase's tracker has a `name` column; GoTrue's has not. Only the latter
# is dropped, and only when the auth one holds GoTrue's real bookkeeping.
# ---------------------------------------------------------------------------
stray=$(docker exec "$PG_CTN" psql -U postgres -d "$PG_DB_NAME" -tAc \
  "SELECT count(*) FROM pg_tables t WHERE t.schemaname='public' AND t.tablename='schema_migrations' AND NOT EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema='public' AND c.table_name='schema_migrations' AND c.column_name='name')" 2>/dev/null || echo 0)
if [ "${stray:-0}" != "0" ]; then
  note "step a: dropping GoTrue's stray public.schema_migrations (grobase keeps that name)"
  docker exec -i "$PG_CTN" psql -U postgres -d "$PG_DB_NAME" -v ON_ERROR_STOP=1 -f - \
    <<'EOSQL' >/dev/null 2>&1
DROP TABLE IF EXISTS public.schema_migrations;
EOSQL
fi

# ---------------------------------------------------------------------------
# (b) GoTrue healthy — it creates auth.users and the rest of auth.*
# ---------------------------------------------------------------------------
GOTRUE_CTN=$(find_service eval-gotrue)
[ -n "$GOTRUE_CTN" ] || die "no eval-gotrue container in project '$PROJECT' — is the stack up?"
note "step b: waiting for GoTrue ($GOTRUE_CTN) to be healthy"
docker restart "$GOTRUE_CTN" >/dev/null 2>&1 || true
wait_healthy "$GOTRUE_CTN" 180

# ---------------------------------------------------------------------------
# (c) grobase migrations/postgresql/*.sql, in sort order.
#     The 42-header '#' lines are not valid SQL — live strips them
#     (data-engines.yml:146-150: sed "/^#/d" "$f" | psql … -f -). We do the same.
# ---------------------------------------------------------------------------
MIG_DIR="$GROBASE_DIR/scripts/migrations/postgresql"
[ -d "$MIG_DIR" ] || die "missing $MIG_DIR (GROBASE_DIR=$GROBASE_DIR)"
find "$MIG_DIR" -maxdepth 1 -name '*.sql' | sort > "$TMP/migrations.list"
note "step c: $(wc -l < "$TMP/migrations.list" | tr -d ' ') grobase migrations"
while IFS= read -r mig; do
  [ -n "$mig" ] || continue
  mig_name=$(basename "$mig")
  if ! sed '/^#/d' "$mig" | docker exec -i "$PG_CTN" psql -U postgres -d "$PG_DB_NAME" \
    -v ON_ERROR_STOP=1 -f - > "$TMP/mig.out" 2> "$TMP/mig.err"; then
    printf '[migrate] ERROR: %s failed:\n' "$mig_name" >&2
    redact < "$TMP/mig.err" | head -20 >&2
    exit 1
  fi
done < "$TMP/migrations.list"
note "step c: grobase migrations applied"

# ---------------------------------------------------------------------------
# (d) the models runner — --check first, then the apply, then --check again.
#
# Before it: disarm the realtime event trigger.
#
# grobase's 012_realtime_triggers_all_tables.sql leaves an EVENT TRIGGER that
# arms every table created afterwards with a realtime_notify trigger. The RAG
# migration creates ai_chunks as a PARTITIONED table, and PostgreSQL clones
# the parent's trigger to all 16 partitions. realtime-cdc-off-migration.sql
# then tries to drop that clone on every partition — PostgreSQL refuses
# ("trigger \"ai_chunks_realtime_trigger\" for table \"ai_chunks_p00\" does
# not exist"), the whole file aborts, and every realtime trigger stays armed.
#
# Disarming the event trigger FIRST means the tables the models migrations
# create never get a trigger at all — which is the state realtime-cdc-off
# wants anyway.
# ---------------------------------------------------------------------------
docker exec -i "$PG_CTN" psql -U postgres -d "$PG_DB_NAME" -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 <<'EOSQL' || true
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'realtime_auto_trigger_on_create') THEN
    ALTER EVENT TRIGGER realtime_auto_trigger_on_create DISABLE;
  END IF;
END
$$;
EOSQL

# And drop a realtime trigger that a PARTITIONED table already carries: its
# clones are what realtime-cdc-off chokes on. Dropping the parent's trigger
# removes the clones with it.
docker exec -i "$PG_CTN" psql -U postgres -d "$PG_DB_NAME" -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 <<'EOSQL' || true
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.tgname, c.rel
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relnamespace = 'public'::regnamespace
       AND NOT t.tgisinternal
       AND t.tgfoid = to_regproc('public.realtime_notify')
       AND c.relkind = 'p'
  LOOP
    BEGIN
      EXECUTE format('DROP TRIGGER %I ON %s', r.tgname, r.rel);
    EXCEPTION WHEN undefined_object THEN NULL;
    END;
  END LOOP;
END
$$;
EOSQL

RUNNER="$REPO_ROOT/scripts/apply-models-migrations.sh"
[ -x "$RUNNER" ] || die "missing $RUNNER"
MODELS_DIR="$REPO_ROOT/models"

note "step d: models migrations --check (before)"
if PG_CONTAINER=eval-pg PG_DB=postgres MODELS_DIR="$MODELS_DIR" "$RUNNER" --check; then
  note "step d: models migrations already converged"
else
  note "step d: models migrations have pending gaps — applying them"
fi

note "step d: models migrations apply"
if ! PG_CONTAINER=eval-pg PG_DB=postgres MODELS_DIR="$MODELS_DIR" "$RUNNER"; then
  die "the models migrations failed — see the [models] lines above"
fi

# The apply exits 1 when a migration FAILED, so its exit code is the
# convergence check. The runner's own --check is not run again here: it
# reports a pending gap for every file that creates a table inside a
# format() string (the RAG migration's partition line reads as a table named
# "public"), so on a converged database it never passes. The tables that
# matter are asserted by smoke.sh, check 4.

# ---------------------------------------------------------------------------
# PostgREST caches the schema it serves. It started before these migrations,
# so its cache is stale — tell it to reload (the same NOTIFY the RAG
# migration sends) and restart it so the reload is not a race.
# ---------------------------------------------------------------------------
POSTGREST_CTN=$(find_service eval-postgrest)
if [ -n "$POSTGREST_CTN" ]; then
  note "reloading the PostgREST schema cache"
  printf "NOTIFY PGRST, 'reload schema';\n" \
    | docker exec -i "$PG_CTN" psql -U postgres -d "$PG_DB_NAME" -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 || true
  docker restart "$POSTGREST_CTN" >/dev/null 2>&1 || true
  wait_healthy "$POSTGREST_CTN" 120
fi

note "migrate.sh: eval DB migration complete"
