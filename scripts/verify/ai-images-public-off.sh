#!/bin/sh
# ai-images-public-off.sh — devil C70: the public overlay keeps the image
# generation of osionos-ai off, whatever the environment says.
#
# Renders the compose config (no container starts) with OSIONOS_AI_IMAGES=on in
# the environment: the base file alone must carry it (the control — proves the
# check can see the variable), and base + public overlay must render it empty.
# The variables the public overlay requires get throwaway values.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

imagesFlag() {
	OSIONOS_AI_IMAGES=on \
	PUBLIC_ORIGIN=https://verify.invalid \
	AUTH_LINK_SIGNING_KEY=verify-only \
	AUTH_TRUSTED_PROXY_HOPS=1 \
	OSIONOS_ADMIN_EMAILS=none \
	OSIONOS_AI_PUBLIC_DATABASE_URL=postgres://verify@mini-baas-postgres:5432/db \
	OSIONOS_AI_PUBLIC_UPSTREAM_API_KEY=verify-only OSIONOS_AI_PUBLIC_KEK=verify-only \
	OSIONOS_AI_PUBLIC_PLATFORM_MODELS='[{"id":"m:free","label":"m","inputMicroUsdPerMTok":0,"outputMicroUsdPerMTok":0,"default":true}]' \
	OSIONOS_AI_PUBLIC_USER_DAILY_MICROUSD=1 OSIONOS_AI_PUBLIC_PLATFORM_DAILY_MICROUSD=1 \
	docker compose "$@" --env-file /dev/null --profile ai config --format json |
		python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["osionos-ai"]["environment"].get("OSIONOS_AI_IMAGES", "<unset>"))'
}

base=$(imagesFlag -f docker-compose.yml)
public=$(imagesFlag -f docker-compose.yml -f docker-compose.public.yml)
status=0
if [ "$base" = "on" ]; then echo "PASS control: the base file passes OSIONOS_AI_IMAGES=on through"; else echo "FAIL control: base renders '$base', not 'on'"; status=1; fi
if [ "$public" = "" ]; then echo "PASS public: OSIONOS_AI_IMAGES is empty under the public overlay"; else echo "FAIL public: OSIONOS_AI_IMAGES renders '$public'"; status=1; fi
exit "$status"
