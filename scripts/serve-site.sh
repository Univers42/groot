#!/usr/bin/env bash
# serve-site.sh — serve a built site (apps/opposite-osiris/dist) the way production does: the site
# image's own nginx template (headers, gzip, cache policy, 404 page) behind a TLS listener, like the
# edge proxy. It measures a build without touching the shared stack's :4322, for the site-only
# specs (tests/e2e/site.config.ts) and scripts/site-audit.sh.
#
#   scripts/serve-site.sh start [port]   # https://127.0.0.1:<port>, default 4390
#   scripts/serve-site.sh stop [port]
#   SERVE_SITE_DIST=<dir> scripts/serve-site.sh start   # another build or a fixture (tests/site-nginx)
#
# The container is groot-serve-site-<port>; nginx's own listener (:8080, plain HTTP) is reachable
# through `docker exec`, the TLS one (:8443) is published on 127.0.0.1:<port>.
#
# TLS uses the seat's local-CA certificate (apps/grobase/certs/localhost.pem, 127.0.0.1 in its
# SANs), so a browser that trusts the CA verifies it, as the site specs do (tests/e2e/run.sh
# mounts the CA). Caveat: a seat without that certificate gets a self-signed one, which only
# clients that skip verification accept (Lighthouse's --ignore-certificate-errors); st* specs
# then fail on trust, not on the site.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/docker-run.sh
. "$REPO/scripts/lib/docker-run.sh"
cd "$REPO"
action="${1:?usage: scripts/serve-site.sh start|stop [port]}"
port="${2:-4390}"
name="groot-serve-site-$port"
site="apps/opposite-osiris"
state="tests/e2e/test-results/.serve-site-$port"

stop() { docker rm -f "$name" >/dev/null 2>&1 || true; }

start() {
	dist="${SERVE_SITE_DIST:-$site/dist}"
	[[ -f "$dist/index.html" ]] || { echo "no build at $dist: run astro build first" >&2; exit 2; }
	dist="$(cd "$dist" && pwd)"
	image="$(awk '/^FROM .*nginx.* AS runtime/ {print $2}' "$site/docker/services/web/Dockerfile")"
	stop
	rm -rf "$state" && mkdir -p "$state"
	local certs cert key
	certs="$(dirname "$(local_ca_file "$REPO" 2>/dev/null || echo /nonexistent/ca)")"
	cert="$certs/localhost.pem" key="$certs/localhost-key.pem"
	if [[ ! -r "$cert" || ! -r "$key" ]]; then
		echo "[serve-site] no local-CA certificate under $certs: self-signed, untrusted by browsers" >&2
		cert="$REPO/$state/cert.pem" key="$REPO/$state/key.pem"
		scripts/tools.sh openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
			-addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
			-keyout "$state/key.pem" -out "$state/cert.pem" </dev/null 2>/dev/null
	fi
	cat >"$state/tls.conf" <<'CONF'
server {
    listen 8443 ssl;
    ssl_certificate /tls/cert.pem;
    ssl_certificate_key /tls/key.pem;
    location / {
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
}
CONF
	chmod -R a+rX "$state"
	docker run -d --rm --name "$name" -p "127.0.0.1:$port:8443" \
		-e OO_AUTH_UPSTREAM=http://127.0.0.1:9 -e OO_BAAS_UPSTREAM=http://127.0.0.1:9 -e OO_RESOLVER=127.0.0.11 \
		-e NGINX_ENVSUBST_FILTER='^OO_' -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/conf.d \
		-v "$REPO/$site/docker/services/web/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
		-v "$REPO/$state/tls.conf:/etc/nginx/conf.d/tls.conf:ro" -v "$cert:/tls/cert.pem:ro" -v "$key:/tls/key.pem:ro" \
		-v "$dist:/usr/share/nginx/html:ro" "$image" >/dev/null
	for _ in $(seq 50); do
		docker exec "$name" curl -sfk -o /dev/null https://127.0.0.1:8443/ && { echo "https://127.0.0.1:$port"; return 0; }
		sleep 0.2
	done
	docker logs "$name" >&2
	exit 1
}

case "$action" in
start) start ;;
stop) stop ;;
*) echo "unknown action: $action (start|stop)" >&2; exit 2 ;;
esac
