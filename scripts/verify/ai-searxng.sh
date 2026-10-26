#!/bin/sh
# ai-searxng.sh — W5: the assistant's SearXNG is pinned, unpublished, reachable
# only from osionos-ai, and allowed to ask only the engines on the allowlist.
#
# Static (default): renders base compose with every profile (no container of the
# stack starts) and asserts on the JSON, then parses infrastructure/searxng/
# settings.yml with the PINNED SearXNG image's own python+PyYAML (digest-pinned,
# so the parser is as reproducible as the service; needs docker, no host PyYAML).
# --live: starts only osionos-ai-searxng in a throwaway project, queries it from
# the internal net, checks the default bridge cannot reach it, then `down -v`.
#
# Caveat: static mode proves the RENDERED config and the settings FILE, not that
# SearXNG honours them. --live proves one query from this host: results depend on
# the engines not rate-limiting this IP (brave/duckduckgo often do), so a live
# run with zero hits is SKIP, never PASS; it does not prove the engine
# allowlist is the one SearXNG loaded, and "unreachable from the bridge" is one
# probe from one container, not a scan. Nothing here covers the osionos-ai code
# that calls SearXNG, or SSRF through result URLs.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

SERVICE=osionos-ai-searxng
SETTINGS=infrastructure/searxng/settings.yml
UPSTREAM_DEFAULT_SECRET=ultrasecretkey
ENGINES='["bing","brave","duckduckgo","github","stackoverflow","wikipedia"]'
PYTHON=/usr/local/searxng/.venv/bin/python

mode=static
[ "${1:-}" = "--live" ] && mode=live

status=0
n=0
fail() {
	echo "FAIL: $1"
	status=1
}
check() { # check <label> <jq expression that prints true>
	n=$((n + 1))
	[ "$(printf '%s' "$json" | jq -r "$2")" = "true" ] || fail "$1"
}

json=$(timeout 120 docker compose -f docker-compose.yml --env-file /dev/null --profile '*' config --format json)
svc=".services[\"$SERVICE\"]"
IMAGE=$(printf '%s' "$json" | jq -r "$svc.image")

static_compose() {
	check "$SERVICE is rendered" "$svc != null"
	check "$SERVICE image is pinned by digest" "$svc.image | test(\"@sha256:[0-9a-f]{64}\$\")"
	check "$SERVICE is in profile ai" "$svc.profiles | index(\"ai\") != null"
	check "$SERVICE publishes no port" "($svc.ports // []) | length == 0"
	check "$SERVICE exposes only 8080" "[$svc.expose[]] == [\"8080\"]"
	check "$SERVICE joins exactly search-net and search-egress" \
		"($svc.networks | keys) == [\"osionos-ai-search-egress\",\"osionos-ai-search-net\"]"
	check "osionos-ai-search-net is internal" ".networks[\"osionos-ai-search-net\"].internal == true"
	check "osionos-ai-search-egress is not internal" "(.networks[\"osionos-ai-search-egress\"].internal // false) == false"
	check "only osionos-ai and $SERVICE join search-net" \
		"[.services | to_entries[] | select((.value.networks // {}) | has(\"osionos-ai-search-net\")) | .key] | sort == [\"osionos-ai\",\"$SERVICE\"]"
	check "only $SERVICE joins search-egress" \
		"[.services | to_entries[] | select((.value.networks // {}) | has(\"osionos-ai-search-egress\")) | .key] == [\"$SERVICE\"]"
	check "SEARXNG_SECRET is set (value not shown)" "($svc.environment.SEARXNG_SECRET // \"\") | length > 0"
	check "SEARXNG_SECRET is not the upstream default" "$svc.environment.SEARXNG_SECRET != \"$UPSTREAM_DEFAULT_SECRET\""
	check "settings mount is read-only" \
		"[$svc.volumes[] | select(.target == \"/etc/searxng/settings.yml\")] | length == 1 and all(.[]; .read_only == true and (.source | endswith(\"$SETTINGS\")))"
	check "root fs is read-only" "$svc.read_only == true"
	check "all capabilities dropped" "$svc.cap_drop == [\"ALL\"]"
	check "has a healthcheck" "$svc.healthcheck.test != null"
	check "has a memory limit" "($svc.mem_limit | tonumber) > 0"
	check "has a cpu limit" "($svc.cpus | tonumber) > 0"
	check "osionos-ai points at SearXNG" ".services[\"osionos-ai\"].environment.OSIONOS_AI_SEARXNG_URL == \"http://$SERVICE:8080\""
	check "osionos-ai web flag is off by default" ".services[\"osionos-ai\"].environment.OSIONOS_AI_WEB == \"\""
}

static_settings() {
	[ -f "$SETTINGS" ] || { fail "$SETTINGS missing"; return; }
	out=$(timeout 120 docker run --rm --network none --entrypoint "$PYTHON" \
		-v "$REPO/$SETTINGS:/s.yml:ro" "$IMAGE" -I -c '
import json, yaml
d = yaml.safe_load(open("/s.yml"))
print(json.dumps({
  "engines": sorted(d["use_default_settings"]["engines"]["keep_only"]),
  "only_keep_only": list(d["use_default_settings"]["engines"].keys()) == ["keep_only"],
  "no_engines_override": "engines" not in d,
  "safe": d["search"]["safe_search"],
  "formats": d["search"]["formats"],
  "image_proxy": d["server"]["image_proxy"],
  "limiter": d["server"]["limiter"],
  "public": d["server"]["public_instance"],
  "secret": d["server"]["secret_key"],
}))') || { fail "settings.yml does not parse"; return; }
	json=$out
	check "engine allowlist is exactly $ENGINES" ".engines == $ENGINES"
	check "keep_only is the only engine filter" ".only_keep_only and .no_engines_override"
	check "safe_search is 1" ".safe == 1"
	check "formats are html and json" ".formats | sort == [\"html\",\"json\"]"
	check "image_proxy is false" ".image_proxy == false"
	check "limiter is false" ".limiter == false"
	check "public_instance is false" ".public == false"
	check "secret_key is not the upstream default" ".secret != \"$UPSTREAM_DEFAULT_SECRET\" and (.secret | length) > 0"
}

live() {
	if ! timeout 10 docker run --rm --network bridge --entrypoint wget "$IMAGE" -q -T 6 -O /dev/null https://en.wikipedia.org/ >/dev/null 2>&1; then
		echo "SKIP live: no internet egress from a bridge container, so a query cannot prove egress"
		return 2
	fi
	proj="searxng-verify-$$"
	net="${proj}_osionos-ai-search-net"
	trap 'timeout 120 docker compose -p "$proj" -f docker-compose.yml --env-file /dev/null --profile ai down -v --remove-orphans >/dev/null 2>&1 || true' EXIT
	timeout 300 docker compose -p "$proj" -f docker-compose.yml --env-file /dev/null --profile ai \
		up -d --no-deps --wait --wait-timeout 90 "$SERVICE" >/dev/null || { fail "$SERVICE did not become healthy"; return 1; }

	# The searxng image is the throwaway client: it is already pulled and ships wget.
	body=$(timeout 60 docker run --rm --network "$net" --entrypoint wget "$IMAGE" -q -T 40 -S -O - \
		"http://$SERVICE:8080/search?q=linux+kernel&format=json" 2>&1) || { fail "query from the search net failed"; return 1; }
	hdr=$(printf '%s' "$body" | sed -n '/^  HTTP\//p;/Content-Type/Ip' | tr -d '\r')
	json=$(printf '%s' "$body" | sed -n '/^{/,$p')
	echo "  $(printf '%s' "$hdr" | tr '\n' ' ')"
	n=$((n + 1)); printf '%s' "$hdr" | grep -q 'HTTP/1.[01] 200' || fail "HTTP status is not 200"
	n=$((n + 1)); printf '%s' "$hdr" | grep -qi 'application/json' || fail "content-type is not application/json"
	check "response has a results array" '.results | type == "array"'
	hits=$(printf '%s' "$json" | jq -r '(.results | length) + (.infoboxes | length) + (.answers | length)')
	echo "  hits=$hits unresponsive=$(printf '%s' "$json" | jq -c '[.unresponsive_engines[][0]]')"

	ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "${proj}-${SERVICE}-1")
	n=$((n + 1))
	if timeout 20 docker run --rm --network bridge --entrypoint wget "$IMAGE" -q -T 5 -O /dev/null "http://$ip:8080/healthz" >/dev/null 2>&1; then
		fail "searxng IS reachable from the default bridge by IP"
	fi
	n=$((n + 1))
	if timeout 20 docker run --rm --network bridge --entrypoint wget "$IMAGE" -q -T 5 -O /dev/null "http://$SERVICE:8080/healthz" >/dev/null 2>&1; then
		fail "searxng IS reachable from the default bridge by name"
	fi
	[ "$hits" -gt 0 ] || { echo "SKIP live egress: HTTP/JSON shape ok but every engine returned nothing (rate-limited or blocked)"; return 2; }
	return 0
}

if [ "$mode" = static ]; then
	static_compose
	static_settings
else
	rc=0
	live || rc=$?
	if [ "$status" -eq 0 ] && [ "$rc" -eq 2 ]; then echo "SKIP live ($n checks ran, egress not proven)"; exit 0; fi
fi

if [ "$status" -eq 0 ]; then echo "PASS $n checks ($mode)"; else echo "FAIL: see above ($n checks)"; fi
exit "$status"
