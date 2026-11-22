#!/usr/bin/env bats
# /storage/v1/* on the osionos origin (:3001) reaches Kong, and Kong sends part of it straight to
# minio (kong.yml), where storage-router's active-content guard never runs. A stored text/html or
# image/svg+xml opened by navigation would then run on the origin that holds the app's tokens.
# The edge closes that with server-level maps (CSP sandbox + nosniff, ruling SG-8/SG-9). A
# location-level add_header would silently drop the server's anti-framing headers on exactly
# that route, so both paths are checked for those too.
#
# Runs the REAL nginx.conf in the image compose runs it in. One stub container answers as both
# upstreams of :3001 (network aliases osionos-app and mini-baas-kong) with no security headers of
# its own, so every header asserted here comes from the edge. Every other upstream name stays
# unresolved, which nginx tolerates: proxy_pass uses a variable (see the note in nginx.conf).
# The self-signed pair is throwaway, made in the test's temp dir. Curl runs inside the edge
# container, so only the nginx image is needed.
#
# Needs docker and openssl; skips without docker (the fresh-machine bats container has none) and
# runs, no skips allowed, in .github/workflows/storage-edge.yml. From a container:
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD:/code" -w /code \
#     --entrypoint sh bats/bats:1.11.1 <script running: apk add docker-cli openssl; bats this-file>

NGINX_IMAGE=public.ecr.aws/docker/library/nginx:1.27-alpine

d() { timeout 60 docker "$@"; }

setup_file() {
  command -v docker >/dev/null 2>&1 || skip "needs docker (runs in storage-edge.yml)"
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  NET=tsg-net-$$
  UPSTREAM=tsg-upstream-$$
  EDGE=tsg-edge-$$
  d network create "$NET" >/dev/null

  d create --name "$UPSTREAM" --network "$NET" \
    --network-alias osionos-app --network-alias mini-baas-kong "$NGINX_IMAGE" >/dev/null
  cat >"$BATS_FILE_TMPDIR/stub.conf" <<'NGINX'
events {}
http {
  server { listen 80;   location / { add_header X-Stub app always;  return 200 "app\n"; } }
  server { listen 8000; location / { add_header X-Stub kong always; return 200 "kong\n"; } }
}
NGINX
  d cp "$BATS_FILE_TMPDIR/stub.conf" "$UPSTREAM:/etc/nginx/nginx.conf"
  d start "$UPSTREAM" >/dev/null

  local certs=$BATS_FILE_TMPDIR/etc/track-binocle/certs
  mkdir -p "$certs"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$certs/localhost-key.pem" -out "$certs/localhost.pem" 2>/dev/null
  d create --name "$EDGE" --network "$NET" "$NGINX_IMAGE" >/dev/null
  d cp "$REPO/infrastructure/tls/nginx.conf" "$EDGE:/etc/nginx/nginx.conf"
  d cp "$BATS_FILE_TMPDIR/etc/." "$EDGE:/etc/"
  d start "$EDGE" >/dev/null

  for _ in $(seq 50); do
    [ "$(d exec "$EDGE" curl -sk -o /dev/null -w '%{http_code}' https://localhost:3001/storage/v1/x)" = 200 ] && break
    sleep 0.2
  done
  export NET UPSTREAM EDGE
}

teardown_file() {
  d rm -f "${EDGE:-tsg-edge-none}" "${UPSTREAM:-tsg-upstream-none}" >/dev/null 2>&1 || true
  d network rm "${NET:-tsg-net-none}" >/dev/null 2>&1 || true
}

# Response headers of a GET to :3001 (lower-cased names, CR stripped).
edge() {
  d exec "$EDGE" curl -sk --max-time 5 -o /dev/null -D - "https://localhost:3001$1" | tr -d '\r' |
    awk '{ i = index($0, ":"); if (i) $0 = tolower(substr($0, 1, i)) substr($0, i + 1); print }'
}

header() { sed -n "s/^$1: //p" <<<"$2"; }

# The anti-framing set every response of the app origin must keep.
assert_framing_kept() {
  [ "$(header x-frame-options "$1")" = DENY ]
  header content-security-policy "$1" | grep -qxF "frame-ancestors 'none'"
  header permissions-policy "$1" | grep -qF 'microphone=(self)'
}

@test "nginx -t accepts the real config" {
  run d exec "$EDGE" nginx -t
  [ "$status" -eq 0 ]
}

@test "/storage/v1/x reaches Kong and is sandboxed with nosniff" {
  out=$(edge /storage/v1/x)
  [ "$(header x-stub "$out")" = kong ]
  header content-security-policy "$out" | grep -qx 'sandbox'
  [ "$(header x-content-type-options "$out")" = nosniff ]
}

@test "/storage/v1/x keeps X-Frame-Options, frame-ancestors 'none' and Permissions-Policy" {
  assert_framing_kept "$(edge /storage/v1/x)"
}

@test "/ reaches the SPA and keeps X-Frame-Options, frame-ancestors 'none' and Permissions-Policy" {
  out=$(edge /)
  [ "$(header x-stub "$out")" = app ]
  assert_framing_kept "$out"
}

@test "negative control: / carries no sandbox" {
  out=$(edge /)
  [ -n "$out" ]
  if header content-security-policy "$out" | grep -q sandbox; then return 1; fi
}
