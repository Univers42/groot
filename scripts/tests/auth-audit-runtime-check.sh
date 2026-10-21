#!/bin/sh
# Applies user.sql, gdpr-migration.sql and auth-security-migration.sql (the order grobase's
# track-binocle project init uses) to a throwaway postgres:16-alpine with no network, then proves the function
# records every type in the CHECK list and refuses an unknown one with SQLSTATE 22023.
#
# It proves that for BOTH key types of public.users.id, because auth_audit_events.user_id
# follows whatever type the catalog reports for it: once on the INTEGER users table user.sql
# creates, and once on a UUID users table (the type the auth gateway's BaaS database has),
# created here in a second throwaway database in the same container.
#
# Usage: auth-audit-runtime-check.sh [path/to/auth-security-migration.sql]
# Exit 0 when all checks hold, 1 otherwise. Needs docker and the cached postgres:16-alpine image.
#
# Caveat: the three files run as the postgres superuser against an empty database, so a
# production table or function that differs from the repo files is not exercised here.
set -eu

here=$(cd "$(dirname "$0")/../.." && pwd)
auth_sql=$(realpath "${1:-$here/models/auth-security-migration.sql}")
name=audit-runtime-check-$$
# The container goes away either way, and every failure leaves exit code 1 — psql exits 2 or 3
# on its own errors, and this script's contract is a plain 1.
cleanup() {
  rc=$?
  trap - EXIT
  docker rm -f "$name" >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] || exit 1
}
trap cleanup EXIT

docker run -d --name "$name" --network none -e POSTGRES_PASSWORD=x \
  -v "$here/models:/models:ro" -v "$auth_sql:/auth.sql:ro" postgres:16-alpine >/dev/null
psql() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$name" psql -U postgres -v ON_ERROR_STOP=1 -qtA "$@"; }
# The entrypoint runs initdb on a temporary server, then restarts; only the second one is ready.
# Caveat: bounded at 60 s, so a cold image on a slow disk can fail here before postgres is up.
tries=0
until docker logs "$name" 2>&1 | grep -q 'init process complete' && psql -c 'select 1' >/dev/null 2>&1; do
  tries=$((tries + 1))
  [ "$tries" -lt 60 ] || { echo "postgres not ready after 60 s" >&2; exit 1; }
  sleep 1
done

# The names come from the file, so a comma-broken copy yields a name the CHECK does not hold.
types=$(awk '/ADD CONSTRAINT .*CHECK \(event_type IN \($/ { in_list = 1; next } in_list && /^  \)\);$/ { exit } in_list' "$auth_sql" |
  tr -d ' \n')
count=$(printf '%s' "$types" | tr -cd "'" | wc -c)
count=$((count / 2))

# The proof every key type has to pass, in the database $1, labelled $2 in the summary lines:
# every listed type records, an unknown one raises SQLSTATE 22023, and the audit table's
# user_id column carries the very type public.users.id has.
check_audit() {
  check_db=$1
  check_label=$2

  recorded=$(psql -d "$check_db" -c "SELECT count(*) FILTER (WHERE r->>'status' = 'recorded') FROM unnest(ARRAY[$types]) t,
    LATERAL auth_record_audit_event(t, NULL, '{}') r")
  echo "recorded/listed ($check_label): $recorded/$count"
  [ "$recorded" = "$count" ] && [ "$count" -ge 36 ] || return 1

  state=$(psql -d "$check_db" -c "DO \$\$ BEGIN PERFORM auth_record_audit_event('zz_not_a_type'); EXCEPTION WHEN SQLSTATE '22023' THEN RAISE WARNING 'sqlstate 22023'; END \$\$" 2>&1)
  echo "unknown type ($check_label): $state"
  case "$state" in *"sqlstate 22023"*) ;; *) return 1 ;; esac

  users_type=$(psql -d "$check_db" -c "SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'users' AND a.attname = 'id'
      AND a.attnum > 0 AND NOT a.attisdropped")
  audit_type=$(psql -d "$check_db" -c "SELECT format_type(atttypid, atttypmod) FROM pg_attribute
    WHERE attrelid = 'public.auth_audit_events'::regclass AND attname = 'user_id'")
  echo "user_id type ($check_label): $audit_type (users.id: $users_type)"
  [ -n "$users_type" ] && [ "$audit_type" = "$users_type" ] || return 1
}

# The integer key type: user.sql creates users with a SERIAL id.
psql -c 'CREATE ROLE service_role; CREATE ROLE authenticated; CREATE ROLE anon;'
for f in /models/user.sql /models/gdpr-migration.sql /auth.sql; do psql -f "$f" >/dev/null; done
check_audit postgres integer || exit 1

# The uuid key type: the auth gateway's BaaS database has a uuid users.id. Only the auth file
# is applied here — no user.sql, no gdpr-migration.sql — because the users table it follows is
# created here, with a uuid id and the one row the check below looks up.
psql -c 'CREATE DATABASE uuidcheck;'
psql -d uuidcheck -c 'CREATE TABLE users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text);'
psql -d uuidcheck -c "INSERT INTO users (email) VALUES ('reed@agency.local');"
psql -d uuidcheck -f /auth.sql >/dev/null
check_audit uuidcheck uuid || exit 1

# An event for a padded, mixed-case email must land on that user's uuid in user_id.
psql -d uuidcheck -c "SELECT auth_record_audit_event('login_success', ' Reed@Agency.local ', '{}')" >/dev/null
expected=$(psql -d uuidcheck -c "SELECT id FROM users WHERE email = 'reed@agency.local'")
stored=$(psql -d uuidcheck -c "SELECT user_id FROM auth_audit_events
  WHERE event_type = 'login_success' AND email = 'reed@agency.local' ORDER BY id DESC LIMIT 1")
echo "matched user_id (uuid): $stored"
[ -n "$expected" ] && [ "$stored" = "$expected" ] || exit 1
