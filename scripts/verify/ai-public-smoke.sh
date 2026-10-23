#!/bin/sh
# ai-public-smoke.sh <bridge-base-url> <app-base-url> — release R-C12: the live
# smoke of the public AI surface, run by the operator after the cutover.
#
# Read-only: it creates no account. The checks that need a logged-in session
# (assistant answer with a citation, a second account's 404 on the first one's
# conversation, beacon/moderation/index catch-up) are printed as SKIP, never as
# PASS: no login helper in scripts/ is reusable without a real mailbox, and a
# throwaway-* account flow is not faked here.
# Caveat: the 429 check is a burst from ONE client; if the Funnel hop does not
# append X-Forwarded-For the burst still trips (shared bucket) and the check
# cannot tell per-client from global — R-C9's second-client 200 is manual.
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <bridge-base-url> <app-base-url>" >&2; exit 2; }
BRIDGE="${1%/}"
APP="${2%/}"
status=0

code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null || true; }
expect() { # expect <label> <wanted> <got>
	if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (wanted $2, got $3)"; status=1; fi
}

expect "GET /api/ai/health is 200" 200 "$(code "$BRIDGE/api/ai/health")"
expect "GET /api/ai/access-tokens is 404" 404 "$(code "$BRIDGE/api/ai/access-tokens")"
expect "POST /api/ai/access-tokens is 404" 404 "$(code -X POST -H 'content-type: application/json' -d '{}' "$BRIDGE/api/ai/access-tokens")"
expect "POST /api/ai/images is 404 (images off)" 404 "$(code -X POST -H 'content-type: application/json' -d '{}' "$BRIDGE/api/ai/images")"

hdrs=$(curl -s -o /dev/null -m 10 -D - -H 'Origin: https://evil.example' "$BRIDGE/api/ai/health" 2>/dev/null || true)
acao=$(printf '%s' "$hdrs" | grep -i '^access-control-allow-origin:' || true)
if [ -z "$hdrs" ]; then echo "FAIL foreign Origin check: no response"; status=1
# The service answers one fixed allowed origin, as the bridge does; a browser on any other origin
# then refuses the response. Only an echo of the foreign origin, or *, would let it read.
elif [ -z "$acao" ]; then echo "PASS foreign Origin gets no access-control-allow-origin"
elif printf '%s' "$acao" | grep -qiE 'evil\.example|\*'; then echo "FAIL foreign Origin is allowed: $acao"; status=1
else echo "PASS foreign Origin is not allowed (fixed $(printf '%s' "$acao" | tr -d '\r'))"; fi

# A burst of 30 within the burst window: the zone allows 2 r/s + burst 10.
n429=0
i=0
while [ "$i" -lt 30 ]; do
	[ "$(code "$BRIDGE/api/ai/health")" = 429 ] && n429=$((n429 + 1))
	i=$((i + 1))
done
if [ "$n429" -ge 1 ]; then echo "PASS burst of 30 got $n429 x 429"; else echo "FAIL burst of 30 got no 429"; status=1; fi

expect "app $APP answers 200" 200 "$(code "$APP/")"

for c in "assistant answers with a citation" "second account gets 404 on the first one's conversation" \
	"moderation does not delete or hide user content" "a beacon without consent writes 0 ai_events rows" \
	"the index catches up on an edit"; do
	echo "SKIP $c: needs a session (manual)"
done
exit "$status"
