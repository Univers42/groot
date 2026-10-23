#!/bin/sh
# ai-locked-routes-cors.sh — release R-C4: the public edge keeps /api/ai/access-tokens and
# /api/ai/mcp at 404, but the app's own origin can READ the access-tokens 404 (and its preflight),
# so the panel says "off" and not "could not reach the server". MCP gets no CORS at all (C118).
#
# Starts a throwaway nginx (same image as local-https-proxy, --network none, no published port),
# with the repo's nginx.conf and public.d files at the public overlay's paths.
# Stubbed: a self-signed cert generated here for localhost.pem; no upstream exists (the locked
# routes answer from nginx itself, so none is contacted). PUBLIC_ORIGIN=https://example.invalid.
# Caveat: proves the proxy's answers for these two routes only, over HTTPS on :4000 inside the
# container; it does not prove the live Funnel or that a browser accepts the headers.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${AI_EDGE_TEST_IMAGE:-public.ecr.aws/docker/library/nginx:1.27-alpine}"
NAME=ai-edge-test
GOOD=https://example.invalid:8443
TLS="$REPO/infrastructure/tls"
tmp=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

timeout 60 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
	-keyout "$tmp/localhost-key.pem" -out "$tmp/localhost.pem" >/dev/null 2>&1
chmod 644 "$tmp"/*.pem

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$NAME" --network none \
	-e NGINX_ENVSUBST_FILTER=PUBLIC_ -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/track-binocle.d \
	-e PUBLIC_ORIGIN=https://example.invalid -e PUBLIC_MAIL_ORIGIN= -e PUBLIC_CALENDAR_ORIGIN= \
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
		-H "Origin: $3" -H 'Access-Control-Request-Method: GET' "https://127.0.0.1:4000$2" | tr 'A-Z' 'a-z'
}
code() { printf '%s' "$1" | sed -n 's/^code://p'; }
acao() { printf '%s' "$1" | sed -n 's/^access-control-allow-origin: *//p' | tr -d '\r'; }

if docker exec "$NAME" nginx -t >/dev/null 2>&1; then pass "a nginx -t rc 0"; else fail "a nginx -t rc 0"; fi

r=$(req GET /api/ai/access-tokens "$GOOD")
if [ "$(code "$r")" = 404 ] && [ "$(acao "$r")" = "$GOOD" ]; then pass "b GET good origin: 404 + ACAO"; else fail "b GET good origin: 404 + ACAO ($(code "$r") '$(acao "$r")')"; fi

r=$(req OPTIONS /api/ai/access-tokens "$GOOD")
if [ "$(code "$r")" = 204 ] && [ "$(acao "$r")" = "$GOOD" ] \
	&& printf '%s' "$r" | grep -q '^access-control-allow-methods: get, post, delete, options' \
	&& printf '%s' "$r" | grep -q '^access-control-allow-headers: authorization, content-type'; then
	pass "c OPTIONS good origin: 204 + ACAO + methods + headers"
else fail "c OPTIONS good origin: 204 + ACAO + methods + headers ($(code "$r") '$(acao "$r")')"; fi

r=$(req GET /api/ai/access-tokens https://evil.invalid)
if [ "$(code "$r")" = 404 ] && [ -z "$(acao "$r")" ]; then pass "d GET evil origin: 404, no ACAO"; else fail "d GET evil origin: 404, no ACAO ($(code "$r") '$(acao "$r")')"; fi

r=$(req GET /api/ai/access-tokens/abc "$GOOD")
if [ "$(code "$r")" = 404 ] && [ "$(acao "$r")" = "$GOOD" ]; then pass "e sub-path: 404 + ACAO"; else fail "e sub-path: 404 + ACAO ($(code "$r") '$(acao "$r")')"; fi

for m in GET OPTIONS; do
	r=$(req "$m" /api/ai/mcp "$GOOD")
	if [ -z "$(acao "$r")" ] && [ -n "$(code "$r")" ] && [ "$(code "$r")" != 000 ]; then pass "f $m /api/ai/mcp: no ACAO ($(code "$r"))"; else fail "f $m /api/ai/mcp: no ACAO ($(code "$r") '$(acao "$r")')"; fi
done

exit "$status"
