#!/usr/bin/env bats
# vm-bootstrap.bats — scripts/demo/vm/vm-bootstrap.sh against throwaway engines: a postgres 16
# holding the platform tables (fixture/schema.sql) with a fake Kong beside it, and a mongo 7.
# It proves the devil's phase2 conditions the script can be held to without baas: additive only,
# resumable, refuses what is not its own, loads as the demo logins, no secret on argv.
#
# Run (needs the docker socket; the suite joins its own network to reach the fake Kong):
#   docker run --rm -v "$PWD:$PWD" -w "$PWD" -v "$XDG_RUNTIME_DIR/docker.sock:/docker.sock" \
#     -e DOCKER_HOST=unix:///docker.sock --entrypoint sh bats/bats:1.11.1 -c \
#     'apk add -q --no-cache bash curl jq openssl docker-cli coreutils procps && bats tests/demo-seed'

bats_require_minimum_version 1.5.0

setup_file() {
  export TAG="demo-seed-$$"
  export NET="$TAG-net" PG="$TAG-pg" MONGO="$TAG-mongo"
  docker network create "$NET" >/dev/null
  docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD=fixture-root \
    -e KONG_SERVICE_API_KEY=fixture-service-key -e KONG_PUBLIC_API_KEY=fixture-public-key \
    postgres:16-alpine >/dev/null
  docker run -d --name "$MONGO" --network "$NET" -e MONGO_INITDB_ROOT_USERNAME=root \
    -e MONGO_INITDB_ROOT_PASSWORD=fixture-mongo-root mongo:7 >/dev/null
  docker network connect "$NET" "$(hostname)"
  for _ in $(seq 60); do docker exec "$PG" pg_isready -U postgres -q 2>/dev/null && break; sleep 1; done
  sleep 2
  docker exec -i "$PG" psql -q -U postgres -v ON_ERROR_STOP=1 <tests/demo-seed/fixture/schema.sql
  docker exec "$PG" apk add -q --no-cache nodejs >/dev/null
  docker cp tests/demo-seed/fixture/fake-kong.mjs "$PG:/fake-kong.mjs"
  docker exec -d "$PG" node /fake-kong.mjs
  for _ in $(seq 60); do docker exec "$MONGO" mongosh --quiet --eval 1 >/dev/null 2>&1 && break; sleep 1; done
  for _ in $(seq 30); do curl -s -o /dev/null "http://$PG:8000/" && break; sleep 1; done
}

teardown_file() {
  docker network disconnect "$NET" "$(hostname)" 2>/dev/null || true
  docker rm -f "$PG" "$MONGO" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}

setup() {
  export DEMO_PG_CONTAINER="$PG" DEMO_MONGO_CONTAINER="$MONGO" DEMO_KONG_CONTAINER="$PG"
  export DEMO_KONG_URL="http://$PG:8000" DEMO_IGNORE_WINDOW=1
  export DEMO_STATE_DIR="$BATS_FILE_TMPDIR/state"
}

# bundle UID8 [DATA_SQL] — a seed bundle like seed-baas.sh ships, small enough to read.
bundle() {
  local dir="$BATS_TEST_TMPDIR/bundle-$1" ws_ops ws_fin
  mkdir -p "$dir"
  cp scripts/demo/vm/mongo-user.js scripts/demo/vm/mongo-load.js "$dir/"
  ws_ops="$1-0000-5000-8000-00000000000a"
  ws_fin="$1-0000-5000-8000-00000000000b"
  cat >"$dir/params.env" <<EOF
UID8=$1
TENANT=agency
INES_EMAIL=ines.$1@arlet.example.com
JULES_EMAIL=jules.$1@arlet.example.com
INES_NAME='Inès Caradec'
JULES_NAME='Jules Marchand'
WS_OPS_ID=$ws_ops
WS_OPS_SLUG=arlet-operations-$1
WS_OPS_NAME='Arlet — Operations'
WS_FIN_ID=$ws_fin
WS_FIN_SLUG=arlet-finance-$1
WS_FIN_NAME='Arlet — Finance review'
DATA_FILE=crm.data.sql
CRM_TABLES=companies
ACT_COLLECTIONS=interactions
ACT_FILES=activity.interactions.jsonl
EOF
  (umask 077 && printf 'INES_PASSWORD=ines-secret-%s\nJULES_PASSWORD=jules-secret-%s\n' "$1" "$1" >"$dir/secrets.env")
  cat >"$dir/crm.schema.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS demo_schema (file text PRIMARY KEY, sha256 text NOT NULL);
CREATE TABLE IF NOT EXISTS companies (id uuid PRIMARY KEY, name text NOT NULL);
EOF
  printf '%s\n' "${2:-INSERT INTO companies VALUES ('11111111-1111-5111-8111-111111111111', 'Hôtel Varenne') ON CONFLICT (id) DO NOTHING;}" >"$dir/crm.data.sql"
  printf '{"_id":"a1","kind":"call","duration_s":180}\n{"_id":"a2","kind":"email","subject":"Q4"}\n' >"$dir/activity.interactions.jsonl"
  printf '%s' "$dir"
}

psql_root() { docker exec -i "$PG" psql -X -q -At -U postgres -d postgres; }

@test "a fresh run creates the demo objects and keeps every row that existed" {
  local dir before
  dir="$(bundle aaaaaaaa)"
  before="$(echo "select count(*) from auth.users where email like '%else.test'; select count(*) from osionos_pages; select count(*) from tenant_databases where name = 'osionos-crm';" | psql_root | paste -sd' ')"
  run bash scripts/demo/vm/vm-bootstrap.sh "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mount_demo_aaaaaaaa_crm="* && "$output" == *"workspace_finance="* ]]
  [ "$(echo "select count(*) from auth.users where email like '%else.test'; select count(*) from osionos_pages; select count(*) from tenant_databases where name = 'osionos-crm';" | psql_root | paste -sd' ')" = "$before" ]
  [ "$(echo "select role from osionos_workspace_members where user_id = (select id from auth.users where email = 'jules.aaaaaaaa@arlet.example.com');" | psql_root)" = viewer ]
  [ "$(echo "select count(*) from osionos_workspace_databases where workspace_id = 'aaaaaaaa-0000-5000-8000-00000000000a';" | psql_root)" = 2 ]
}

@test "the mount's DSN logs in as the demo role, which cannot read the platform" {
  local dsn
  dsn="$(echo "select connection_string from tenant_databases where name = 'demo_aaaaaaaa_crm';" | psql_root)"
  [[ "$dsn" == postgres://demo_aaaaaaaa_crm:*@postgres:5432/demo_aaaaaaaa_crm ]]
  [ "$(docker exec "$PG" psql -At "${dsn/@postgres:5432/@127.0.0.1:5432}" -c 'select name from companies')" = "Hôtel Varenne" ]
  run docker exec "$PG" psql -At "${dsn/@postgres:5432/@127.0.0.1:5432}" -c 'select 1 from pg_authid'
  [ "$status" -ne 0 ]
  run docker exec "$PG" psql -At "${dsn/@postgres:5432\/demo_aaaaaaaa_crm/@127.0.0.1:5432/postgres}" -c 'select count(*) from auth.users'
  [ "$status" -ne 0 ]
}

@test "mongo holds the activity as the demo login, which cannot read another database" {
  local dsn
  dsn="$(echo "select connection_string from tenant_databases where name = 'demo_aaaaaaaa_activity';" | psql_root)"
  [ "$(docker exec "$MONGO" mongosh --quiet "${dsn/@mongo:27017/@127.0.0.1:27017}" --eval 'db.interactions.countDocuments()')" = 2 ]
  run docker exec "$MONGO" mongosh --quiet "${dsn/@mongo:27017/@127.0.0.1:27017}" --eval 'db.getSiblingDB("admin").system.users.countDocuments()'
  [ "$status" -ne 0 ]
}

@test "a second run adds nothing and keeps an edit made in between" {
  local dir dsn counts
  dir="$(bundle aaaaaaaa)"
  dsn="$(echo "select connection_string from tenant_databases where name = 'demo_aaaaaaaa_crm';" | psql_root)"
  docker exec "$PG" psql -q "${dsn/@postgres:5432/@127.0.0.1:5432}" -c "update companies set name = 'Hôtel Varenne (edited)'"
  counts="$(echo "select count(*) from auth.users; select count(*) from tenant_databases; select count(*) from osionos_workspaces; select count(*) from osionos_workspace_members;" | psql_root | paste -sd' ')"
  run bash scripts/demo/vm/vm-bootstrap.sh "$dir"
  [ "$status" -eq 0 ]
  [ "$(echo "select count(*) from auth.users; select count(*) from tenant_databases; select count(*) from osionos_workspaces; select count(*) from osionos_workspace_members;" | psql_root | paste -sd' ')" = "$counts" ]
  [ "$(docker exec "$PG" psql -At "${dsn/@postgres:5432/@127.0.0.1:5432}" -c 'select name from companies')" = "Hôtel Varenne (edited)" ]
}

@test "a run that dies after CREATE DATABASE resumes to completion" {
  local dir
  dir="$(bundle bbbbbbbb "INSERT INTO no_such_table VALUES (1);")"
  run bash scripts/demo/vm/vm-bootstrap.sh "$dir"
  [ "$status" -ne 0 ]
  [ "$(echo "select count(*) from pg_database where datname = 'demo_bbbbbbbb_crm';" | psql_root)" = 1 ]
  dir="$(bundle bbbbbbbb)"
  run bash scripts/demo/vm/vm-bootstrap.sh "$dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mount_demo_bbbbbbbb_activity="* ]]
}

@test "a database with our name but no state file is refused before any write" {
  local dir users
  echo "create database demo_cccccccc_crm;" | psql_root
  users="$(echo "select count(*) from auth.users;" | psql_root)"
  dir="$(bundle cccccccc)"
  run bash scripts/demo/vm/vm-bootstrap.sh "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not ours"* ]]
  [ "$(echo "select count(*) from auth.users;" | psql_root)" = "$users" ]
  [ "$(echo "select count(*) from pg_roles where rolname = 'demo_cccccccc_crm';" | psql_root)" = 0 ]
}

@test "a tenant without the bridge's mounts is refused" {
  local dir
  dir="$(bundle dddddddd)"
  sed -i 's/^TENANT=agency/TENANT=other/' "$dir/params.env"
  run bash scripts/demo/vm/vm-bootstrap.sh "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not the bridge's tenant"* ]]
  [ "$(echo "select count(*) from pg_database where datname = 'demo_dddddddd_crm';" | psql_root)" = 0 ]
}

@test "a demo login that can read auth.users is refused before its DSN is registered" {
  local dir
  echo "grant usage on schema auth to public; grant select on auth.users to public;" | psql_root
  dir="$(bundle ffffffff)"
  run bash scripts/demo/vm/vm-bootstrap.sh "$dir"
  echo "revoke select on auth.users from public; revoke usage on schema auth from public;" | psql_root
  [ "$status" -ne 0 ]
  [[ "$output" == *"can read auth.users"* ]]
  [ "$(echo "select count(*) from tenant_databases where name like 'demo_ffffffff_%';" | psql_root)" = 0 ]
}

@test "an applied file whose bytes changed is refused" {
  local dir
  dir="$(bundle aaaaaaaa)"
  echo "-- edited after it was applied" >>"$dir/crm.schema.sql"
  run bash scripts/demo/vm/vm-bootstrap.sh "$dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"crm.schema.sql changed since it was applied"* ]]
}

@test "no secret reaches a command line, and the check sees one that does" {
  local dir shims="$BATS_TEST_TMPDIR/shims" log="$BATS_TEST_TMPDIR/argv.log" real secret leaks
  mkdir -p "$shims"
  for real in docker curl; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec %s "$@"\n' "$log" "$(command -v "$real")" >"$shims/$real"
    chmod +x "$shims/$real"
  done
  dir="$(bundle eeeeeeee)"
  PATH="$shims:$PATH" run bash scripts/demo/vm/vm-bootstrap.sh "$dir"
  [ "$status" -eq 0 ]
  leaks=0
  for secret in ines-secret-eeeeeeee jules-secret-eeeeeeee fixture-service-key fixture-public-key \
    $(cut -d= -f2 "$DEMO_STATE_DIR/eeeeeeee.secrets"); do
    grep -qF -- "$secret" "$log" && leaks=$((leaks + 1))
  done
  [ "$leaks" -eq 0 ]
  PATH="$shims:$PATH" docker exec "$PG" true "planted-$(cut -d= -f2 "$DEMO_STATE_DIR/eeeeeeee.secrets" | head -1)"
  grep -qF -- "$(cut -d= -f2 "$DEMO_STATE_DIR/eeeeeeee.secrets" | head -1)" "$log"
}

# node_run ARGS — the generator and manifest tool, in a node image on the repo's own path.
node_run() { docker run --rm -v "$PWD:$PWD" -w "$PWD" node:22-alpine node "$@"; }

# real_bundle MANIFEST ONLY — what seed-baas.sh ships, built by the real generator and manifest.
real_bundle() {
  local manifest="$1" only="$2" uid8 out flag=()
  uid8="$(jq -r .uid8 "$manifest")"
  out="scripts/demo/out/bats-$uid8/$only"
  [ "$only" = spike ] && flag=(--spike)
  node_run scripts/demo/generate.mjs --anchor 2026-10-16 --uid8 "$uid8" --out "$out" "${flag[@]}" >&2
  cp scripts/demo/vm/lib.sh scripts/demo/vm/vm-bootstrap.sh scripts/demo/vm/mongo-user.js scripts/demo/vm/mongo-load.js "$out/"
  node_run scripts/demo/manifest.mjs params --file "$manifest" --out "$out" --only "$only" >"$out/params.env"
  (umask 077 && printf 'INES_PASSWORD=a\nJULES_PASSWORD=b\n' >"$out/secrets.env")
  printf '%s' "$out"
}

@test "the generated spike, then the full dataset, load as the demo logins and reconcile" {
  local manifest="scripts/demo/out/bats-manifest-$$.json" out uid8 dsn
  node_run scripts/demo/manifest.mjs init --file "$manifest" --target fixture --tenant agency
  uid8="$(jq -r .uid8 "$manifest")"
  out="$(real_bundle "$manifest" spike)"
  run bash scripts/demo/vm/vm-bootstrap.sh "$out"
  [ "$status" -eq 0 ]
  out="$(real_bundle "$manifest" full)"
  run bash scripts/demo/vm/vm-bootstrap.sh "$out"
  [ "$status" -eq 0 ]
  dsn="$(echo "select connection_string from tenant_databases where name = 'demo_${uid8}_crm';" | psql_root)"
  dsn="${dsn/@postgres:5432/@127.0.0.1:5432}"
  [ "$(docker exec "$PG" psql -At "$dsn" -c 'select count(*) from trade_order_lines')" = "$(jq '.counts.trade_order_lines // .tables.trade_order_lines' "$out/stats.json")" ]
  [ "$(docker exec "$PG" psql -At "$dsn" -c 'select count(*) from demo_schema')" = 3 ]
  dsn="$(echo "select connection_string from tenant_databases where name = 'demo_${uid8}_activity';" | psql_root)"
  [ "$(docker exec "$MONGO" mongosh --quiet "${dsn/@mongo:27017/@127.0.0.1:27017}" --eval 'db.library.countDocuments()')" = 250 ]
  rm -rf "scripts/demo/out/bats-$uid8" "$manifest"
}

@test "the deploy-mountlist guard sees the script, not its own code on a command line" {
  . scripts/demo/vm/lib.sh
  run bash -c "$(declare -f deploy_mountlist_running); deploy_mountlist_running && echo seen || echo clear"
  [ "$output" = clear ]
  local planted
  bash -c 'sleep 30; :' deploy-mountlist-baas.sh &
  planted=$!
  sleep 1
  run bash -c '. scripts/demo/vm/lib.sh; deploy_mountlist_running && echo seen || echo clear'
  kill "$planted"
  [ "$output" = seen ]
}

@test "the bootstrap deletes nothing and alters only a demo login's password" {
  run ! grep -nE '\b(DELETE|DROP|TRUNCATE)\b' scripts/demo/vm/vm-bootstrap.sh scripts/demo/vm/lib.sh scripts/demo/vm/mongo-user.js scripts/demo/vm/mongo-load.js
  run grep -nE '\b(UPDATE|ALTER|updateUser)\b' scripts/demo/vm/vm-bootstrap.sh scripts/demo/vm/mongo-user.js
  [ "$status" -eq 0 ]
  run ! grep -vE 'resume-password|^[^:]+:[0-9]+:\s*(#|//)' <<<"$output"
}
