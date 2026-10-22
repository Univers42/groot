#!/usr/bin/env sh
# smoke.sh — THE GATE: with the stack up, it asserts and prints PASS/FAIL per
# check. Never prints a secret value (names and set/unset only).
#
#   1. edge /health → 200
#   2. GoTrue health THROUGH THE EDGE (GET /auth/v1/health) → 200
#   3. the vector extension is present
#   4. osionos_pages, osionos_workspaces, ai_chunks, ai_index_queue, ai_runs exist
#   5. PostgREST GET /rest/v1/osionos_pages?limit=1 with the service key
#      (apikey + Authorization: Bearer) → 200
#   6. a JWT signed with a WRONG secret → 401
#   7. a seeded user's password grant → an access_token, and PostgREST with
#      that token → 200
#   8. every published port of the project binds 127.0.0.1
#   9. eval-pg is on exactly one network, <project>_eval-net
#  10. the migrate guard: PG_CONTAINER / PG_DB pointing elsewhere → exit 1
#      before ANY docker command
#  11. (rag profile only) a page inserted through the service role shows up
#      in ai_chunks — smoke-rag.sh, split out by concern
#
# Exit 1 if any check FAILs. A check that is IN SCOPE but cannot run prints
# SKIP and also exits 1, unless --allow-skip is given. A check that is OUT OF
# SCOPE (check 11 without the rag profile) prints N/A and is not counted.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$HERE/.env"
USERS_FILE="$HERE/.users"
readonly PG_CTN=eval-pg

ALLOW_SKIP=0
for arg in "$@"; do
  case "$arg" in
    --allow-skip) ALLOW_SKIP=1 ;;
    *) printf 'usage: smoke.sh [--allow-skip]\n' >&2; exit 2 ;;
  esac
done

[ -f "$ENV_FILE" ] || { printf 'FAIL: no %s — run gen-secrets.sh first\n' "$ENV_FILE"; exit 1; }
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
umask 077

FAILURES=0
SKIPS=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
skip() { printf 'SKIP: %s\n' "$*"; SKIPS=$((SKIPS + 1)); }
note() { printf '[smoke] %s\n' "$*" >&2; }

EDGE_PORT=${EVAL_EDGE_PORT:-18000}
BASE_URL="http://127.0.0.1:${EDGE_PORT}"

# The compose project of the stack under test.
PROJECT=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$PG_CTN" 2>/dev/null || true)
if [ -z "$PROJECT" ]; then
  printf 'FAIL: no %s container — is the stack up?\n' "$PG_CTN"
  exit 1
fi

# A curl config file (mode 600) carries the headers: a secret on curl's
# command line is a secret in the process list.
write_cfg() {
  cfg=$1
  shift
  : > "$cfg"
  for hdr in "$@"; do
    printf 'header = "%s"\n' "$hdr" >> "$cfg"
  done
  chmod 600 "$cfg"
}

# curl_code URL [curl args...] — the extra arguments are PASSED THROUGH.
curl_code() {
  c_url=$1
  shift
  c_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$c_url" "$@" 2>/dev/null) || c_code=''
  [ -n "$c_code" ] || c_code=000
  printf '%s' "$c_code"
}

psql_q() {
  docker exec "$PG_CTN" psql -U postgres -d postgres -tAc "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. edge /health → 200
# ---------------------------------------------------------------------------
code=$(curl_code "$BASE_URL/health")
if [ "$code" = "200" ]; then pass "edge /health → 200"; else fail "edge /health → $code"; fi

# 2. GoTrue health THROUGH THE EDGE → 200
code=$(curl_code "$BASE_URL/auth/v1/health")
if [ "$code" = "200" ]; then pass "GoTrue /auth/v1/health through the edge → 200"; else fail "GoTrue /auth/v1/health through the edge → $code"; fi

# 3. the vector extension is present
result=$(psql_q "SELECT 1 FROM pg_extension WHERE extname='vector'")
if [ "$result" = "1" ]; then pass "vector extension present"; else fail "vector extension not present"; fi

# 4. the required tables exist
missing=""
for tbl in osionos_pages osionos_workspaces ai_chunks ai_index_queue ai_runs; do
  if [ "$(psql_q "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='$tbl'")" != "1" ]; then
    missing="$missing $tbl"
  fi
done
if [ -z "$missing" ]; then
  pass "all required tables exist"
else
  fail "missing tables:$missing"
fi

# 5. PostgREST with the service key (apikey + Authorization: Bearer) → 200
write_cfg "$TMP/svc.cfg" "apikey: ${SERVICE_ROLE_KEY}" "Authorization: Bearer ${SERVICE_ROLE_KEY}"
code=$(curl_code "$BASE_URL/rest/v1/osionos_pages?limit=1" -K "$TMP/svc.cfg")
if [ "$code" = "200" ]; then
  pass "PostgREST with the service key → 200"
else
  fail "PostgREST with the service key → $code"
fi

# 6. a JWT signed with a WRONG secret → 401
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
sign_jwt() {
  s_secret=$1
  s_role=$2
  s_iat=$(date +%s)
  s_exp=$((s_iat + 315360000))
  s_h=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
  s_p=$(printf '{"role":"%s","iss":"eval","iat":%s,"exp":%s}' "$s_role" "$s_iat" "$s_exp" | b64url)
  s_sig=$(printf '%s' "$s_h.$s_p" | openssl dgst -sha256 -mac HMAC -macopt "key:$s_secret" -binary | b64url)
  printf '%s.%s.%s' "$s_h" "$s_p" "$s_sig"
}
BAD_TOKEN=$(sign_jwt "$(openssl rand -hex 32)" anon)
write_cfg "$TMP/bad.cfg" "apikey: ${BAD_TOKEN}" "Authorization: Bearer ${BAD_TOKEN}"
code=$(curl_code "$BASE_URL/rest/v1/osionos_pages?limit=1" -K "$TMP/bad.cfg")
if [ "$code" = "401" ]; then
  pass "a JWT signed with a wrong secret → 401"
else
  fail "a JWT signed with a wrong secret → $code (expected 401)"
fi

# 7. a seeded user's password grant → an access_token → PostgREST → 200
if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
  first_line=$(head -1 "$USERS_FILE")
  user_email=${first_line%%:*}
  user_password=${first_line#*:}
  write_cfg "$TMP/anon.cfg" "apikey: ${ANON_KEY}" "Content-Type: application/json"
  printf '{"email":"%s","password":"%s"}' "$user_email" "$user_password" > "$TMP/token_body.json"
  chmod 600 "$TMP/token_body.json"
  token_code=$(curl -sS --max-time 20 -o "$TMP/token.json" -w '%{http_code}' \
    -X POST -K "$TMP/anon.cfg" --data-binary "@$TMP/token_body.json" \
    "$BASE_URL/auth/v1/token?grant_type=password" 2>/dev/null) || token_code=000
  access_token=$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP/token.json")
  if [ "$token_code" != "200" ] || [ -z "$access_token" ]; then
    fail "the password grant did not return an access_token (HTTP $token_code)"
  else
    write_cfg "$TMP/user.cfg" "apikey: ${access_token}" "Authorization: Bearer ${access_token}"
    # PostgREST must ACCEPT the user's token: same JWT secret, same role.
    code=$(curl_code "$BASE_URL/rest/v1/posts?limit=1" -K "$TMP/user.cfg")
    if [ "$code" != "200" ]; then
      fail "the user's token was refused by PostgREST (HTTP $code)"
    else
      # osionos_pages is service-role-only BY DESIGN — the bridge is its only
      # reader (models/osionos-service-role-only-migration.sql revokes it
      # from anon and authenticated), so a user token answers 403 there.
      # What must NOT happen is 401: that would mean PostgREST rejected the
      # token itself.
      page_code=$(curl_code "$BASE_URL/rest/v1/osionos_pages?limit=1" -K "$TMP/user.cfg")
      if [ "$page_code" = "401" ]; then
        fail "the user's token was rejected by PostgREST (401)"
      else
        pass "user password grant → access_token → PostgREST → 200 (osionos_pages answers $page_code: service-role-only by design)"
      fi
    fi
  fi
else
  skip "no .users file — run seed-users.sh first"
fi

# ---------------------------------------------------------------------------
# 8. every published port of the project binds 127.0.0.1
# ---------------------------------------------------------------------------
docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Ports}}' > "$TMP/ports" 2>/dev/null || true
ports_ok=1
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    *'->'*)
      # A PUBLISHED mapping ("127.0.0.1:38000->80/tcp"): it must bind the
      # loopback only.
      case "$line" in
        127.0.0.1:*) : ;;
        *) ports_ok=0; note "published outside 127.0.0.1: $line" ;;
      esac
      ;;
    *)
      # An EXPOSED port with no host binding ("3000/tcp"): reachable only
      # from inside the project network. Nothing is published.
      : ;;
  esac
done < "$TMP/ports"
if [ "$ports_ok" -eq 1 ]; then
  pass "every published port binds 127.0.0.1"
else
  fail "a published port binds something other than 127.0.0.1"
fi

# ---------------------------------------------------------------------------
# 9. eval-pg is on exactly ONE network: <project>_eval-net
# ---------------------------------------------------------------------------
expected_net="${PROJECT}_eval-net"
nets=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$PG_CTN" 2>/dev/null || true)
net_count=$(printf '%s\n' "$nets" | grep -c . || true)
net_names=$(printf '%s' "$nets" | tr -d '[:space:]')
if [ "$net_count" = "1" ] && [ "$net_names" = "$expected_net" ]; then
  pass "$PG_CTN is on exactly one network: $expected_net"
else
  fail "$PG_CTN networks: [$net_names] (expected exactly one: $expected_net)"
fi

# ---------------------------------------------------------------------------
# 10. the migrate guard — the container name is a constant.
#     A docker shim first on PATH records every call; the guard must exit 1
#     BEFORE any docker command, so the record stays EMPTY.
# ---------------------------------------------------------------------------
SHIM_DIR="$TMP/shim"
mkdir -p "$SHIM_DIR"
SHIM_LOG="$TMP/docker-calls.log"
: > "$SHIM_LOG"
cat > "$SHIM_DIR/docker" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_SHIM_LOG"
exit 0
SHIM
chmod +x "$SHIM_DIR/docker"
guard_ok=1
for bad_var in "PG_CONTAINER=mini-baas-postgres" "PG_DB=other"; do
  : > "$SHIM_LOG"
  rc=0
  # shellcheck disable=SC2086
  out=$(PATH="$SHIM_DIR:$PATH" DOCKER_SHIM_LOG="$SHIM_LOG" env "$bad_var" sh "$HERE/migrate.sh" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ]; then
    guard_ok=0
    note "migrate.sh with $bad_var exited $rc (expected 1): $out"
  fi
  if [ -s "$SHIM_LOG" ]; then
    guard_ok=0
    note "migrate.sh with $bad_var ran a docker command: $(head -1 "$SHIM_LOG")"
  fi
done
if [ "$guard_ok" -eq 1 ]; then
  pass "migrate.sh refuses a foreign PG_CONTAINER/PG_DB before any docker command"
else
  fail "the migrate guard does not hold"
fi

# ---------------------------------------------------------------------------
# 11. (rag profile only) a page inserted through the service role reaches
#     ai_chunks. Split out by concern — it is the only check that needs the
#     rag profile, and the only one that waits.
# ---------------------------------------------------------------------------
rag_status=0
sh "$HERE/smoke-rag.sh" || rag_status=$?
case "$rag_status" in
  0 | 3) : ;;                        # PASS, or out of scope
  1) FAILURES=$((FAILURES + 1)) ;;   # FAIL (it printed its own line)
  2) SKIPS=$((SKIPS + 1)) ;;         # SKIP (it printed its own line)
  *) FAILURES=$((FAILURES + 1)) ;;
esac

# ---------------------------------------------------------------------------
# the verdict
# ---------------------------------------------------------------------------
if [ "$SKIPS" -gt 0 ] && [ "$ALLOW_SKIP" -eq 0 ]; then
  printf 'FAIL: %s check(s) could not run — re-run with --allow-skip to accept them\n' "$SKIPS"
  FAILURES=$((FAILURES + SKIPS))
fi
if [ "$FAILURES" -gt 0 ]; then
  printf 'smoke.sh: %s failure(s), %s skip(s)\n' "$FAILURES" "$SKIPS"
  exit 1
fi
printf 'smoke.sh: all checks PASS (%s skipped)\n' "$SKIPS"
exit 0
