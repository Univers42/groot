#!/bin/sh
# ai-locked-routes-cors.sh — release R-C4, as changed by FB4: the public edge no longer answers
# /api/ai/access-tokens and /api/ai/mcp with 404; it proxies them to the AI service and adds no
# CORS header of its own (MCP gets none at all, C118). The :4000 buckets still apply (h-j).
#
# Starts a throwaway nginx (same image as local-https-proxy, --network none, no published port),
# with the repo's nginx.conf and public.d files at the public overlay's paths.
# Stubbed: a self-signed cert generated here for localhost.pem; no upstream exists (a proxied route
# answers 502). PUBLIC_ORIGIN=https://example.invalid.
# Caveat: proves the proxy's answers for these two routes only, over HTTPS on :4000 inside the
# container; it does not prove the live Funnel or that a browser accepts the headers.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${AI_EDGE_TEST_IMAGE:-public.ecr.aws/docker/library/nginx:1.27-alpine}"
NAME=ai-edge-test
GOOD=https://example.invalid:8443
BETA=https://beta.example.invalid
TLS="$REPO/infrastructure/tls"
tmp=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

timeout 60 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
	-keyout "$tmp/localhost-key.pem" -out "$tmp/localhost.pem" >/dev/null 2>&1
chmod 644 "$tmp"/*.pem

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$NAME" --network none \
	-e NGINX_ENVSUBST_FILTER=PUBLIC_ -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/track-binocle.d \
	-e PUBLIC_ORIGIN=https://example.invalid -e PUBLIC_MAIL_ORIGIN= -e PUBLIC_CALENDAR_ORIGIN= -e PUBLIC_EXTRA_FRAME_ANCESTORS= -e PUBLIC_BETA_ORIGIN="$BETA" \
	-v "$TLS/nginx.conf:/etc/nginx/nginx.conf:ro" \
	-v "$tmp:/etc/track-binocle/certs:ro" \
	-v "$TLS/public.d/bridge-public.conf:/etc/nginx/track-binocle.d/bridge-public.conf:ro" \
	-v "$TLS/public.d/http-limits.conf:/etc/nginx/track-binocle.d/http-limits.conf:ro" \
	-v "$TLS/public.d/ai-public.conf:/etc/nginx/track-binocle.d/ai-public.conf:ro" \
	-v "$TLS/public.d/apps.conf.template:/etc/nginx/templates/http-apps.conf.template:ro" \
	-v "$TLS/public.d/http-locked-ai-cors.conf.template:/etc/nginx/templates/http-locked-ai-cors.conf.template:ro" \
	"$IMAGE" >/dev/null

i=0
until docker exec "$NAME" sh -c 'nginx -t >/dev/null 2>&1 && curl -sk -o /dev/null https://127.0.0.1:4000/api/ai/mcp' 2>/dev/null; do
	i=$((i + 1))
	[ "$i" -lt 20 ] || break
	sleep 1
done

status=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; status=1; }

# req <method> <path> <origin> -> "<code>\n<headers lowercased>"
req() {
	docker exec "$NAME" curl -sk -o /dev/null -D - -w 'code:%{http_code}\n' -X "$1" \
		-H "Origin: $3" -H 'Access-Control-Request-Method: GET' "https://127.0.0.1:4000$2" | tr '[:upper:]' '[:lower:]'
}
code() { printf '%s' "$1" | sed -n 's/^code://p'; }
acao() { printf '%s' "$1" | sed -n 's/^access-control-allow-origin: *//p' | tr -d '\r'; }

if docker exec "$NAME" nginx -t >/dev/null 2>&1; then pass "a nginx -t rc 0"; else fail "a nginx -t rc 0"; fi

# b-d: since FB4 the edge no longer answers these routes itself: they are proxied to the AI service
# (no upstream here, so 502), and the edge adds no ACAO of its own (the service owns CORS; MCP has none, C118).
for path in /api/ai/access-tokens /api/ai/access-tokens/abc /api/ai/mcp; do
	for m in GET OPTIONS; do
		r=$(req "$m" "$path" "$GOOD")
		if [ "$(code "$r")" != 404 ] && [ "$(code "$r")" != 000 ] && [ -z "$(acao "$r")" ]; then pass "b $m $path: proxied, no edge ACAO ($(code "$r"))"; else fail "b $m $path: proxied, no edge ACAO ($(code "$r") '$(acao "$r")')"; fi
	done
done

# h/i: the bucket guards the model calls. A read (GET) or a preflight never calls a model, and a
# page load fires more than the burst of them, so they are never refused; a burst of POSTs still is.
# No upstream runs here, so an unrefused request answers 502: only 429 counts as refused.
# In parallel, so the bucket cannot refill between them; --max-time because the upstream name
# never resolves under --network none (a refusal is answered before any lookup).
burst() { docker exec "$NAME" sh -c "for i in \$(seq 1 ${2:-30}); do curl -sk --max-time 3 -o /dev/null -w '%{http_code}\n' -X $1 https://127.0.0.1:4000/api/ai/providers & done; wait" | grep -c '^429$' || true; }
n=$(burst GET); if [ "$n" = 0 ]; then pass "h 30 GETs at once: none refused"; else fail "h 30 GETs at once: $n refused with 429"; fi
n=$(burst OPTIONS); if [ "$n" = 0 ]; then pass "h 30 preflights at once: none refused"; else fail "h 30 preflights at once: $n refused with 429"; fi
n=$(burst POST); if [ "$n" -gt 0 ]; then pass "i 30 POSTs at once: $n refused with 429"; else fail "i 30 POSTs at once: none refused (the bucket is off)"; fi

n=$(burst GET 150); if [ "$n" -gt 0 ]; then pass "j 150 GETs at once: $n refused with 429 (reads still have a bucket)"; else fail "j 150 GETs at once: none refused (reads are unmetered)"; fi

exit "$status"
