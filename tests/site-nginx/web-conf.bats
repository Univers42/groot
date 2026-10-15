#!/usr/bin/env bats
# The site image's nginx template (apps/opposite-osiris/docker/services/web/default.conf.template)
# on the real nginx base image, against a fixture site: every response keeps the security
# headers, fingerprinted assets are immutable, and a missing page gets the site's own 404.
# Needs a Docker daemon, so it lives outside scripts/tests (whose CI job has none).
#
# Run (bats in a container, talking to this machine's daemon; the repo at its own path because
# the fixture is bind-mounted by host path):
#   docker run --rm -v "$PWD:$PWD" -w "$PWD" -e DOCKER_HOST=unix:///docker.sock \
#     -v "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock:/docker.sock" --entrypoint sh \
#     bats/bats:1.11.1 -c 'apk add -q --no-cache bash coreutils docker-cli && bats tests/site-nginx'
# On a rootful daemon, mount /var/run/docker.sock instead.

bats_require_minimum_version 1.5.0

setup_file() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  dockerfile="$ROOT/apps/opposite-osiris/docker/services/web/Dockerfile"
  IMAGE="$(awk '/^FROM .*nginx.* AS runtime/ {print $2}' "$dockerfile")"
  [[ -n "$IMAGE" ]] || { echo "no nginx runtime stage in $dockerfile" >&2; return 1; }
  SITE="$(mktemp -d "$ROOT/tests/site-nginx/.tmp.XXXXXX")"
  mkdir -p "$SITE/_astro" "$SITE/fonts" "$SITE/legal"
  echo '<p>home</p>' >"$SITE/index.html"
  echo '<p>site-404-page</p>' >"$SITE/404.html"
  echo '<p>legal</p>' >"$SITE/legal/index.html"
  echo 'console.log(1)' >"$SITE/_astro/app.js"
  echo 'font' >"$SITE/fonts/face.woff2"
  chmod -R a+rX "$SITE"
  CONTAINER="$(docker run -d --rm \
    -e OO_AUTH_UPSTREAM=http://127.0.0.1:9 -e OO_BAAS_UPSTREAM=http://127.0.0.1:9 -e OO_RESOLVER=127.0.0.11 \
    -e NGINX_ENVSUBST_FILTER='^OO_' -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/conf.d \
    -v "$ROOT/apps/opposite-osiris/docker/services/web/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
    -v "$SITE:/usr/share/nginx/html:ro" "$IMAGE")"
  export ROOT SITE CONTAINER
  for _ in $(seq 50); do
    docker exec "$CONTAINER" curl -sf -o /dev/null http://127.0.0.1:8080/ && return 0
    sleep 0.2
  done
  docker logs "$CONTAINER" >&2
  return 1
}

teardown_file() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$SITE"
}

# Prints the status line, the headers and the body of one request from inside the container
# (curl -i: busybox wget prints no body for an error status).
fetch() {
  docker exec "$CONTAINER" curl -s -i "http://127.0.0.1:8080$1" | tr -d '\r'
}

has_security_headers() {
  grep -qi '^Strict-Transport-Security: max-age=' <<<"$1" &&
    grep -qi '^X-Content-Type-Options: nosniff' <<<"$1" &&
    grep -qi '^X-Frame-Options: DENY' <<<"$1" &&
    grep -qi "^Content-Security-Policy: frame-ancestors 'none'" <<<"$1" &&
    grep -qi '^Referrer-Policy: ' <<<"$1" &&
    grep -qi '^Permissions-Policy: ' <<<"$1"
}

@test "a page answers with the security headers and revalidates" {
  out="$(fetch /legal/)"
  grep -q '^HTTP/1.1 200' <<<"$out"
  has_security_headers "$out"
  grep -qi '^Cache-Control: no-cache' <<<"$out"
}

@test "fingerprinted scripts keep the security headers and are cached for good" {
  out="$(fetch /_astro/app.js)"
  grep -q '^HTTP/1.1 200' <<<"$out"
  has_security_headers "$out"
  grep -qi '^Cache-Control: public, max-age=31536000, immutable' <<<"$out"
}

@test "fonts keep the security headers and are cached for good" {
  out="$(fetch /fonts/face.woff2)"
  grep -q '^HTTP/1.1 200' <<<"$out"
  has_security_headers "$out"
  grep -qi '^Cache-Control: public, max-age=31536000, immutable' <<<"$out"
}

@test "a missing page answers 404 with the site's own 404 page and its headers" {
  out="$(fetch /no/such/page)"
  grep -q '^HTTP/1.1 404' <<<"$out"
  grep -q 'site-404-page' <<<"$out"
  has_security_headers "$out"
}

@test "the Permissions-Policy names no token browsers reject (web-share)" {
  out="$(fetch /)"
  grep -qi '^Permissions-Policy: ' <<<"$out"
  run ! grep -qi 'web-share' <<<"$out"
}
