#!/usr/bin/env sh
# demo-login-ensure.sh — make the local demo account's password the one in ./.env.local.
#
# The data snapshot (git or vault seed) carries the account with an old password that was
# published in this public repo. This step, run by `make all` right after the restore,
# sets it to the per-machine DEMO_LOGIN_PASSWORD that gen-local-env.sh minted. Idempotent:
# a password that already matches is left alone (no new hash each run).
#
# The value never touches argv or SQL text: docker exec forwards it by NAME (-e VAR) and
# psql reads it with \getenv, so a failed statement cannot echo it back.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENV_LOCAL="${ENV_LOCAL:-$REPO/.env.local}"
PG_CONTAINER="${PG_CONTAINER:-mini-baas-postgres}"
# shellcheck source=scripts/lib/demo-login.sh
. "$REPO/scripts/lib/demo-login.sh"

note() { printf '[demo-login] %s\n' "$1" >&2; }

DEMO_LOGIN_PASSWORD="$(demo_login_password "$ENV_LOCAL")" || exit 1
export DEMO_LOGIN_PASSWORD DEMO_LOGIN_EMAIL

docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER" || {
	note "$PG_CONTAINER is not running — bring the backend up (make backend-up), then re-run make demo-login-ensure."
	exit 1
}

state="$(docker exec -i -e DEMO_LOGIN_PASSWORD -e DEMO_LOGIN_EMAIL "$PG_CONTAINER" \
	psql -U postgres -d postgres -X -q -tA <<'SQL'
\set ON_ERROR_STOP 1
\set VERBOSITY terse
\getenv pw DEMO_LOGIN_PASSWORD
\getenv email DEMO_LOGIN_EMAIL
SET search_path = public, extensions;
WITH account AS (
  SELECT id, coalesce(encrypted_password = crypt(:'pw', encrypted_password), false) AS current
  FROM auth.users WHERE email = :'email'
), reset AS (
  UPDATE auth.users SET encrypted_password = crypt(:'pw', gen_salt('bf', 10)), updated_at = now()
  WHERE id IN (SELECT id FROM account WHERE NOT current)
  RETURNING id
)
SELECT CASE
  WHEN NOT EXISTS (SELECT 1 FROM account) THEN 'missing'
  WHEN EXISTS (SELECT 1 FROM reset) THEN 'updated'
  ELSE 'current' END;
SQL
)" || {
	note "could not set the demo password on $PG_CONTAINER (see the psql error above)."
	exit 1
}

case "$state" in
updated) note "$DEMO_LOGIN_EMAIL: password set from ./.env.local (make demo-login prints it)." ;;
current) note "$DEMO_LOGIN_EMAIL: password already matches ./.env.local." ;;
missing)
	note "$DEMO_LOGIN_EMAIL is not in auth.users — was the data restored? (make restore-if-empty)"
	exit 1
	;;
*)
	note "unexpected answer from postgres: '$state'"
	exit 1
	;;
esac
