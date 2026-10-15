#!/usr/bin/env bats
# The site image's nginx template (apps/opposite-osiris/docker/services/web/default.conf.template)
# on the real nginx base image, against a fixture site served by scripts/serve-site.sh: every
# response keeps the security headers, fingerprinted assets are immutable, a missing page gets the
# site's own 404, and the local TLS proxy in front keeps all of it.
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
  PORT=4391
  CONTAINER="groot-serve-site-$PORT"
  export PORT CONTAINER
  SITE="$(mktemp -d "$ROOT/tests/site-nginx/.tmp.XXXXXX")"
  mkdir -p "$SITE/_astro" "$SITE/fonts" "$SITE/legal" "$SITE/auth/confirm" "$SITE/auth/reset-password"
  echo '<p>confirm</p>' >"$SITE/auth/confirm/index.html"
  echo '<p>reset</p>' >"$SITE/auth/reset-password/index.html"
  mkdir -p "$SITE/auth/confirmed-elsewhere" && echo '<p>other</p>' >"$SITE/auth/confirmed-elsewhere/index.html"
  echo '<p>home</p>' >"$SITE/index.html"
  echo '<p>site-404-page</p>' >"$SITE/404.html"
  echo '<p>legal</p>' >"$SITE/legal/index.html"
  echo 'console.log(1)' >"$SITE/_astro/app.js"
  echo 'font' >"$SITE/fonts/face.woff2"
  head -c 4096 /dev/zero | tr '\0' 'a' | sed 's/^/<p>/' >"$SITE/legal/long.html"
  chmod -R a+rX "$SITE"
  SERVE_SITE_DIST="$SITE" bash "$ROOT/scripts/serve-site.sh" start "$PORT" >/dev/null
  export ROOT SITE
}

teardown_file() {
  bash "$ROOT/scripts/serve-site.sh" stop "$PORT"
  rm -rf "$SITE"
}

# Prints the status line, the headers and the body of one request from inside the container
# (curl -i: busybox wget prints no body for an error status), from nginx's own listener.
# tls_fetch prints the headers only, through the TLS proxy the site audits measure.
fetch() {
  docker exec "$CONTAINER" curl -s -i "http://127.0.0.1:8080$1" | tr -d '\r'
}

tls_fetch() {
  docker exec "$CONTAINER" curl -sk -D - -o /dev/null -H 'Accept-Encoding: gzip' "https://127.0.0.1:8443$1" | tr -d '\r'
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

@test "the pages that receive a token in their fragment send no Referer; the others a strict one" {
  for page in /auth/confirm/ /auth/reset-password/ /auth/confirm; do
    grep -qi '^Referrer-Policy: no-referrer$' <<<"$(fetch "$page")" || {
      echo "no no-referrer on $page" >&2
      return 1
    }
  done
  grep -qi '^Referrer-Policy: strict-origin-when-cross-origin$' <<<"$(fetch /legal/)"
  grep -qi '^Referrer-Policy: strict-origin-when-cross-origin$' <<<"$(fetch /auth/confirmed-elsewhere/)"
}

@test "the local TLS server passes the headers through and keeps gzip (HTTP/1.1 upstream)" {
  out="$(tls_fetch /legal/long.html)"
  grep -q '^HTTP/1.1 200' <<<"$out"
  has_security_headers "$out"
  grep -qi '^Content-Encoding: gzip' <<<"$out"
}
