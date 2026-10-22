#!/bin/sh
# ai-public-flags-off.sh — release R-C4..R-C6, R-C5, R-C11: the public overlay
# starts only the five AI services, forces every public-risky flag off, caps
# memory, publishes no port and never points at the dev osionos-ai-db.
#
# Renders the compose config (no container starts) with every flag exported as
# "on", base + public overlay + the `ai` profile, and asserts on the JSON.
# The variables the overlay requires get throwaway values.
# Caveat: it proves the RENDERED config, not the code: only the names it exports
# (OSIONOS_AI_PAT, _IMAGES, _STT_URL, the bridge's OSIONOS_MODERATION_ACTIONS) are
# covered; a flag the code reads under another name is not.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

json=$(
	OSIONOS_AI_IMAGES=on OSIONOS_AI_PAT=on OSIONOS_AI_STT_URL=http://x \
	OSIONOS_MODERATION_ACTIONS=hold \
	PUBLIC_ORIGIN=https://verify.invalid \
	AUTH_LINK_SIGNING_KEY=verify-only \
	AUTH_TRUSTED_PROXY_HOPS=1 \
	OSIONOS_ADMIN_EMAILS=none \
	OSIONOS_AI_PUBLIC_DATABASE_URL=postgres://osionos_ai:verify@mini-baas-postgres:5432/db \
	docker compose -f docker-compose.yml -f docker-compose.public.yml --env-file /dev/null \
		--profile ai config --format json
)

n=0
status=0
check() { # check <label> <jq expression that prints true>
	n=$((n + 1))
	if [ "$(printf '%s' "$json" | jq -r "$2")" = "true" ]; then
		:
	else
		echo "FAIL: $1"
		status=1
	fi
}

svc='.services["osionos-ai"]'
check "osionos-ai OSIONOS_AI_IMAGES is empty" "$svc.environment.OSIONOS_AI_IMAGES == \"\""
check "osionos-ai OSIONOS_AI_PAT is empty" "$svc.environment.OSIONOS_AI_PAT == \"\""
check "osionos-ai OSIONOS_AI_STT_URL is empty" "$svc.environment.OSIONOS_AI_STT_URL == \"\""
check "osionos-bridge OSIONOS_MODERATION_ACTIONS is log" ".services[\"osionos-bridge\"].environment.OSIONOS_MODERATION_ACTIONS == \"log\""
check "osionos-ai OSIONOS_ALLOWED_ORIGIN is the app origin" "$svc.environment.OSIONOS_ALLOWED_ORIGIN == \"https://verify.invalid:8443\""
check "osionos-ai publishes no port" "($svc.ports // []) | length == 0"

for s in osionos-ai osionos-ai-redis osionos-ai-embed osionos-ai-embed-bulk osionos-ai-indexer; do
	check "$s is rendered" ".services[\"$s\"] != null"
	check "$s has a memory limit" "(.services[\"$s\"].mem_limit // 0 | tonumber? // 0) > 0"
done
for s in osionos-ai-db osionos-ai-llm osionos-ai-stt osionos-ai-sd osionos-ai-guard; do
	check "$s is NOT rendered" ".services[\"$s\"] == null"
done

for s in osionos-ai osionos-ai-indexer; do
	check "$s database URL is not osionos-ai-db" ".services[\"$s\"].environment.OSIONOS_AI_DATABASE_URL | contains(\"osionos-ai-db\") | not"
	check "$s joins mini-baas" ".services[\"$s\"].networks | has(\"mini-baas\")"
	check "$s depends on nothing outside the five" "[(.services[\"$s\"].depends_on // {}) | keys[] | select(. == \"osionos-ai-db\" or . == \"osionos-ai-llm\" or . == \"osionos-ai-stt\")] | length == 0"
done

if [ "$status" -eq 0 ]; then echo "PASS $n checks"; else echo "FAIL: see above ($n checks)"; fi
exit "$status"
