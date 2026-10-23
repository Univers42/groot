#!/usr/bin/env bash
# vm-bootstrap.sh — the privileged half of the Arlet demo seed (ADR 0005, devil verdict
# docs/redesign/verdicts/phase2-baas-submission.md). It runs INSIDE the baas VM, from the bundle
# seed-baas.sh ships over ssh, and only ever ADDS:
#   two databases demo_<uid8>_crm (postgres) and demo_<uid8>_activity (mongo), each with a login
#   limited to itself · their mounts in the bridge's tenant · the two @arlet.example.com users ·
#   two workspaces, their three member rows and the two mount links.
# Nothing existing is changed or dropped: the only UPDATE/ALTER is resetting the password of a
# demo login whose mount is not registered yet (marked `resume-password`, condition 1).
#
#   bash vm-bootstrap.sh <bundle-dir>      # stdout: the state file (ids only)
#
# The bundle holds params.env (names and ids, no secrets), secrets.env (the two user passwords,
# mode 600), crm.schema.sql, the data file, the activity JSONL and the two mongosh scripts.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/demo/vm/lib.sh
. "$HERE/lib.sh"

BUNDLE="${1:?usage: vm-bootstrap.sh <bundle-dir>}"
# shellcheck source=/dev/null
. "$BUNDLE/params.env"
CRM="demo_${UID8}_crm"
ACT="demo_${UID8}_activity"
STATE_DIR="${DEMO_STATE_DIR:-$HOME/.arlet-demo}"
STATE_FILE="$STATE_DIR/$UID8.state"
SECRET_FILE="$STATE_DIR/$UID8.secrets"
DEMO_NAME_RE='^demo_[0-9a-f]{8}_(crm|activity)$'
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

check_inputs() {
  [[ "$UID8" =~ ^[0-9a-f]{8}$ ]] || die "uid8 '$UID8' is not 8 hex digits"
  [[ "$CRM" =~ $DEMO_NAME_RE && "$ACT" =~ $DEMO_NAME_RE ]] || die "demo names do not match $DEMO_NAME_RE"
  local id
  for id in "$WS_OPS_ID" "$WS_FIN_ID"; do [[ "$id" =~ $UUID_RE ]] || die "workspace id '$id' is not a uuid"; done
  [[ "$INES_EMAIL" == *@arlet.example.com && "$JULES_EMAIL" == *@arlet.example.com ]] ||
    die "demo users must be @arlet.example.com"
  [[ "$TENANT" =~ ^[a-z0-9-]{1,64}$ ]] || die "tenant '$TENANT' is not a slug"
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
}

# mount_id NAME — the id of this tenant's mount NAME, or empty.
mount_id() {
  local code
  code="$(kong_call GET /admin/v1/databases "$ADMIN_CFG")"
  [ "$code" = 200 ] || die "listing the tenant's mounts answered HTTP $code"
  jq -r --arg n "$1" '.[] | select(.name == $n) | .id' "$WORK/resp" | head -1
}

# check_ownership — refuse a uid8 whose objects exist without our state file (someone else's),
# and a tenant that holds no osionos mount (wrong tenant: a mount there would be orphaned).
check_ownership() {
  local prefix="${DEMO_TENANT_MOUNT_PREFIX:-osionos}" existing
  ADMIN_CFG="$(curl_config admin "apikey: $(kong_env KONG_SERVICE_API_KEY)" "X-Tenant-Id: $TENANT" "Content-Type: application/json")"
  [ "$(kong_call GET /admin/v1/databases "$ADMIN_CFG")" = 200 ] || die "cannot list mounts of tenant $TENANT"
  jq -e --arg p "$prefix" 'any(.[]; .name | startswith($p))' "$WORK/resp" >/dev/null ||
    die "tenant '$TENANT' holds no '$prefix*' mount: not the bridge's tenant"
  [ -f "$STATE_FILE" ] && return 0
  existing="$(printf "select (select count(*) from pg_database where datname = %s) + (select count(*) from pg_roles where rolname = %s);\n" \
    "$(sql_literal "$CRM")" "$(sql_literal "$CRM")" | pg_super -d postgres)"
  [ "$existing" = 0 ] || die "$CRM exists on this host but $STATE_FILE does not: not ours"
  [ -z "$(mount_id "$CRM")$(mount_id "$ACT")" ] || die "a $UID8 mount exists but $STATE_FILE does not: not ours"
  state_put uid8 "$UID8"
}

# demo_password NAME — the login password of demo login NAME, kept in the VM-only secrets file.
# Generated when absent; a login that exists without a stored password may be reset only while
# its mount is unregistered, since a registered mount's DSN would then be stale.
demo_password() {
  local name="$1" pw=""
  if [ -f "$SECRET_FILE" ]; then pw="$(sed -n "s/^$name=//p" "$SECRET_FILE" | tail -1)"; fi
  if [ -z "$pw" ]; then
    [ -z "$(mount_id "$name")" ] || die "$name is registered but its password is lost; not touching it"
    pw="$(openssl rand -hex 24)"
    (umask 077 && printf '%s=%s\n' "$name" "$pw" >>"$SECRET_FILE")
  fi
  printf '%s' "$pw"
}

# is_stored NAME — whether NAME's password is already in the VM-only secrets file.
is_stored() { [ -f "$SECRET_FILE" ] && grep -q "^$1=" "$SECRET_FILE"; }

# Caveat: the password reaches the server as SQL text, so a postgres with log_statement=ddl or
# all writes it to its log. A SCRAM verifier computed here would close that.
bootstrap_postgres() {
  write_window_wait
  local pw reset=false
  is_stored "$CRM" || reset=true
  pw="$(demo_password "$CRM")"
  pg_super -d postgres <<SQL
SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION PASSWORD %L', '$CRM', $(sql_literal "$pw"))
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$CRM')\gexec
SELECT format('ALTER ROLE %I PASSWORD %L', '$CRM', $(sql_literal "$pw")) -- resume-password
WHERE $reset AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$CRM')\gexec
SELECT 'CREATE DATABASE $CRM OWNER $CRM' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$CRM')\gexec
REVOKE CONNECT, TEMPORARY ON DATABASE $CRM FROM PUBLIC;
GRANT CONNECT ON DATABASE $CRM TO $CRM;
SQL
  state_put pg_database "$CRM"
}

# check_platform_unreadable — G2 on the real target (condition 12), before the DSN is registered:
# the demo login must fail to read auth.users from the platform database, at connect or at the
# table. The fixture proves the check; only this run proves baas's own grants.
check_platform_unreadable() {
  local out
  if out="$(echo 'select count(*) from auth.users;' | PGPASSWORD="$PG_PW" docker exec -i -e PGPASSWORD \
    "$PG_CONTAINER" psql -X -q -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$CRM" -d postgres 2>&1)"; then
    die "$CRM can read auth.users on the platform database; not registering its DSN"
  fi
  say "G2: $CRM cannot read auth.users (${out%%$'\n'*})"
}

# load_sql FILE — applies FILE as the demo login in one transaction, after checking its
# fingerprint: an applied file whose bytes changed is refused (condition 5).
load_sql() {
  local file="$1" name sha applied
  name="$(basename "$file")"
  sha="$(sha256sum "$file" | cut -d' ' -f1)"
  applied="$(echo "select sha256 from demo_schema where file = $(sql_literal "$name");" |
    DEMO_PG_PASSWORD="$PG_PW" pg_as_demo "$CRM" 2>/dev/null || true)"
  [ -z "$applied" ] || [ "$applied" = "$sha" ] || die "$name changed since it was applied; ship changes as a new file"
  {
    cat "$file"
    printf "\nINSERT INTO demo_schema (file, sha256) VALUES (%s, %s) ON CONFLICT (file) DO NOTHING;\n" \
      "$(sql_literal "$name")" "$(sql_literal "$sha")"
  } | DEMO_PG_PASSWORD="$PG_PW" pg_as_demo "$CRM"
  say "applied $name as $CRM"
}

load_postgres() {
  write_window_wait
  PG_PW="$(demo_password "$CRM")"
  load_sql "$BUNDLE/crm.schema.sql"
  write_window_wait
  load_sql "$BUNDLE/$DATA_FILE"
}

bootstrap_mongo() {
  write_window_wait
  local dir="/tmp/arlet-$UID8" jsonl_files
  read -ra jsonl_files <<<"$ACT_FILES"
  DEMO_MONGO_RESET=false
  is_stored "$ACT" || DEMO_MONGO_RESET=true
  DEMO_MONGO_PASSWORD="$(demo_password "$ACT")"
  DEMO_MONGO_USER="$ACT" DEMO_MONGO_DB="$ACT" DEMO_MONGO_DIR="$dir"
  export DEMO_MONGO_USER DEMO_MONGO_PASSWORD DEMO_MONGO_DB DEMO_MONGO_DIR DEMO_MONGO_RESET
  docker exec "$MONGO_CONTAINER" mkdir -p "$dir"
  tar -C "$BUNDLE" -cf - mongo-user.js mongo-load.js "${jsonl_files[@]}" | docker exec -i "$MONGO_CONTAINER" tar -C "$dir" -xf -
  mongo_js "$dir/mongo-user.js"
  write_window_wait
  mongo_js "$dir/mongo-load.js"
  docker exec "$MONGO_CONTAINER" sh -c 'rm -f "$1"/*.jsonl "$1"/*.js && rmdir "$1"' sh "$dir"
  state_put mongo_database "$ACT"
}

# register_mount ENGINE NAME DSN-URL — registers once; an existing mount is reused unchanged.
register_mount() {
  local engine="$1" name="$2" id code
  id="$(mount_id "$name")"
  if [ -z "$id" ]; then
    code="$(jq -n --arg e "$engine" --arg n "$name" --arg d "$3" '{engine:$e,name:$n,connection_string:$d}' |
      kong_call POST /admin/v1/databases "$ADMIN_CFG" body)"
    case "$code" in
    201) id="$(jq -r .id "$WORK/resp")" ;;
    409) id="$(mount_id "$name")" ;;
    *) die "registering $name answered HTTP $code: $(jq -r '.error // .message // empty' "$WORK/resp" 2>/dev/null)" ;;
    esac
  fi
  [[ "$id" =~ $UUID_RE ]] || die "no mount id for $name"
  state_put "mount_$name" "$id"
  printf '%s' "$id"
}

register_mounts() {
  write_window_wait
  local crm_pw act_pw
  crm_pw="$(demo_password "$CRM")"
  act_pw="$(demo_password "$ACT")"
  CRM_MOUNT="$(register_mount postgresql "$CRM" "postgres://$CRM:$crm_pw@postgres:5432/$CRM")"
  ACT_MOUNT="$(register_mount mongodb "$ACT" "mongodb://$ACT:$act_pw@mongo:27017/$ACT?authSource=$ACT")"
}

# demo_user EMAIL NAME PASSWORD — the GoTrue id of EMAIL, created confirmed when absent. An
# existing account is used as it is.
demo_user() {
  local id code
  id="$(echo "select id from auth.users where lower(email) = lower($(sql_literal "$1"));" | pg_super -d postgres)"
  if [ -z "$id" ]; then
    code="$(jq -n --arg e "$1" --arg n "$2" --arg p "$3" \
      '{email:$e,password:$p,email_confirm:true,user_metadata:{full_name:$n}}' |
      kong_call POST /auth/v1/admin/users "$AUTH_CFG" body)"
    case "$code" in 200 | 201) id="$(jq -r .id "$WORK/resp")" ;; *) die "GoTrue did not create $1 (HTTP $code)" ;; esac
  fi
  [[ "$id" =~ $UUID_RE ]] || die "no user id for $1"
  printf '%s' "$id"
}

create_users() {
  write_window_wait
  # shellcheck source=/dev/null
  . "$BUNDLE/secrets.env"
  AUTH_CFG="$(curl_config auth "apikey: $(kong_env KONG_PUBLIC_API_KEY)" \
    "Authorization: Bearer $(kong_env KONG_SERVICE_API_KEY)" "Content-Type: application/json")"
  INES_ID="$(demo_user "$INES_EMAIL" "$INES_NAME" "$INES_PASSWORD")"
  state_put ines_id "$INES_ID"
  JULES_ID="$(demo_user "$JULES_EMAIL" "$JULES_NAME" "$JULES_PASSWORD")"
  state_put jules_id "$JULES_ID"
}

create_workspaces() {
  write_window_wait
  local table owner="'{create,read,update,delete,admin}'"
  for table in osionos_workspaces osionos_workspace_members osionos_workspace_databases; do
    [ "$(echo "select to_regclass('public.$table') is not null;" | pg_super -d postgres)" = t ] || die "public.$table is missing"
  done
  pg_super -d postgres <<SQL
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug, source) VALUES
  ('$WS_OPS_ID', '$INES_ID', $(sql_literal "$WS_OPS_NAME"), $(sql_literal "$WS_OPS_SLUG"), 'bridge'),
  ('$WS_FIN_ID', '$INES_ID', $(sql_literal "$WS_FIN_NAME"), $(sql_literal "$WS_FIN_SLUG"), 'bridge')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES
  ('$WS_OPS_ID', '$INES_ID', 'owner', $owner),
  ('$WS_FIN_ID', '$INES_ID', 'owner', $owner),
  ('$WS_FIN_ID', '$JULES_ID', 'viewer', '{read}')
ON CONFLICT (workspace_id, user_id) DO NOTHING;
INSERT INTO public.osionos_workspace_databases (workspace_id, db_id, engine, tables, label) VALUES
  ('$WS_OPS_ID', '$CRM_MOUNT', 'postgresql', string_to_array($(sql_literal "$CRM_TABLES"), ','), 'Arlet CRM and trade'),
  ('$WS_OPS_ID', '$ACT_MOUNT', 'mongodb', string_to_array($(sql_literal "$ACT_COLLECTIONS"), ','), 'Arlet activity and library')
ON CONFLICT (workspace_id, db_id) DO NOTHING;
SQL
  state_put workspace_operations "$WS_OPS_ID"
  state_put workspace_finance "$WS_FIN_ID"
}

# Every row present before the run must still be there after it (condition 8). The seed only
# inserts, so the "after" side may hold more; nothing may be missing.
EXISTING_ROWS_SQL="
select 'u:' || id from auth.users
union all select 't:' || id from public.tenants
union all select 'd:' || id from public.tenant_databases
union all select 'w:' || id from public.osionos_workspaces
union all select 'm:' || workspace_id || '/' || user_id from public.osionos_workspace_members
union all select 'p:' || id from public.osionos_pages;"

snapshot() { echo "$EXISTING_ROWS_SQL" | pg_super -d postgres | sort >"$WORK/$1"; }

check_invariance() {
  local missing
  snapshot after
  missing="$(comm -23 "$WORK/before" "$WORK/after" | wc -l)"
  [ "$missing" = 0 ] || die "$missing rows present before the run are gone: $(comm -23 "$WORK/before" "$WORK/after" | cut -c1-2 | sort | uniq -c | tr '\n' ' ')"
  local demo
  demo="$(
    pg_super -d postgres <<SQL
select (select count(*) from auth.users where id in ('$INES_ID','$JULES_ID'))
  || ' ' || (select count(*) from public.tenant_databases where id in ('$CRM_MOUNT','$ACT_MOUNT'))
  || ' ' || (select count(*) from public.osionos_workspaces where id in ('$WS_OPS_ID','$WS_FIN_ID'))
  || ' ' || (select count(*) from public.osionos_workspace_members where workspace_id in ('$WS_OPS_ID','$WS_FIN_ID'))
  || ' ' || (select count(*) from public.osionos_workspace_databases where workspace_id = '$WS_OPS_ID' and db_id in ('$CRM_MOUNT','$ACT_MOUNT'));
SQL
  )"
  [ "$demo" = "2 2 2 3 2" ] || die "demo rows are not exactly 2 users, 2 mounts, 2 workspaces, 3 members, 2 links: $demo"
  say "invariance: all $(wc -l <"$WORK/before") rows present before are kept; demo rows exact"
}

main() {
  check_inputs
  check_ownership
  snapshot before
  bootstrap_postgres
  load_postgres
  check_platform_unreadable
  bootstrap_mongo
  register_mounts
  create_users
  create_workspaces
  check_invariance
  cat "$STATE_FILE"
}

main
