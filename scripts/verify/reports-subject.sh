#!/bin/sh
# reports-subject.sh — prove the osionos_user_reports subject_kind CHECK accepts
# every moderated subject and that a reporter files ONE report per subject.
# See models/osionos-social-migration.sql.
#
# WHAT IT PROVES
#   fresh/replayed  the social migration applied TWICE leaves exactly one
#                   subject_kind CHECK; a 'page', a 'feed_comment' and a
#                   'page_comment' report insert; 'bogus' is refused with
#                   SQLSTATE 23514; the same (reporter, kind, id) twice is
#                   refused with SQLSTATE 23505.
#   legacy          a database that already holds two identical reports (the
#                   pre-change table, copied here as a heredoc) still takes the
#                   new migration with exit 0, keeps BOTH rows, says so with a
#                   NOTICE, and creates NO unique index: the duplicate rows are
#                   user data and are never deleted, merged or rewritten.
#
# ISOLATION: throwaway containers only: reports-subject-$$ (--network none, no
# port, no volume). The live databases are never touched. A trap removes the
# container on every exit path.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${REPO}/scripts/verify"
MODELS="${REPO}/models"
FIX="${DIR}/models-grants"
CTN="reports-subject-$$"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reports-subject.XXXXXX")"
passed=0
failed=0
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

note() { printf '[reports-subject] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s %s\n' "$1" "$2"; }

drop_container() {
  if [ "${KEEP}" -eq 1 ]; then
    note "--keep: container ${CTN} left up"
    return 0
  fi
  docker rm -f "${CTN}" >/dev/null 2>&1 || true
  return 0
}
trap 'drop_container; rm -rf "${WORK}"' EXIT INT TERM

# psql_db <db> — a session on one database of the throwaway container.
psql_db() { docker exec -i "${CTN}" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qAt; }

# q <db> <sql> — the first column of the first row. A failing query reads as
# "nothing" and the check that wanted it fails; it never aborts the run.
q() { printf '%s\n' "$2" | psql_db "$1" 2>"${WORK}/q.err" || true; }

# apply <db> <file> <logname> — psql a file. The log (NOTICEs included) lands
# in ${WORK}/<logname>.log.
apply() {
  if docker exec -i "${CTN}" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -q <"$2" >"${WORK}/$3.log" 2>&1; then
    return 0
  fi
  note "psql rejected $(basename "$2") on $1"
  sed 's/^/  | /' "${WORK}/$3.log" >&2
  return 1
}

# state_of <db> <sql> — the SQLSTATE the statement was refused with; empty when
# the statement was accepted.
state_of() {
  err="${WORK}/state.err"
  if printf '%s\n' '\set VERBOSITY sqlstate' "$2" |
    docker exec -i "${CTN}" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qAt >/dev/null 2>"${err}"; then
    printf ''
    return 0
  fi
  sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' "${err}" | head -1
}

# insert_report <db> <reporter> <kind> <subject_id>
insert_report() {
  printf "INSERT INTO public.osionos_user_reports (reporter_id, subject_kind, subject_id) VALUES ('%s','%s','%s');\n" \
    "$2" "$3" "$4" | psql_db "$1" >/dev/null 2>&1
}

# check_eq <id> <label> <expected> <actual>
check_eq() {
  if [ "$3" = "$4" ]; then
    pass "$1" "$2"
  else
    fail "$1" "$2 (expected $3, got ${4:-nothing})"
  fi
}

start_pg() {
  command -v docker >/dev/null 2>&1 || { note "docker is required"; exit 2; }
  docker run -d --rm --network none --name "${CTN}" -e POSTGRES_HOST_AUTH_METHOD=trust "${PG_IMAGE}" >/dev/null
  i=0
  while [ "${i}" -lt 60 ]; do
    docker exec "${CTN}" pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 1
  done
  note "postgres never became ready"
  exit 1
}

# fixture <db> — the prerequisites the social migration needs: the auth.users
# stand-in (GoTrue), then the bridge and the chat models, in that order.
fixture() {
  printf 'CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb);\n' |
    docker exec -i "${CTN}" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -q >/dev/null || return 1
  apply "$1" "${MODELS}/osionos-bridge-migration.sql" "bridge-$1" || return 1
  apply "$1" "${MODELS}/osionos-chat-migration.sql" "chat-$1" || return 1
}

main() {
  start_pg
  note "postgres up"
  docker exec "${CTN}" createdb -U postgres legacy

  # The roles are cluster-wide, so roles.sql runs once, on the first database;
  # the legacy database gets the per-database half of it (the schema and the
  # grants), because CREATE ROLE cannot run twice.
  apply postgres "${FIX}/roles.sql" roles || exit 1
  cat >"${WORK}/legacy-grants.sql" <<'SQL'
CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
SQL
  apply legacy "${WORK}/legacy-grants.sql" legacy-grants || exit 1
  for db in postgres legacy; do
    fixture "${db}" || exit 1
  done
  note "fixture applied"

  # ── the fresh database, the migration replayed twice ──
  apply postgres "${MODELS}/osionos-social-migration.sql" social-1 || exit 1
  apply postgres "${MODELS}/osionos-social-migration.sql" social-2 || exit 1
  note "social migration applied twice"

  n="$(q postgres "SELECT count(*) FROM pg_constraint con
      WHERE con.conrelid = 'public.osionos_user_reports'::regclass
        AND con.contype = 'c'
        AND pg_get_constraintdef(con.oid) LIKE '%subject_kind%';")"
  check_eq c1 "exactly one subject_kind CHECK" 1 "${n:-none}"

  if insert_report postgres 11111111-1111-1111-1111-111111111111 page page-1; then
    pass c2 "a 'page' report inserts"
  else
    fail c2 "a 'page' report inserts"
  fi
  if insert_report postgres 22222222-2222-2222-2222-222222222222 feed_comment fc-1; then
    pass c3 "a 'feed_comment' report inserts"
  else
    fail c3 "a 'feed_comment' report inserts"
  fi
  if insert_report postgres 33333333-3333-3333-3333-333333333333 page_comment pc-1; then
    pass c4 "a 'page_comment' report inserts"
  else
    fail c4 "a 'page_comment' report inserts"
  fi

  st="$(state_of postgres "INSERT INTO public.osionos_user_reports (reporter_id, subject_kind, subject_id) VALUES ('44444444-4444-4444-4444-444444444444','bogus','x');")"
  check_eq c5 "'bogus' is refused with 23514" 23514 "${st:-none}"

  first=ok
  insert_report postgres 55555555-5555-5555-5555-555555555555 message msg-1 || first=no
  st="$(state_of postgres "INSERT INTO public.osionos_user_reports (reporter_id, subject_kind, subject_id) VALUES ('55555555-5555-5555-5555-555555555555','message','msg-1');")"
  if [ "${first}" = "ok" ] && [ "${st:-none}" = "23505" ]; then
    pass c6 "the same (reporter, kind, id) twice is refused with 23505"
  else
    fail c6 "the same (reporter, kind, id) twice is refused with 23505 (got ${st:-nothing}, first insert ${first})"
  fi

  n="$(q postgres "SELECT count(*) FROM pg_indexes
      WHERE schemaname = 'public' AND indexname = 'osionos_user_reports_reporter_subject_key';")"
  check_eq c7 "the unique index on (reporter, kind, subject) exists" 1 "${n:-none}"

  # ── the legacy database: the pre-change table, duplicates already in it ──
  cat >"${WORK}/old-reports.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS public.osionos_user_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id UUID NOT NULL,
  subject_user_id UUID,
  subject_kind TEXT NOT NULL DEFAULT 'user'
    CHECK (subject_kind IN ('user', 'message', 'channel', 'workspace')),
  subject_id TEXT,
  category TEXT NOT NULL DEFAULT 'other',
  details TEXT,
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'reviewing', 'resolved', 'dismissed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL
  apply legacy "${WORK}/old-reports.sql" old-reports || exit 1
  printf '%s\n%s\n' \
    "INSERT INTO public.osionos_user_reports (reporter_id, subject_kind, subject_id, category) VALUES ('66666666-6666-6666-6666-666666666666','user','dup-1','spam');" \
    "INSERT INTO public.osionos_user_reports (reporter_id, subject_kind, subject_id, category) VALUES ('66666666-6666-6666-6666-666666666666','user','dup-1','spam');" |
    psql_db legacy >/dev/null 2>&1 || { note "the legacy rows could not be inserted"; exit 1; }
  note "legacy table with two identical reports"

  # The migration must complete (exit 0) on a database that holds duplicates.
  apply legacy "${MODELS}/osionos-social-migration.sql" social-legacy || exit 1

  n="$(q legacy "SELECT count(*) FROM public.osionos_user_reports;")"
  check_eq l1 "both legacy rows are still there" 2 "${n:-none}"

  if grep 'NOTICE:' "${WORK}/social-legacy.log" | grep -q 'duplicate' &&
    grep 'NOTICE:' "${WORK}/social-legacy.log" | grep -q 'osionos_user_reports_reporter_subject_key'; then
    pass l2 "the migration says how many duplicate groups it found"
  else
    fail l2 "the migration says how many duplicate groups it found"
  fi

  n="$(q legacy "SELECT count(*) FROM pg_indexes
      WHERE schemaname = 'public' AND indexname = 'osionos_user_reports_reporter_subject_key';")"
  check_eq l3 "no unique index on a table that holds duplicates" 0 "${n:-none}"

  printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
  drop_container
  [ "${failed}" -eq 0 ] || exit 1
  exit 0
}

main "$@"
