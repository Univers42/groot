#!/bin/sh
# ai-public-flags-off.sh — release R-C4..R-C6, R-C5, R-C11: the public overlay
# starts only the six AI services, forces every public-risky flag off, caps
# memory, publishes no port and never points at the dev osionos-ai-db.
#
# Renders the compose config (no container starts) with every flag exported as
# "on", base + public overlay + the `ai` and `dev` profiles (dev renders the app bundle), and
# asserts on the JSON.
# The variables the overlay requires get throwaway values.
# Caveat: it proves the RENDERED config, not the code: only the names it exports
# (OSIONOS_AI_PAT, _IMAGES, _STT_URL, _MCP_CLIENT, _WEB, the bridge's OSIONOS_MODERATION_ACTIONS) are
# covered; a flag the code reads under another name is not.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

json=$(
	OSIONOS_AI_IMAGES=on OSIONOS_AI_PAT=on OSIONOS_AI_BUILDERS=on OSIONOS_AI_MCP_CLIENT=on OSIONOS_AI_WEB=on OSIONOS_AI_SUMMARY=on OSIONOS_AI_RESEARCH=on OSIONOS_AI_STT_URL=https://x OSIONOS_AI_VLM_URL=https://vlm.invalid \
	OSIONOS_MODERATION_ACTIONS=hold \
	PUBLIC_ORIGIN=https://verify.invalid \
	AUTH_LINK_SIGNING_KEY=verify-only \
	AUTH_TRUSTED_PROXY_HOPS=1 \
	OSIONOS_ADMIN_EMAILS=none \
	OSIONOS_AI_PUBLIC_DATABASE_URL=postgres://osionos_ai@mini-baas-postgres:5432/db \
	OSML_PUBLIC_DATABASE_URL=postgres://osml_job@mini-baas-postgres:5432/db \
	OSIONOS_AI_PUBLIC_UPSTREAM_API_KEY=verify-only OSIONOS_AI_PUBLIC_KEK=verify-only \
	OSIONOS_AI_PUBLIC_PLATFORM_MODELS='[{"id":"m:free","label":"m","inputMicroUsdPerMTok":0,"outputMicroUsdPerMTok":0,"default":true}]' \
	OSIONOS_AI_PUBLIC_USER_DAILY_MICROUSD=1 OSIONOS_AI_PUBLIC_PLATFORM_DAILY_MICROUSD=1 \
	docker compose -f docker-compose.yml -f docker-compose.public.yml --env-file /dev/null \
		--profile ai --profile dev config --format json
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
check "osionos-ai OSIONOS_AI_BUILDERS is empty" "$svc.environment.OSIONOS_AI_BUILDERS == \"\""
check "osionos-ai OSIONOS_AI_PAT is empty" "$svc.environment.OSIONOS_AI_PAT == \"\""
check "osionos-ai OSIONOS_AI_STT_URL is empty" "$svc.environment.OSIONOS_AI_STT_URL == \"\""
check "osionos-ai OSIONOS_AI_VLM_URL is empty" "$svc.environment.OSIONOS_AI_VLM_URL == \"\""
check "osionos-ai OSIONOS_AI_MCP_CLIENT is empty" "$svc.environment.OSIONOS_AI_MCP_CLIENT == \"\""
check "osionos-ai OSIONOS_AI_WEB is empty" "$svc.environment.OSIONOS_AI_WEB == \"\""
check "osionos-ai OSIONOS_AI_SUMMARY is empty" "$svc.environment.OSIONOS_AI_SUMMARY == \"\""
check "osionos-ai OSIONOS_AI_RESEARCH is empty" "$svc.environment.OSIONOS_AI_RESEARCH == \"\""
check "osionos-bridge OSIONOS_MODERATION_ACTIONS is log" ".services[\"osionos-bridge\"].environment.OSIONOS_MODERATION_ACTIONS == \"log\""
check "osionos-ai OSIONOS_ALLOWED_ORIGIN is the app origin" "$svc.environment.OSIONOS_ALLOWED_ORIGIN == \"https://verify.invalid:8443\""
check "osionos-ai upstream is OpenRouter" "$svc.environment.OSIONOS_AI_UPSTREAM_BASE_URL == \"https://openrouter.ai/api/v1\""
check "osionos-ai publishes no port" "($svc.ports // []) | length == 0"
check "osionos-app bundle points the assistant at the proxy" ".services[\"osionos-app\"].build.args.VITE_AI_URL == \"https://verify.invalid:10000\""

for s in osionos-ai osionos-ai-redis osionos-ai-embed osionos-ai-embed-bulk osionos-ai-indexer osionos-ml-job; do
	check "$s is rendered" ".services[\"$s\"] != null"
	check "$s has a memory limit" "(.services[\"$s\"].mem_limit // 0 | tonumber? // 0) > 0"
done
for s in osionos-ai-db osionos-ai-llm osionos-ai-stt osionos-ai-sd osionos-ai-guard osionos-ai-vlm osionos-ai-tox osionos-ai-sentiment osionos-ai-jobs osionos-ai-searxng; do
	check "$s is NOT rendered" ".services[\"$s\"] == null"
done

for s in osionos-ai osionos-ai-indexer; do
	check "$s database URL is not osionos-ai-db" ".services[\"$s\"].environment.OSIONOS_AI_DATABASE_URL | contains(\"osionos-ai-db\") | not"
	check "$s joins mini-baas" ".services[\"$s\"].networks | has(\"mini-baas\")"
	check "$s depends on nothing outside the six" "[(.services[\"$s\"].depends_on // {}) | keys[] | select(. == \"osionos-ai-db\" or . == \"osionos-ai-llm\" or . == \"osionos-ai-stt\")] | length == 0"
done

check "osionos-ml-job database URL is the public one" ".services[\"osionos-ml-job\"].environment.DATABASE_URL == \"postgres://osml_job@mini-baas-postgres:5432/db\""
check "osionos-ml-job sends no dev password" ".services[\"osionos-ml-job\"].environment.PGPASSWORD == \"\""
check "osionos-ml-job waits on no dev database" "(.services[\"osionos-ml-job\"].depends_on // {}) | length == 0"
check "osionos-ml-job publishes no port" "(.services[\"osionos-ml-job\"].ports // []) | length == 0"

for s in osionos-bridge osionos-ai osionos-ai-indexer osionos-ml-job; do
	check "$s runs a :public image" ".services[\"$s\"].image | endswith(\":public\")"
done

if [ "$status" -eq 0 ]; then echo "PASS $n checks"; else echo "FAIL: see above ($n checks)"; fi
exit "$status"
