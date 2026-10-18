#!/bin/sh
# Applies user.sql, gdpr-migration.sql and auth-security-migration.sql (the order the migration
# runner uses) to a throwaway postgres:16-alpine with no network, then proves the function
# records every type in the CHECK list and refuses an unknown one with SQLSTATE 22023.
# Usage: auth-audit-runtime-check.sh [path/to/auth-security-migration.sql]
# Exit 0 when all checks hold, 1 otherwise. Needs docker and the cached postgres:16-alpine image.
#
# Caveat: the three files run as the postgres superuser against an empty database, so a
# production table or function that differs from the repo files is not exercised here.
set -eu

here=$(cd "$(dirname "$0")/../.." && pwd)
auth_sql=$(realpath "${1:-$here/models/auth-security-migration.sql}")
name=audit-runtime-check-$$
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT

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

psql -c 'CREATE ROLE service_role; CREATE ROLE authenticated; CREATE ROLE anon;'
for f in /models/user.sql /models/gdpr-migration.sql /auth.sql; do psql -f "$f" >/dev/null; done

# The names come from the file, so a comma-broken copy yields a name the CHECK does not hold.
types=$(awk '/ADD CONSTRAINT .*CHECK \(event_type IN \($/ { in_list = 1; next } in_list && /^  \)\);$/ { exit } in_list' "$auth_sql" |
  tr -d ' \n')
count=$(printf '%s' "$types" | tr -cd "'" | wc -c)
count=$((count / 2))
recorded=$(psql -c "SELECT count(*) FILTER (WHERE r->>'status' = 'recorded') FROM unnest(ARRAY[$types]) t,
  LATERAL auth_record_audit_event(t, NULL, '{}') r")
echo "recorded/listed: $recorded/$count"
[ "$recorded" = "$count" ] && [ "$count" -ge 36 ] || exit 1

state=$(psql -c "DO \$\$ BEGIN PERFORM auth_record_audit_event('zz_not_a_type'); EXCEPTION WHEN SQLSTATE '22023' THEN RAISE WARNING 'sqlstate 22023'; END \$\$" 2>&1)
echo "unknown type: $state"
case "$state" in *"sqlstate 22023"*) ;; *) exit 1 ;; esac
