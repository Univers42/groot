#!/usr/bin/env bash
# pg-roundtrip.sh: applies the generated CRM files to a throwaway postgres:16-alpine the way the
# loader will (devil condition 4: `psql -1 -v ON_ERROR_STOP=1`, as a non-superuser role that owns
# its database) and proves:
#   - schema ×2 and data ×2 run without an error or a warning;
#   - row counts equal stats.json, and every report view reconciles with its stats.json KPI;
#   - the per-table checksum is identical after the second data run;
#   - an edit made in the app survives a data re-run (ON CONFLICT DO NOTHING, condition 11);
#   - spike then full gives the same rows as full alone (a later full run only adds).
# The container has no published port, a random name, and is removed on exit; the generated
# files live in a temp dir under the repo (tools.sh mounts only the repo) and are removed too.
#
#   bash scripts/demo/tests/pg-roundtrip.sh
#
# Caveat: proves the SQL against stock PostgreSQL 16, not against grobase's /admin/v1/migrate
# path or the mount role's real grants; those are the seed's verify step (PLAN §5.4).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ANCHOR=2026-10-15
SEED=42
UID8=0a1b2c3d
DB="demo_${UID8}_crm"
IMAGE=postgres:16-alpine

out="$(mktemp -d "$REPO/scripts/demo/tests/.roundtrip.XXXXXX")"
name="demo-pg-roundtrip-$$-$RANDOM"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$out"
}
trap cleanup EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: got [$2] want [$3]"; fi; }

# The NOTICE that IF NOT EXISTS prints is not an error; anything at WARNING or above is.
sql_as() {
  local role="$1" db="$2"
  shift 2
  docker exec -e PGOPTIONS='-c client_min_messages=warning' "$name" \
    psql -h 127.0.0.1 -U "$role" -d "$db" -X -q -At -v ON_ERROR_STOP=1 "$@"
}
apply() {
  local db="$1" file="$2" errors
  errors="$(docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$name" \
    psql -h 127.0.0.1 -U demo_owner -d "$db" -X -q -1 -v ON_ERROR_STOP=1 -f - <"$file" 2>&1 >/dev/null)" ||
    {
      fail "apply $(basename "$file") to $db: $errors"
      return 1
    }
  if [[ -n "$errors" ]]; then fail "apply $(basename "$file") to $db printed: $errors"; else pass "apply $(basename "$file") to $db"; fi
}
checksums() {
  local db="$1" query
  query="$(sql_as demo_owner "$db" -c "SELECT string_agg(format('SELECT %L, md5(coalesce(string_agg(t::text, E''\\n'' ORDER BY t.id), '''')) FROM %I t', table_name, table_name), ' UNION ALL ' ORDER BY table_name) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' AND table_name <> 'demo_schema'")"
  sql_as demo_owner "$db" -c "$query"
}

"$REPO/scripts/tools.sh" node "$REPO/scripts/demo/generate.mjs" --anchor "$ANCHOR" --seed "$SEED" --uid8 "$UID8" --out "$out/full" </dev/null
"$REPO/scripts/tools.sh" node "$REPO/scripts/demo/generate.mjs" --anchor "$ANCHOR" --seed "$SEED" --uid8 "$UID8" --out "$out/spike" --spike </dev/null
stats="$out/full/stats.json"

docker run -d --rm --name "$name" -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null
# The image's init server listens on the socket only, so a TCP answer means the real server is up.
for _ in $(seq 1 60); do
  if docker exec "$name" pg_isready -q -h 127.0.0.1 -U postgres 2>/dev/null; then break; fi
  sleep 1
done
docker exec "$name" pg_isready -q -h 127.0.0.1 -U postgres || {
  echo "postgres did not come up" >&2
  exit 1
}
sql_as postgres postgres -c "CREATE ROLE demo_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE"
sql_as postgres postgres -c "CREATE DATABASE $DB OWNER demo_owner"
sql_as postgres postgres -c "CREATE DATABASE ${DB}_spike OWNER demo_owner"
check "demo_owner is not a superuser" "$(sql_as demo_owner "$DB" -c 'SELECT rolsuper FROM pg_roles WHERE rolname = current_user')" "f"

apply "$DB" "$out/full/crm.schema.sql"
apply "$DB" "$out/full/crm.schema.sql"
apply "$DB" "$out/full/crm.data.sql"
first="$(checksums "$DB")"
apply "$DB" "$out/full/crm.data.sql"
second="$(checksums "$DB")"
check "checksums cover all 11 tables" "$(grep -c . <<<"$first")" "11"
check "checksums identical after the second data run" "$second" "$first"

while IFS=$'\t' read -r table want; do
  check "rows in $table" "$(sql_as demo_owner "$DB" -c "SELECT count(*) FROM $table")" "$want"
done < <(jq -r '.counts | to_entries[] | select(.key | test("^(companies|contacts|company_contacts|deals|deal_contacts|trade_.*)$")) | [.key, .value] | @tsv' "$stats")
check "demo_schema exists and is left to the loader" "$(sql_as demo_owner "$DB" -c 'SELECT count(*) FROM demo_schema')" "0"

while IFS=$'\t' read -r check_name query want; do
  check "view reconciles: $check_name" "$(sql_as demo_owner "$DB" -c "$query")" "$want"
done < <(jq -r '.reconcile[] | [.name, .sql, .expected] | @tsv' "$stats")

sql_as demo_owner "$DB" -c "UPDATE companies SET city = 'Lyon 2e (edited in the app)' WHERE name = 'Hôtel Varenne'"
apply "$DB" "$out/full/crm.data.sql"
check "an app edit survives a data re-run" \
  "$(sql_as demo_owner "$DB" -c "SELECT city FROM companies WHERE name = 'Hôtel Varenne'")" "Lyon 2e (edited in the app)"

apply "${DB}_spike" "$out/spike/crm.schema.sql"
apply "${DB}_spike" "$out/spike/crm.data.spike.sql"
check "spike loads rows into every table" \
  "$(sql_as demo_owner "${DB}_spike" -c "SELECT count(*) FROM (SELECT 1 FROM companies LIMIT 1) a, (SELECT 1 FROM trade_stock_movements LIMIT 1) b, (SELECT 1 FROM trade_expenses LIMIT 1) c, (SELECT 1 FROM deal_contacts LIMIT 1) d")" "1"
apply "${DB}_spike" "$out/full/crm.data.sql"
check "spike then full equals full alone" "$(checksums "${DB}_spike")" "$first"

if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
echo "pg-roundtrip: all checks passed"
