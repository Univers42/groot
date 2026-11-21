#!/usr/bin/env bash
# revoke-automation-sessions.sh — sign out the sessions automation left on an account.
#
#   revoke-automation-sessions.sh --api URL [--env-file FILE] [--apply] [--since ISO_UTC] [--keep RE]
#
# Every probe, smoke or script that signs in leaves a live session; the owner then reads a
# sessions list full of sign-ins they never made. This signs in as DEMO_LOGIN_EMAIL with
# DEMO_LOGIN_PASSWORD from FILE (default ./.env.local), lists the sessions, and revokes each
# automation family through DELETE /api/account/sessions/:id — never POST
# /api/auth/bridge/logout, which signs the owner out of every device. Its own sign-in is
# revoked last, dry run included, so the tool leaves nothing behind.
#
# Without --apply it prints what it would revoke. Rows are classed by
# scripts/lib/automation-sessions.jq (its Caveat names what it misclasses). --since makes
# Electron sign-ins from that minute on automation (a desktop smoke run's start). Output
# carries no session id, token or password. Tested in scripts/tests/revoke-automation-sessions.bats.
#
# Caveat: the list route returns at most 50 families, so revocation runs in passes until a
# pass finds nothing new (at most 10). The revoke route allows 30 per minute per user; a 429
# waits REVOKE_RETRY_SECONDS (65) and retries twice, then counts as failed — re-run the tool.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=scripts/lib/demo-login.sh
. "$HERE/lib/demo-login.sh"

API="" ENV_FILE="$REPO/.env.local" APPLY=0 SINCE="" KEEP="X11; Ubuntu;"
PAUSE="${REVOKE_PAUSE_SECONDS:-3}" RETRY_WAIT="${REVOKE_RETRY_SECONDS:-65}"
REVOKED=0 FAILED=0 AUTOMATION=0 KEPT=0 SELF_ID=""
declare -A SEEN=()

usage() { sed -n 4p "$0" | sed 's/^# *//' >&2; }

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--api) API="${2:-}"; shift ;;
		--env-file) ENV_FILE="${2:-}"; shift ;;
		--since) SINCE="${2:-}"; shift ;;
		--keep) KEEP="${2:-}"; shift ;;
		--apply) APPLY=1 ;;
		-h | --help) usage; exit 0 ;;
		*) usage; exit 2 ;;
		esac
		shift
	done
	[ -n "$API" ] || { echo "revoke-automation-sessions: --api URL is required" >&2; usage; exit 2; }
	API="${API%/}"
}

# The password reaches curl through a 0600 body file, never an argv; the token through a header file.
sign_in() {
	local pw code
	pw="$(demo_login_password "$ENV_FILE")" || exit 1
	jq -n --arg e "$DEMO_LOGIN_EMAIL" --rawfile p <(printf '%s' "$pw") '{email: $e, password: $p}' >"$WORK/body"
	code="$(curl -sS -m 30 -o "$WORK/login" -w '%{http_code}' -H 'content-type: application/json' \
		--data-binary @"$WORK/body" "$API/api/auth/login" </dev/null)" || code=000
	rm -f "$WORK/body"
	[ "$code" = 200 ] || { echo "sign-in failed: HTTP $code" >&2; exit 1; }
	local token
	token="$(jq -r '.accessToken // empty' "$WORK/login")"
	rm -f "$WORK/login"
	[ -n "$token" ] || { echo "sign-in returned no access token" >&2; exit 1; }
	printf 'Authorization: Bearer %s\n' "$token" >"$WORK/auth"
}

list_sessions() {
	curl -sS -f -m 30 -H @"$WORK/auth" "$API/api/account/sessions" </dev/null >"$WORK/list" ||
		{ echo "listing sessions failed" >&2; return 1; }
	jq -r --arg since "$SINCE" --arg keep "$KEEP" -f "$HERE/lib/automation-sessions.jq" "$WORK/list" >"$WORK/rows"
}

# One DELETE with up to two retries on 429. 204 = revoked; 404 = already gone, neither counts as failed.
revoke() {
	local code try
	for try in 1 2 3; do
		code="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X DELETE -H @"$WORK/auth" \
			"$API/api/account/sessions/$1" </dev/null)" || code=000
		[ "$code" = 429 ] && [ "$try" -lt 3 ] && { sleep "$RETRY_WAIT"; continue; }
		break
	done
	case "$code" in
	204) REVOKED=$((REVOKED + 1)) ;;
	404) ;;
	*) FAILED=$((FAILED + 1)); echo "  revoke failed: HTTP $code" >&2 ;;
	esac
	sleep "$PAUSE"
}

# Prints each row once and revokes automation not yet handled; returns 1 when the pass found nothing new.
run_pass() {
	local at method ua class id found=1
	while IFS=$'\t' read -r at method ua class id; do
		[ -z "${SEEN[$id]+x}" ] || continue
		SEEN[$id]=1
		case "$class" in
		self) SELF_ID="$id"; continue ;;
		keep) KEPT=$((KEPT + 1)) ;;
		automation) AUTOMATION=$((AUTOMATION + 1)); found=0 ;;
		esac
		printf '%s  %-8s %-10s %s\n' "$at" "$method" "$class" "$ua"
		[ "$class" = automation ] && [ "$APPLY" = 1 ] && revoke "$id"
	done <"$WORK/rows"
	return "$found"
}

main() {
	parse_args "$@"
	WORK="$(mktemp -d)"
	trap 'rm -rf "$WORK"' EXIT
	sign_in
	local pass
	for pass in 1 2 3 4 5 6 7 8 9 10; do
		list_sessions || break
		run_pass || break
		[ "$APPLY" = 1 ] || break
	done
	[ -n "$SELF_ID" ] && revoke "$SELF_ID"
	echo "mode=$([ "$APPLY" = 1 ] && echo apply || echo dry) automation=$AUTOMATION kept=$KEPT revoked=$REVOKED failed=$FAILED passes=$pass"
	[ "$FAILED" -eq 0 ]
}

main "$@"
