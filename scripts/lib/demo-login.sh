#!/bin/sh
# demo-login.sh — the ONE reader of the local demo account's credentials.
#
#   demo_login_password FILE   Print DEMO_LOGIN_PASSWORD from FILE (./.env.local). Unset or
#                              empty is an error on stderr naming the fix, exit 1 — callers
#                              never get an empty password to log in or reset with.
#
# The value is minted per machine by scripts/gen-local-env.sh and applied to the account
# by scripts/demo-login-ensure.sh; it is never committed (the repo is public).
# Sourced by demo-login-ensure.sh, showcase.sh and `make demo-login`; tested in
# scripts/tests/demo-login.bats.

DEMO_LOGIN_EMAIL="${DEMO_LOGIN_EMAIL:-dev.pro.photo@gmail.com}"

demo_login_password() {
	_dl_file="$1"
	_dl_val=""
	[ -f "$_dl_file" ] && _dl_val="$(sed -n 's/^DEMO_LOGIN_PASSWORD=//p' "$_dl_file" | tail -1 |
		sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
	if [ -z "$_dl_val" ]; then
		printf 'DEMO_LOGIN_PASSWORD is not set in %s — run "bash scripts/gen-local-env.sh --sync" (or make all) to mint it.\n' \
			"$_dl_file" >&2
		return 1
	fi
	printf '%s' "$_dl_val"
}
