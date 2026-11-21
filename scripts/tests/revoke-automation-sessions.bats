#!/usr/bin/env bats
# Automation that signs in to a shared account leaves a live session per run; the owner then
# reads a sessions list full of unknown sign-ins. scripts/revoke-automation-sessions.sh signs
# those out through the product route (DELETE /api/account/sessions/:id), never the
# sign-out-everywhere logout, and always revokes its own sign-in. curl is a stub that answers
# as the bridge would and records every call.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache jq && bats scripts/tests/revoke-automation-sessions.bats'

bats_require_minimum_version 1.5.0

FF_UBUNTU='Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:158.0) Gecko/20100101 Firefox/158.0'
FF_PLAYWRIGHT='Mozilla/5.0 (X11; Linux x86_64; rv:158.0) Gecko/20100101 Firefox/158.0'
HEADLESS='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/131.0.6778.33 Safari/537.36'
CHROME='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36'
ELECTRON='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) osionos/0.5.4 Chrome/152.0.7977.167 Electron/44.8.0 Safari/537.36'

row() { jq -n --arg id "$1" --arg at "$2" --arg ua "$3" --argjson cur "${4:-false}" \
	'{id: $id, createdAt: $at, authMethod: "password", userAgent: $ua, current: $cur}'; }

fixture() {
	{
		row 00000000-0000-4000-8000-000000000001 2026-11-16T15:17:00Z 'curl/8.5.0'
		row 00000000-0000-4000-8000-000000000002 2026-11-16T16:04:00Z "$HEADLESS"
		row 00000000-0000-4000-8000-000000000003 2026-11-18T12:27:00Z "$FF_PLAYWRIGHT"
		row 00000000-0000-4000-8000-000000000004 2026-11-20T18:08:00Z "$FF_UBUNTU"
		row 00000000-0000-4000-8000-000000000005 2026-11-06T14:29:00Z "$CHROME"
		row 00000000-0000-4000-8000-000000000006 2026-11-20T10:00:00Z "$ELECTRON"
		row 00000000-0000-4000-8000-000000000007 2026-11-20T23:34:00Z "$ELECTRON"
		row 00000000-0000-4000-8000-000000000008 2026-11-20T23:40:00Z 'curl/8.5.0' true
	} | jq -s '{sessions: .}'
}

classify() { fixture | jq -r --arg since "${1:-}" --arg keep "X11; Ubuntu;" -f "$BATS_TEST_DIRNAME/../lib/automation-sessions.jq"; }
class_of() { classify "${2:-}" | awk -F'\t' -v id="$1" '$5 ~ id"$" { print $4 }'; }

setup() {
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	export CALLS="$BATS_TEST_TMPDIR/calls" LIST="$BATS_TEST_TMPDIR/list.json"
	fixture >"$LIST"
	cat >"$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/sh
# Records method + url + argv, answers login / list / delete like the bridge.
echo "$*" >>"$CALLS.argv"
out=/dev/null; method=GET; url=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out="$2"; shift ;;
	-X) method="$2"; shift ;;
	-w|-H|-m|--data-binary) shift ;;
	http*) url="$1" ;;
	esac
	shift
done
echo "$method $url" >>"$CALLS"
case "$method $url" in
*/api/auth/login) printf '{"accessToken":"osionos_v1.stub"}' >"$out"; printf 200 ;;
"GET "*/api/account/sessions) cat "$LIST" ;;
"DELETE "*) printf 204 ;;
esac
STUB
	chmod +x "$BATS_TEST_TMPDIR/bin/curl"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	export SECRET_PW=pw-Sentinel-0123456789
	printf 'DEMO_LOGIN_PASSWORD=%s\n' "$SECRET_PW" >"$BATS_TEST_TMPDIR/env"
	export DEMO_LOGIN_EMAIL=demo@example.com REVOKE_PAUSE_SECONDS=0
}

tool() { run bash "$BATS_TEST_DIRNAME/../revoke-automation-sessions.sh" --api https://bridge.test --env-file "$BATS_TEST_TMPDIR/env" "$@"; }

@test "tool user agents and Playwright Firefox are automation; the owner's Firefox and Chrome are kept" {
	[ "$(class_of 001)" = automation ]
	[ "$(class_of 002)" = automation ]
	[ "$(class_of 003)" = automation ]
	[ "$(class_of 004)" = keep ]
	[ "$(class_of 005)" = keep ]
}

@test "an Electron sign-in is automation only from --since on, so the owner's desktop app survives" {
	[ "$(class_of 006)" = keep ]
	[ "$(class_of 007)" = keep ]
	[ "$(class_of 006 2026-11-20T23:20)" = keep ]
	[ "$(class_of 007 2026-11-20T23:20)" = automation ]
}

@test "the caller's own session is classed self, whatever its user agent" {
	[ "$(class_of 008)" = self ]
}

@test "dry run revokes nothing but its own sign-in" {
	tool
	[ "$status" -eq 0 ]
	[ "$(grep -c '^DELETE ' "$CALLS")" -eq 1 ]
	grep -q '^DELETE .*/api/account/sessions/00000000-0000-4000-8000-000000000008$' "$CALLS"
}

@test "--apply revokes every automation family, then its own, and never the sign-out-everywhere route" {
	tool --apply --since 2026-11-20T23:20
	[ "$status" -eq 0 ]
	for id in 001 002 003 007 008; do grep -q "^DELETE .*-000000000$id\$" "$CALLS"; done
	for id in 004 005 006; do run ! grep -q "^DELETE .*-000000000$id\$" "$CALLS"; done
	run ! grep -q 'bridge/logout' "$CALLS"
	[ "$(tail -1 "$CALLS")" = "DELETE https://bridge.test/api/account/sessions/00000000-0000-4000-8000-000000000008" ]
}

@test "output carries no session id, token or password" {
	tool --apply
	[ "$status" -eq 0 ]
	[[ "$output" != *00000000-0000* ]]
	[[ "$output" != *osionos_v1* ]]
	[[ "$output" != *"$SECRET_PW"* ]]
	[[ "$output" == *"revoked="* ]]
}

@test "the password never reaches an argv" {
	tool --apply
	[ -s "$CALLS.argv" ]
	run ! grep -q "$SECRET_PW" "$CALLS.argv"
}

@test "a missing --api is refused before any sign-in" {
	run bash "$BATS_TEST_DIRNAME/../revoke-automation-sessions.sh" --env-file "$BATS_TEST_TMPDIR/env"
	[ "$status" -eq 2 ]
	[ ! -e "$CALLS" ]
}
