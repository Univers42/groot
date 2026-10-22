#!/bin/sh
# membership-cutoff.sh — prove the osionos_workspace_members -> auth_session_cutoffs
# trigger on a throwaway database. See models/osionos-membership-cutoff-migration.sql.
#
# ISOLATION: throwaway containers only: ai-mc-net, ai-mc-pg, ai-mc-pgrst.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${REPO}/scripts/verify"
MODELS="${REPO}/models"
FIX="${DIR}/models-grants"
NET="ai-mc-net"
PG_CTN="ai-mc-pg"
PGRST_CTN="ai-mc-pgrst"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
PGRST_IMAGE="${PGRST_IMAGE:-postgrest/postgrest:v12.2.3}"
PGRST_PORT="${PGRST_PORT:-33201}"
JWT_SECRET="$(openssl rand -hex 32)"
PV_SUBNET="${PV_SUBNET:-10.123.45.0/24}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/membership-cutoff.XXXXXX")"
# The models the token-trusting routes read, in the runner's order (ORDERED_FIRST
# first, then the alphabetical pass). See apply_fixture.
ROUTE_MODELS="osionos-bridge-migration.sql osionos-chat-migration.sql osionos-social-migration.sql osionos-engagement-migration.sql osionos-page-search-migration.sql osionos-comments-migration.sql osionos-favorites-migration.sql osionos-message-search-migration.sql osionos-object-databases-migration.sql osionos-page-links-migration.sql osionos-reply-migration.sql osionos-share-rules-migration.sql osionos-tasks-migration.sql osionos-workspace-databases-migration.sql"
passed=0; failed=0
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

note() { printf '[membership-cutoff] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s %s\n' "$1" "$2"; }

teardown() {
  [ "${KEEP}" -eq 1 ] && { note "--keep: containers left up"; return 0; }
  docker rm -f "${PGRST_CTN}" >/dev/null 2>&1 || true
  docker rm -f "${PG_CTN}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

psql_q() { docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt; }
q() { printf '%s\n' "$1" | psql_q 2>/dev/null; }
qf() { docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt <"$1"; }
apply() {
  if docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <"$1" >"${WORK}/apply.log" 2>&1; then return 0; fi
  note "psql rejected $(basename "$1")"; sed 's/^/  | /' "${WORK}/apply.log" >&2; return 1
}
must_raise() {
  err="${WORK}/raise.err"
  if printf '%s\n' "$1" | docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt >"${WORK}/raise.out" 2>"${err}"; then return 1; fi
  grep -m1 'ERROR:' "${err}" || head -1 "${err}"
  return 0
}

start_pg() {
  command -v docker >/dev/null 2>&1 || { note "docker is required"; exit 2; }
  docker network create --subnet "${PV_SUBNET}" "${NET}" >/dev/null
  docker run -d --name "${PG_CTN}" --network "${NET}" -e POSTGRES_HOST_AUTH_METHOD=trust "${PG_IMAGE}" >/dev/null
  i=0
  while [ "${i}" -lt 60 ]; do
    docker exec "${PG_CTN}" pg_isready -U postgres -d postgres >/dev/null 2>&1 && return 0
    i=$((i + 1)); sleep 1
  done
  note "postgres never became ready"; exit 1
}

mint_jwt() {
  JWT_SECRET="${JWT_SECRET}" python3 -c '
import base64, hashlib, hmac, json, os, sys, time
role = sys.argv[1]
secret = os.environ["JWT_SECRET"].encode()
def b64(raw): return base64.urlsafe_b64encode(raw).rstrip(b"=")
head = b64(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(",",":")).encode())
now = int(time.time())
pay = b64(json.dumps({"role": role, "iat": now, "exp": now + 3600}, separators=(",",":")).encode())
sig = b64(hmac.new(secret, head + b"." + pay, hashlib.sha256).digest())
print((head + b"." + pay + b"." + sig).decode())
' "$1"
}

start_postgrest() {
  docker run -d --name "${PGRST_CTN}" --network "${NET}" -p "127.0.0.1:${PGRST_PORT}:3000" \
    -e PGRST_DB_URI="postgresql://authenticator@${PG_CTN}:5432/postgres" \
    -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
    -e PGRST_JWT_SECRET="${JWT_SECRET}" -e PGRST_SERVER_PORT=3000 \
    "${PGRST_IMAGE}" >/dev/null
  i=0
  while [ "${i}" -lt 60 ]; do
    curl -sS -o /dev/null "http://127.0.0.1:${PGRST_PORT}/" 2>/dev/null && return 0
    i=$((i + 1)); sleep 1
  done
  note "postgrest never answered"; return 1
}

apply_fixture() {
  apply "${FIX}/roles.sql" || exit 1
  # auth.users stand-in (GoTrue)
  printf 'CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb);\n' | docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q >/dev/null
  apply "${MODELS}/osionos-bridge-migration.sql" || exit 1
  apply "${MODELS}/auth-session-cutoffs.sql" || exit 1
  # The models the token-trusting routes read, in the RUNNER's order: the files of
  # ORDERED_FIRST first (bridge, chat, social, engagement, page-search), then the
  # alphabetical pass (the rest), then ORDERED_LAST. The list is the one the
  # routes need, found by reading what each of them queries:
  #   graph    scripts/bridge-graph.mjs (osionos_pages), scripts/bridge-graph-data.mjs
  #            (osionos_workspace_databases)
  #   search   scripts/bridge-api.mjs:2364 (osionos_pages), the search_doc of the
  #            page-search migration
  #   chat     scripts/bridge-chat.mjs:186 (osionos_channels), the messages of the
  #            chat migration, the receipts of the social one
  #   rtc      scripts/bridge-rtc.mjs:165 (osionos_workspace_members)
  #   IDE mint scripts/bridge-ide-token.mjs (osionos_workspace_members, through the
  #            osionos_bridge_list_workspaces RPC)
  #   and the backlinks route (scripts/bridge-api.mjs:3223) reads osionos_page_links
  #            by workspace_id, the tasks and the share rules have a workspace_id too.
  # The AI's own tables (ai_conversations, ai_chunks, ai_index_queue) are NOT applied:
  # they carry a workspace_id without a foreign key, and the AI service is the G1
  # lane's (C98/C127) -- it is not one of the five surfaces C126 names. The two
  # models this fixture cannot take at all are auth-gateway-users-reconcile-
  # migration.sql and osionos-people-directory-migration.sql: both need the grobase
  # public.users table, which comes from grobase's own init container and not from
  # models/ (measured on this fixture: ERROR: relation "public.users" does not
  # exist). The full set runs later on the eval stack.
  for base in ${ROUTE_MODELS}; do
    apply "${MODELS}/${base}" || { note "the fixture could not apply ${base}"; exit 1; }
  done
  apply "${MODELS}/osionos-membership-cutoff-migration.sql" || exit 1
  apply "${MODELS}/osionos-service-role-only-migration.sql" || exit 1
}

# shellcheck source-path=SCRIPTDIR
. "${DIR}/membership-cutoff/checks-c123.sh"
. "${DIR}/membership-cutoff/checks-c124.sh"
. "${DIR}/membership-cutoff/checks-c125.sh"
. "${DIR}/membership-cutoff/checks-c126.sh"
. "${DIR}/membership-cutoff/checks-c130.sh"
. "${DIR}/membership-cutoff/checks-c131.sh"
. "${DIR}/membership-cutoff/checks-order.sh"

main() {
  start_pg
  note "postgres up"
  apply_fixture
  note "fixture applied"
  start_postgrest
  note "postgrest up"

  for fn in check_c123 check_c124 check_c125 check_c126 check_c130 check_c131 check_order; do
    if $fn; then pass "${fn}" "ok"; else fail "${fn}" "failed"; fi
  done

  printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
  [ "${failed}" -eq 0 ] || exit 1
  exit 0
}

main "$@"
