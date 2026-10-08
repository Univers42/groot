#!/usr/bin/env bash
# account-roundtrip.sh — proof that the frontends persist data through grobase. Against
# the RUNNING stack, through the real TLS edge (local-https-proxy, the local CA, never -k):
# register a fresh account on the site, sign in, bridge into osionos, write a page, read it
# back through the bridge, then read the rows back from grobase's postgres as this machine
# reaches it (grobase-link.sh mode: local -> docker exec, ssh -> ssh + docker exec, direct
# -> Kong only, so the DB step is SKIP and the bridge read-back is the evidence). One
# `ok|FAIL|SKIP <step>  <detail>` line per step, exit 1 on any FAIL. The email is printed
# (the proof's key); the password, tokens and cookies never are, nor are they put in argv.
# It cleans up nothing: the account, workspace and page rows ARE the evidence.
#
# Run: make roundtrip   (or LOCAL_CA_CERT=<ca.pem> bash scripts/verify/account-roundtrip.sh)
# Ponytail: it exercises the HTTP contract, not the UI: a frontend misconfigured for another
# origin passes here and fails in the browser; every run leaves one roundtrip-*@example.test
# account behind and nothing prunes them.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RT_LINK_SH="$REPO/scripts/grobase-link.sh"
# Sourced for ssh_args, state_get (the link state, wherever GROBASE_LINK_DIR puts it),
# EDGE_SERVICE and LINK_CA (LOCAL_CA_CERT, else grobase's CA); it steps aside when sourced.
# shellcheck source=scripts/grobase-link.sh
. "$RT_LINK_SH"
RT_PG=${PG_CONTAINER:-mini-baas-postgres} # as scripts/apply-models*.sh name them
# Ponytail: 10 s to open ssh, 60 s for the whole psql run, 15 s per statement: a loaded VM
# that answers slower reads as FAIL, not as slow (raise RT_SSH_TIMEOUT / RT_DB_TIMEOUT).
RT_SSH_TIMEOUT=${RT_SSH_TIMEOUT:-10}
RT_DB_TIMEOUT=${RT_DB_TIMEOUT:-60}
FAILED=0
RESOLVE=()
PSQL=()

# Every DB check judges itself and prints "step|verdict|detail". psql binds the values (-v,
# :'name' is quoted by psql), so no input is spliced into the SQL text. The identity,
# workspace and membership rows are what osionos_bridge_upsert_workspace writes
# (models/osionos-bridge-migration.sql:373-400): user_id = GoTrue id, role = owner.
RT_SQL=$(cat "$REPO/scripts/verify/account-roundtrip.sql")

# "ok   step  detail": the verdict padded to four columns, as grobase-link verify prints.
rt_line() { printf '%-4s %s  %s\n' "$1" "$2" "$3"; }
report() {
  rt_line "$@"
  [ "$1" != FAIL ] || FAILED=1
}
# A failed HTTP step stops the run: every later step needs what this one produced.
fail() {
  report FAIL "$@"
  exit 1
}

# "<email> <username>" for one run: epoch + pid keep two runs in the same second apart;
# example.test is allowlisted while SMTP is local (auth-gateway.mjs:205-212), and the
# username (9 + 10 + at most 7 digits) fits ^\w[\w.-]{2,31}$ (auth-gateway.mjs:90).
rt_identity() { printf 'roundtrip-%s-%s@example.test roundtrip%s%s\n' "$1" "$2" "$1" "$2"; }
# 20 random alphanumerics plus one char of each class the policy demands
# (auth-gateway.mjs:89), so the password passes without a retry loop.
rt_password() { printf '%s%s\n' "$(head -c 30 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)" 'a7Q!'; }
# The words as one line for the remote login shell, each single-quoted: ssh hands its
# command to that shell, which may be one that aborts on an unmatched glob (zsh-like).
rt_sh_join() {
  local w out=""
  for w in "$@"; do out+="'${w//\'/\'\\\'\'}' "; done
  printf '%s\n' "${out% }"
}
# Sets DB_MODE from the link (`grobase-link.sh mode`; no link = local) and PSQL to the argv
# that runs psql in grobase's postgres; PSQL stays empty for direct, which reaches only Kong.
rt_psql_plan() { # <psql args...>
  local inner=(docker exec -i "$RT_PG" psql -U "${PG_USER:-postgres}" -d "${PG_DB:-postgres}" -X -q -tA -v ON_ERROR_STOP=1 "$@")
  local target sargs
  DB_MODE=$(bash "$RT_LINK_SH" mode 2>/dev/null) || DB_MODE=local
  PSQL=()
  case $DB_MODE in
  local) PSQL=("${inner[@]}") ;;
  ssh)
    target=$(state_get target 2>/dev/null) || return 0
    read -r -a sargs <<<"$(ssh_args "$target")"
    PSQL=(ssh -o BatchMode=yes -o ClearAllForwardings=yes -o LogLevel=ERROR
      -o ConnectTimeout="$RT_SSH_TIMEOUT" "${sargs[@]}" "$(rt_sh_join "${inner[@]}")")
    ;;
  esac
}

# Stores in the variable named $3 the host port of edge container port $1: compose's answer,
# else the compose variable $2, else the container port (docker-compose.yml:19-22). --resolve
# keeps the certificate's name (localhost) whatever address the port is bound to.
# Ponytail: a wildcard bind (0.0.0.0, ::) is reached on 127.0.0.1, wrong if it is firewalled.
edge_port() { # <container port> <compose variable> <result variable>
  local hp addr port
  hp=$(docker compose -f "$REPO/docker-compose.yml" port "$EDGE_SERVICE" "$1" 2>/dev/null | head -n1) || true
  port=${hp##*:}
  addr=${hp%:*}
  [ -n "$port" ] || port=${!2:-$1}
  case $addr in '' | 0.0.0.0 | :: | '[::]') addr=127.0.0.1 ;; esac
  RESOLVE+=(--resolve "localhost:$port:$addr")
  printf -v "$3" '%s' "$port"
}

# One request through the edge: the body lands in $TMP/resp and the HTTP code is printed
# (000 when nothing answered). Bodies and headers come from files, so no token is in argv.
# Ponytail: -m 20 per call; a gateway that waits on an unreachable SMTP server for longer
# reads as FAIL here even though the browser might succeed after a longer wait.
request() { # <method> <url> [body file] [header file]
  local args=(-sS -m 20 --cacert "$LINK_CA" "${RESOLVE[@]}" -b "$TMP/jar" -c "$TMP/jar"
    -o "$TMP/resp" -w '%{http_code}' -X "$1")
  [ -z "${3:-}" ] || args+=(-H 'content-type: application/json' --data-binary "@$3")
  [ -z "${4:-}" ] || args+=(-H "@$4")
  : >"$TMP/resp"
  curl "${args[@]}" "$2" 2>"$TMP/curl.err" || true
}
# The server's own message for a detail line, never the raw body (it can carry tokens).
said() {
  local m
  m=$(jq -r '.message // .error // empty' "$TMP/resp" 2>/dev/null | head -c 160) || true
  printf '%s\n' "${m:-$(head -n1 "$TMP/curl.err" 2>/dev/null)}"
}

step_edge() {
  local code url
  edge_port 4322 OPPOSITE_OSIRIS_HOST_PORT SITE_PORT
  edge_port 4000 OSIONOS_BRIDGE_HOST_PORT BRIDGE_PORT
  SITE="https://localhost:$SITE_PORT"
  BRIDGE="https://localhost:$BRIDGE_PORT"
  for url in "$SITE/api/auth/availability" "$BRIDGE/api/auth/bridge/health"; do
    code=$(request GET "$url")
    [ "$code" = 200 ] || fail edge "$url answers HTTP $code ($(said)): is the stack up? make link-frontends-up"
  done
  report ok edge "$SITE (site + auth gateway) and $BRIDGE (osionos bridge) over TLS, CA ${LINK_CA#"$REPO"/}"
}

# Availability is a GET with query parameters (auth-gateway.mjs:1137), not a POST.
step_availability() {
  local code
  code=$(request GET "$SITE/api/auth/availability?email=${EMAIL/@/%40}&username=$HANDLE")
  if ! { [ "$code" = 200 ] && jq -e '.email.available and .username.available' "$TMP/resp" >/dev/null; }; then
    fail availability "HTTP $code $(said)"
  fi
  report ok availability "HTTP 200, email and username $HANDLE are free"
}

# The local Turnstile bypass accepts only this token (auth-gateway.mjs:236), not any string.
step_register() {
  local code
  RT_PW=$PASSWORD jq -n --arg email "$EMAIL" --arg user "$HANDLE" '{email: $email, password: $ENV.RT_PW,
    turnstileToken: "localhost-turnstile-token", profile: {username: $user, confirmPassword: $ENV.RT_PW}}' >"$TMP/body"
  code=$(request POST "$SITE/api/auth/register" "$TMP/body")
  [ "$code" = 200 ] || fail register "HTTP $code $(said)"
  report ok register "HTTP 200 $(said)"
}

# The refresh token rides only in the prismatica_refresh cookie; the body keeps the access
# token (auth-gateway.mjs:348-351, 926-928).
step_login() {
  local code
  RT_PW=$PASSWORD jq -n --arg email "$EMAIL" \
    '{email: $email, password: $ENV.RT_PW, turnstileToken: "localhost-turnstile-token"}' >"$TMP/body"
  code=$(request POST "$SITE/api/auth/login" "$TMP/body")
  [ "$code" = 200 ] || fail login "HTTP $code $(said)"
  jq -er '(.access_token // .session.access_token) | strings | "Authorization: Bearer " + .' "$TMP/resp" >"$TMP/site-auth" 2>/dev/null ||
    fail login "HTTP 200 without an access_token"
  USER_ID=$(jq -r '.user.id // .session.user.id // empty' "$TMP/resp")
  awk '$6 == "prismatica_refresh" { f = 1 } END { exit !f }' "$TMP/jar" ||
    fail login "HTTP 200 without a prismatica_refresh cookie"
  report ok login "HTTP 200, user $USER_ID, access token and prismatica_refresh cookie received (not shown)"
}

# The handoff token rides in the redirect's fragment (bridge-api.mjs:1171-1172) and is
# base64url (bridge-api.mjs:219); jq moves it straight into the consume body.
step_session() {
  local code
  code=$(request POST "$SITE/api/auth/osionos-session" "$TMP/empty" "$TMP/site-auth")
  [ "$code" = 200 ] || fail osionos-session "HTTP $code $(said)"
  jq -e '{token: (.redirectUrl | capture("#bridge_token=(?<t>[A-Za-z0-9_-]+)").t)}' "$TMP/resp" >"$TMP/handoff" 2>/dev/null ||
    fail osionos-session "HTTP 200 without a #bridge_token redirect"
  report ok osionos-session "HTTP 200, redirect to $(jq -r '.redirectUrl | sub("#.*"; "")' "$TMP/resp")#bridge_token=(not shown)"
}

# The app token and the private workspace come back in the session
# (bridge-api.mjs:1182-1196); the token is signed as osionos_v1.<payload>.<sig> (:416).
step_consume() {
  local code
  code=$(request POST "$BRIDGE/api/auth/bridge/consume" "$TMP/handoff")
  [ "$code" = 200 ] || fail bridge-consume "HTTP $code $(said)"
  jq -er '.session.accessToken | select(startswith("osionos_v1.")) | "Authorization: Bearer " + .' \
    "$TMP/resp" >"$TMP/app-auth" 2>/dev/null || fail bridge-consume "HTTP 200 without an osionos_v1. app token"
  WORKSPACE_ID=$(jq -r '.session.privateWorkspaces[0]._id // empty' "$TMP/resp")
  [ -n "$WORKSPACE_ID" ] || fail bridge-consume "HTTP 200 without a private workspace"
  [ "$(jq -r '.session.userId' "$TMP/resp")" = "$USER_ID" ] || fail bridge-consume "the app session is for another user"
  report ok bridge-consume "HTTP 200, osionos_v1. app token (not shown), user $USER_ID, workspace $WORKSPACE_ID"
}

# GET /api/workspaces lists through grobase (bridge-api.mjs:2603); with no grobase row it
# lists synthesized entries without createdAt (:976-980), so createdAt proves a real row. The
# usual cause is the bridge giving up on grobase after 2.5 s at handoff (:99, :1155-1163).
step_workspaces() {
  local code
  code=$(request GET "$BRIDGE/api/workspaces" "" "$TMP/app-auth")
  [ "$code" = 200 ] || fail workspaces "HTTP $code $(said)"
  jq -er --arg id "$WORKSPACE_ID" 'first(.[] | select(._id == $id and .createdAt != null))
    | "\(.name) role=\(.role)"' "$TMP/resp" >"$TMP/ws" 2>/dev/null ||
    fail workspaces "HTTP 200, but $WORKSPACE_ID has no grobase row: see 'BaaS persistence skipped' in the bridge log"
  report ok workspaces "HTTP 200, $WORKSPACE_ID listed from grobase: $(cat "$TMP/ws")"
}

step_page_write() {
  local code
  jq -n --arg ws "$WORKSPACE_ID" --arg title "$TITLE" --arg text "$MARKER" '{workspaceId: $ws, title: $title,
    icon: "R", content: [{id: ("block-" + $title | gsub(" "; "-")), type: "paragraph", content: $text}]}' >"$TMP/body"
  code=$(request POST "$BRIDGE/api/pages" "$TMP/body" "$TMP/app-auth")
  [ "$code" = 201 ] || fail page-write "HTTP $code $(said)"
  PAGE_ID=$(jq -r '._id // empty' "$TMP/resp")
  [ -n "$PAGE_ID" ] || fail page-write "HTTP 201 without a page id"
  report ok page-write "HTTP 201, page $PAGE_ID \"$TITLE\" in workspace $WORKSPACE_ID"
}

# The read selects every column (bridge-api.mjs:863-868, 1794), so content comes back too.
step_page_read() {
  local code
  code=$(request GET "$BRIDGE/api/pages/$PAGE_ID" "" "$TMP/app-auth")
  if [ "$code" = 200 ] && jq -e --arg t "$TITLE" --arg m "$MARKER" \
    '.title == $t and any(.content[]?; .content == $m)' "$TMP/resp" >/dev/null; then
    report ok page-read "HTTP 200, title and paragraph read back through the bridge"
  else
    report FAIL page-read "HTTP $code $(said)"
  fi
}

step_db() {
  local step verdict detail via="on this daemon"
  rt_psql_plan -v "email=$EMAIL" -v "username=$HANDLE" -v "title=$TITLE" -v "marker=$MARKER" -v "page_id=$PAGE_ID"
  case $DB_MODE in
  direct)
    report SKIP db "direct link: only Kong is reachable, not postgres; page-read above is the read-back"
    return 0
    ;;
  local) ;;
  ssh) via="over ssh to $(state_get target 2>/dev/null || printf 'no target (make link)')" ;;
  *) fail db "link mode '$DB_MODE' is none of local, ssh, direct" ;;
  esac
  [ "${#PSQL[@]}" -gt 0 ] || fail db "$DB_MODE link, $via"
  report ok db-link "$DB_MODE link: docker exec $RT_PG psql $via"
  timeout "$RT_DB_TIMEOUT" "${PSQL[@]}" <<<"$RT_SQL" >"$TMP/db" 2>"$TMP/db.err" ||
    fail db "psql through the $DB_MODE link failed: $(head -n1 "$TMP/db.err")"
  [ "$(grep -c . "$TMP/db")" = 6 ] || fail db "expected 6 rows, got: $(head -c 160 "$TMP/db")"
  while IFS='|' read -r step verdict detail; do
    [ "$verdict" = ok ] || verdict=FAIL
    report "$verdict" "$step" "$detail"
  done <"$TMP/db"
}

usage() {
  cat <<'USAGE'
usage: account-roundtrip.sh   (no arguments)      exit 0: every step ok; 1: a FAIL or misuse
settings: LOCAL_CA_CERT, GROBASE_LINK_DIR, PG_CONTAINER, PG_USER, PG_DB, RT_SSH_TIMEOUT, RT_DB_TIMEOUT
USAGE
}
need() { command -v "$1" >/dev/null || fail preflight "$1 is not on PATH"; }

main() {
  local tool epoch step
  case "${1:-}" in '') ;; -h | --help) usage && exit 0 ;; *) usage >&2 && exit 1 ;; esac
  # The DB step comes last, after the account exists: what it needs is checked first.
  for tool in curl jq timeout; do need "$tool"; done
  DB_MODE=$(bash "$RT_LINK_SH" mode 2>/dev/null) || DB_MODE=local
  case $DB_MODE in local) need docker ;; ssh) need ssh ;; esac
  [ -f "$LINK_CA" ] || fail preflight "no CA at $LINK_CA (make certs)"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  : >"$TMP/jar"
  printf '{}\n' >"$TMP/empty"
  epoch=$(date +%s)
  read -r EMAIL HANDLE < <(rt_identity "$epoch" "$$")
  PASSWORD=$(rt_password)
  TITLE="roundtrip $epoch-$$"
  MARKER="written by account-roundtrip.sh for $EMAIL"
  printf 'account-roundtrip: %s (the rows are kept as evidence)\n' "$EMAIL"
  for step in edge availability register login session consume workspaces page_write page_read db; do
    "step_$step"
  done
  exit "$FAILED"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0 # sourced by scripts/tests/account-roundtrip.bats
main "$@"
