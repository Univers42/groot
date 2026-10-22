#!/bin/sh
# rec-beacon.sh — proof of the beacon write (devil C48–C50) on a THROWAWAY Postgres, never
# the running stack: the prerequisite models, then the events and beacon migrations twice
# (idempotence), then rec-beacon.sql. Proves: no consent row or an explicit false writes 0
# rows (C48); 200 clicks of one user on one page are ONE row and two users are two (C50);
# the bucket is the UTC day; a click without a rec_id is nothing; 51 events are 22023; the
# daily cap is 54000; `authenticated` cannot call it. Exit 1 on any FAIL.
#
# Run: sh scripts/verify/rec-beacon.sh
# Caveat: every call runs within one UTC day — a bucket that splits the day finer is caught
# only through the "ts is the UTC day start" check (it fails, unless the run lands in the
# first hour of the UTC day).
set -eu

REPO="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
MODELS="$REPO/models"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
CTN="verify-rec-beacon-$$"
LOG="$(mktemp)"
trap 'docker rm -f "$CTN" >/dev/null 2>&1; rm -f "$LOG"' EXIT INT TERM

docker run -d --rm --name "$CTN" -e POSTGRES_HOST_AUTH_METHOD=trust "$PG_IMAGE" >/dev/null
# The entrypoint's temporary server refuses connections while it stops: ready means PID 1
# is postgres AND a query goes through.
i=0
until [ "$(docker exec "$CTN" cat /proc/1/comm 2>/dev/null)" = postgres ] &&
	docker exec "$CTN" psql -U postgres -c 'SELECT 1' >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -lt 60 ] || { echo "FAIL: postgres did not start"; exit 1; }
	sleep 1
done

psql_run() { docker exec -i "$CTN" psql -q -U postgres -v ON_ERROR_STOP=1; }

echo "CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth; CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS 'SELECT NULL::uuid';" | psql_run

for f in osionos-bridge-migration.sql osionos-chat-migration.sql osionos-social-migration.sql \
	osionos-engagement-migration.sql osionos-comments-migration.sql osionos-favorites-migration.sql \
	osionos-feed-engagement-migration.sql osionos-user-events-migration.sql \
	osionos-rec-beacon-migration.sql osionos-user-events-migration.sql osionos-rec-beacon-migration.sql; do
	psql_run <"$MODELS/$f" >"$LOG" 2>&1 || { echo "FAIL: apply $f"; tail -3 "$LOG"; exit 1; }
done

psql_run <"$REPO/scripts/verify/rec-beacon.sql" >"$LOG" 2>&1 || status=1
sed -n 's/^NOTICE:  //p; s/^ERROR:  //p' "$LOG"
exit "${status:-0}"
