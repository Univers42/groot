#!/bin/sh
# ai-public-providers.sh — FA7, FA8, FC7, R8: the public overlay pins the AI
# provider pool. PUBLIC_MODE is "on", the pool comes only from the public var
# (never a dev OSIONOS_AI_PLATFORM_PROVIDERS), every public provider is keyed,
# and no provider baseUrl points at a compose service (osionos-ai-llm included).
#
# Usage: ai-public-providers.sh              render the compose config and check it
#        ai-public-providers.sh --json FILE  check an already rendered config (tests)
#
# Caveat: it proves the RENDERED config, not the image. The service-name test
# compares the baseUrl's first host label to the compose service names, so an IP
# literal, a network alias or an extra_hosts name that reaches a service slips
# through (under-reporting). The overlay's required vars get throwaway values.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

render() {
	cd "$REPO"
	OSIONOS_AI_PLATFORM_PROVIDERS='[{"id":"env-local-leak","baseUrl":"https://leak.invalid/v1","wire":"openai-compatible","models":[]}]' \
	PUBLIC_ORIGIN=https://verify.invalid AUTH_LINK_SIGNING_KEY=verify-only AUTH_TRUSTED_PROXY_HOPS=1 \
	OSIONOS_ADMIN_EMAILS=none \
	OSIONOS_AI_PUBLIC_MCP_HOST=api.verify.invalid OSIONOS_AI_PUBLIC_DATABASE_URL=postgres://osionos_ai@mini-baas-postgres:5432/db \
	OSML_PUBLIC_DATABASE_URL=postgres://osml_job@mini-baas-postgres:5432/db \
	OSIONOS_AI_PUBLIC_UPSTREAM_API_KEY=verify-only OSIONOS_AI_PUBLIC_KEK=verify-only \
	OSIONOS_AI_PUBLIC_PLATFORM_MODELS='[{"id":"m:free","label":"m","inputMicroUsdPerMTok":0,"outputMicroUsdPerMTok":0,"default":true}]' \
	OSIONOS_AI_PUBLIC_USER_DAILY_MICROUSD=1 OSIONOS_AI_PUBLIC_PLATFORM_DAILY_MICROUSD=1 \
		docker compose -f docker-compose.yml -f docker-compose.public.yml --env-file /dev/null \
		--profile ai --profile dev config --format json
}

if [ "${1:-}" = "--json" ]; then
	json=$(cat "$2")
else
	json=$(render)
fi

n=0
status=0
check() { # check <label> <jq expression that prints true>
	n=$((n + 1))
	if [ "$(printf '%s' "$json" | jq -r "$2")" != "true" ]; then
		echo "FAIL: $1"
		status=1
	fi
}

env='.services["osionos-ai"].environment'
pool="(($env.OSIONOS_AI_PLATFORM_PROVIDERS // \"\") | if . == \"\" then [] else fromjson end)"
host='(.baseUrl | sub("^[a-z]+://"; "") | split("/")[0] | split(":")[0] | split(".")[0])'

check "osionos-ai OSIONOS_AI_PUBLIC_MODE is on" "$env.OSIONOS_AI_PUBLIC_MODE == \"on\""
check "provider pool does not come from the dev OSIONOS_AI_PLATFORM_PROVIDERS" "$pool | all(.[]; .id != \"env-local-leak\")"
check "every public provider names an apiKeyEnv" "$pool | all(.[]; (.apiKeyEnv // \"\") != \"\")"
check "no provider baseUrl names a compose service (FC7)" \
	"(.services | keys) as \$svc | $pool | all(.[]; $host as \$h | (\$svc | index(\$h)) == null)"

[ "$status" -eq 0 ] && echo "ai-public-providers: $n checks passed"
exit "$status"
