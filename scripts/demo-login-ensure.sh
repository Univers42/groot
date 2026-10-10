#!/usr/bin/env sh
# demo-login-ensure.sh — make the local demo account's password the one in ./.env.local.
#
# The data snapshot (git or vault seed) carries the account with an old password that was
# published in this public repo. This step, run by `make all` right after the restore,
# sets it to the per-machine DEMO_LOGIN_PASSWORD that gen-local-env.sh minted. Idempotent:
# a password that already matches is left alone (no new hash each run).
#
# LOCAL mode (the .vault42-local-mode marker: no vault key, or the pull failed) has no team
# data and, since grobase de656694 dropped the committed snapshot, nothing restores the
# account either. There the account is CREATED through GoTrue's admin API behind Kong with
# that same password, so a no-vault `make all` still ends with a working login. Outside
# LOCAL mode a missing account means the restore failed, and that stays a hard error.
#
# The value never touches argv or SQL text: docker exec forwards it by NAME (-e VAR) and
# psql reads it with \getenv, so a failed statement cannot echo it back.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENV_LOCAL="${ENV_LOCAL:-$REPO/.env.local}"
PG_CONTAINER="${PG_CONTAINER:-mini-baas-postgres}"
KONG_CONTAINER="${KONG_CONTAINER:-mini-baas-kong}"
LOCAL_MODE_MARK="${LOCAL_MODE_MARK:-$REPO/.vault42-local-mode}"
# shellcheck source=scripts/lib/demo-login.sh
. "$REPO/scripts/lib/demo-login.sh"
# shellcheck source=scripts/lib/envfile.sh
. "$REPO/scripts/lib/envfile.sh"

note() { printf '[demo-login] %s\n' "$1" >&2; }

# baas_url: Kong's published port, resolved now as common.mk does (grobase moves Kong off
# 8000 when it is taken). BAAS_URL overrides.
baas_url() {
	if [ -n "${BAAS_URL:-}" ]; then
		printf '%s' "$BAAS_URL"
		return 0
	fi
	_bu_port="$(docker port "$KONG_CONTAINER" 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
	[ -n "$_bu_port" ] || {
		note "cannot find $KONG_CONTAINER's published port — is the backend up?"
		return 1
	}
	printf 'http://127.0.0.1:%s' "$_bu_port"
}

# create_account: GoTrue admin API, POST /auth/v1/admin/users. The two keys ride in a curl
# config file and the password in the JSON body on stdin — nothing secret on argv.
create_account() {
	apikey="$(get_env "$ENV_LOCAL" SB_KONG_KEY)" || {
		note "SB_KONG_KEY is not set in $ENV_LOCAL — bash scripts/gen-local-env.sh --sync"
		return 1
	}
	service="$(get_env "$ENV_LOCAL" SERVICE_ROLE_KEY)" || {
		note "SERVICE_ROLE_KEY is not set in $ENV_LOCAL — bash scripts/gen-local-env.sh --sync"
		return 1
	}
	url="$(baas_url)" || return 1
	tmp="$(mktemp -d)" && chmod 700 "$tmp"
	trap 'rm -rf "$tmp"' EXIT
	printf 'header = "apikey: %s"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
		"$apikey" "$service" >"$tmp/curl.cfg"
	code="$(printf '{"email":"%s","password":"%s","email_confirm":true}' "$DEMO_LOGIN_EMAIL" "$DEMO_LOGIN_PASSWORD" |
		curl -sS --max-time 20 -K "$tmp/curl.cfg" --data-binary @- -o "$tmp/resp" -w '%{http_code}' \
			"$url/auth/v1/admin/users")" || code=000
	case "$code" in
	200 | 201) return 0 ;;
	*)
		note "GoTrue did not create $DEMO_LOGIN_EMAIL (HTTP $code): $(head -c 300 "$tmp/resp" 2>/dev/null)"
		return 1
		;;
	esac
}

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
	if [ -e "$LOCAL_MODE_MARK" ]; then
		note "$DEMO_LOGIN_EMAIL is not in auth.users and this machine is in LOCAL mode (no team data) — creating it."
		create_account || exit 1
		note "$DEMO_LOGIN_EMAIL: created with the password from ./.env.local (make demo-login prints it)."
	else
		note "$DEMO_LOGIN_EMAIL is not in auth.users — was the data restored? (make restore-if-empty)"
		exit 1
	fi
	;;
*)
	note "unexpected answer from postgres: '$state'"
	exit 1
	;;
esac
