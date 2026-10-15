#!/usr/bin/env bash
# lib.sh — the primitives vm-bootstrap.sh builds on: the write windows, the engine shells, the
# Kong calls and the state file. Sourced inside the baas VM (or a local fixture). Every secret
# travels on stdin, in a mode-600 file under $WORK, or as `docker exec -e NAME` taken from this
# shell's environment: never on a command line (devil phase2 condition 6).
#
# Container names and the Kong URL come from the environment so the bats fixture can point them
# at throwaway containers: DEMO_PG_CONTAINER, DEMO_MONGO_CONTAINER, DEMO_KONG_CONTAINER,
# DEMO_KONG_URL.

PG_CONTAINER="${DEMO_PG_CONTAINER:-mini-baas-postgres}"
MONGO_CONTAINER="${DEMO_MONGO_CONTAINER:-mini-baas-mongo}"
KONG_CONTAINER="${DEMO_KONG_CONTAINER:-mini-baas-kong}"
KONG_URL="${DEMO_KONG_URL:-http://127.0.0.1:8000}"

say() { printf '[vm-bootstrap] %s\n' "$*" >&2; }
die() {
  say "refused: $*"
  exit 1
}

# deploy_mountlist_running — the [d] keeps pgrep -f from matching a shell that carries this
# check's own code on its command line (measured 2026-10-16: an inline `ssh b2b 'pgrep -f …'`
# saw itself and would have waited forever).
# Caveat: any process whose command line names the script (an editor, `less`) still counts as
# running, so the seed waits; over-reporting, never under. Close it to proceed.
deploy_mountlist_running() { pgrep -f '[d]eploy-mountlist' >/dev/null 2>&1; }

# write_window_wait — blocks until writing is allowed: never at :58-:07 (b2b-backup's hourly
# pg_dump starts on the hour plus up to 5 min) nor 00:30-00:50 (b2b-var-gc at 00:39:55), nor
# while deploy-mountlist runs. DEMO_IGNORE_WINDOW=1 is for the local fixture only.
# Caveat: the windows are copied from groot-69's report of 2026-10-16; a timer moved on the
# VM is not seen here. `systemctl list-timers` in the VM is the source of truth.
# write_window_reason HOUR MINUTE — why writing is closed at that time, with when it reopens;
# empty when it is open.
write_window_reason() {
  local hour=$((10#$1)) minute=$((10#$2))
  if [ "$minute" -ge 58 ]; then
    printf "b2b-backup's hourly pg_dump; writing resumes at %02d:08" $(((hour + 1) % 24))
  elif [ "$minute" -le 7 ]; then
    printf "b2b-backup's hourly pg_dump; writing resumes at %02d:08" "$hour"
  elif [ "$hour" -eq 0 ] && [ "$minute" -ge 30 ] && [ "$minute" -le 50 ]; then
    printf "b2b-var-gc; writing resumes at 00:51"
  fi
}

write_window_wait() {
  [ "${DEMO_IGNORE_WINDOW:-0}" = 1 ] && return 0
  local reason said=""
  while :; do
    reason="$(write_window_reason "$(date +%H)" "$(date +%M)")"
    [ -n "$reason" ] || ! deploy_mountlist_running || reason="deploy-mountlist is running; writing resumes when it exits"
    [ -n "$reason" ] || return 0
    [ "$reason" = "$said" ] || say "paused at $(date +%H:%M): $reason (not stuck; nothing to do)"
    said="$reason"
    sleep 30
  done
}

# pg_super — psql as the engine's superuser over the container's local socket; SQL on stdin.
# Used for the bootstrap (role, database, grants) and read-only counts, never for demo data.
pg_super() {
  docker exec -i "$PG_CONTAINER" sh -c 'exec psql -X -q -At -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" "$@"' psql "$@"
}

# pg_as_demo — psql logged in as the demo role itself (condition 4). DEMO_PG_PASSWORD rides in
# as an inherited env var; `-1` makes the whole input one transaction.
pg_as_demo() {
  local role="$1"
  shift
  PGPASSWORD="$DEMO_PG_PASSWORD" docker exec -i -e PGPASSWORD "$PG_CONTAINER" \
    psql -X -q -At -1 -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$role" -d "$role" "$@"
}

# mongo_js — runs a mongosh script already copied into the container, with --nodb; the script
# authenticates itself from process.env, so no credential is on argv.
mongo_js() {
  docker exec -i -e DEMO_MONGO_USER -e DEMO_MONGO_PASSWORD -e DEMO_MONGO_DB -e DEMO_MONGO_DIR \
    "$MONGO_CONTAINER" mongosh --nodb --quiet --file "$1"
}

# kong_env — one variable from the Kong container's environment, into a shell variable only.
kong_env() { docker exec "$KONG_CONTAINER" printenv "$1"; }

# curl_config — writes a mode-600 curl config holding the given header lines; prints its path.
curl_config() {
  local file="$WORK/$1.cfg" header
  shift
  : >"$file"
  chmod 600 "$file"
  for header in "$@"; do printf 'header = "%s"\n' "$header" >>"$file"; done
  printf '%s' "$file"
}

# kong_call METHOD PATH CONFIG [body] — curl through Kong, headers from CONFIG. Prints the HTTP
# code; the body lands in $WORK/resp. With a 4th argument the request body is read from stdin.
kong_call() {
  local method="$1" path="$2" config="$3"
  curl -sS --max-time 30 -K "$config" -X "$method" -o "$WORK/resp" -w '%{http_code}' \
    ${4:+--data-binary @-} "$KONG_URL$path"
}

# state_put — the VM's record of what this uid8 has created: ids only, one KEY=VALUE per line,
# appended as each object comes into being (condition 1).
state_put() { printf '%s=%s\n' "$1" "$2" >>"$STATE_FILE"; }

sql_literal() { printf "'%s'" "${1//\'/\'\'}"; }
