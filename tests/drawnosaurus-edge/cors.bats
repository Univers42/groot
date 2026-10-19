#!/usr/bin/env bats
# The :3007 front door (infrastructure/tls/nginx.conf) is the one place that answers CORS for
# drawnosaurus. osionos (https://localhost:3001) creates boards and imports scenes cross-origin
# (whiteboardClient.ts: POST /v1/boards and PUT /v1/boards/<slug>, Content-Type + If-Match, no
# credentials), so those preflight. These tests run the REAL nginx.conf in the image compose runs
# it in. Behind it sits a stub `drawnosaurus-gateway` that answers like drawnosaurus's fastify-cors
# does (Access-Control-Allow-Origin https://localhost:3001 for ANY origin, DELETE advertised): the
# front door must neither forward the preflight nor let those upstream headers through.
#
# Needs docker and openssl; everything else runs in containers on a private network, and files
# go in with `docker cp`, so it also runs from inside a container holding the docker socket:
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD:/code" -w /code \
#     --entrypoint sh bats/bats:1.11.1 -c 'apk add -q docker-cli openssl && bats tests/drawnosaurus-edge'

NGINX_IMAGE=public.ecr.aws/docker/library/nginx:1.27-alpine
CURL_IMAGE=curlimages/curl:8.10.1
OSIONOS=https://localhost:3001

setup_file() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  NET=wb-edge-$$
  docker network create "$NET" >/dev/null

  STUB=$(docker create --network "$NET" --network-alias drawnosaurus-gateway "$NGINX_IMAGE")
  cat >"$BATS_FILE_TMPDIR/stub.conf" <<'NGINX'
events {}
http {
  server {
    listen 80;
    location / {
      add_header Access-Control-Allow-Origin https://localhost:3001 always;
      add_header Access-Control-Allow-Methods "GET, HEAD, POST, PUT, PATCH, DELETE" always;
      add_header Access-Control-Expose-Headers "ETag, Location" always;
      add_header X-Stub-Method $request_method always;
      if ($request_method = OPTIONS) { return 204; }
      return 200 "stub\n";
    }
  }
}
NGINX
  docker cp "$BATS_FILE_TMPDIR/stub.conf" "$STUB:/etc/nginx/nginx.conf"
  docker start "$STUB" >/dev/null

  local certs=$BATS_FILE_TMPDIR/etc/track-binocle/certs
  mkdir -p "$certs"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$certs/localhost-key.pem" -out "$certs/localhost.pem" 2>/dev/null
  PROXY=$(docker create --network "$NET" --network-alias edge "$NGINX_IMAGE")
  docker cp "$REPO/infrastructure/tls/nginx.conf" "$PROXY:/etc/nginx/nginx.conf"
  docker cp "$BATS_FILE_TMPDIR/etc/." "$PROXY:/etc/"
  docker start "$PROXY" >/dev/null

  CURL=$(docker run -d --network "$NET" --entrypoint sleep "$CURL_IMAGE" 600)
  for _ in $(seq 50); do
    docker exec "$CURL" curl -sk -o /dev/null -H 'Host: localhost:3007' https://edge:3007/v1/boards && break
    sleep 0.2
  done
  export NET STUB PROXY CURL
}

teardown_file() {
  docker rm -f "${CURL:-}" "${PROXY:-}" "${STUB:-}" >/dev/null 2>&1 || true
  docker network rm "${NET:-}" >/dev/null 2>&1 || true
}

# Response headers (lower-cased names, CR stripped) of a request to :3007; extra curl args follow.
edge() {
  local method="$1" path="$2"
  shift 2
  docker exec "$CURL" curl -sk -o /dev/null -D - -X "$method" -H 'Host: localhost:3007' "$@" \
    "https://edge:3007$path" | tr -d '\r' |
    awk '{ i = index($0, ":"); if (i) $0 = tolower(substr($0, 1, i)) substr($0, i + 1); print }'
}

preflight() {
  edge OPTIONS "$1" -H "Origin: $2" -H "Access-Control-Request-Method: $3" \
    -H "Access-Control-Request-Headers: $4"
}

status_of() { sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' <<<"$1"; }
header() { sed -n "s/^$1: //p" <<<"$2"; }

@test "nginx -t accepts the real config" {
  run docker exec "$PROXY" nginx -t
  [ "$status" -eq 0 ]
}

@test "preflight from osionos for the create POST is answered at the edge" {
  out=$(preflight /v1/boards "$OSIONOS" POST content-type)
  [ "$(status_of "$out")" = 204 ]
  [ "$(header access-control-allow-origin "$out")" = "$OSIONOS" ]
  [ "$(header access-control-allow-methods "$out")" = "GET, HEAD, POST, PUT, PATCH" ]
  [ "$(header access-control-allow-headers "$out")" = "Content-Type, If-Match" ]
  header vary "$out" | grep -qw Origin
  [ -z "$(header x-stub-method "$out")" ]
  [ -z "$(header access-control-allow-credentials "$out")" ]
}

@test "preflight from osionos for the scene import PUT (Content-Type + If-Match) is answered" {
  out=$(preflight /v1/boards/abc123 "$OSIONOS" PUT content-type,if-match)
  [ "$(status_of "$out")" = 204 ]
  [ "$(header access-control-allow-origin "$out")" = "$OSIONOS" ]
  [ "$(header access-control-allow-headers "$out")" = "Content-Type, If-Match" ]
}

@test "negative control: a preflight from another origin gets no Allow-* header" {
  out=$(preflight /v1/boards https://evil.example POST content-type)
  [ -z "$(header access-control-allow-origin "$out")" ]
  [ -z "$(header access-control-allow-methods "$out")" ]
  [ -z "$(header access-control-allow-headers "$out")" ]
  header vary "$out" | grep -qw Origin
  [ -z "$(header x-stub-method "$out")" ]
}

@test "negative control: osionos opened as 127.0.0.1 is another origin and is refused" {
  out=$(preflight /v1/boards https://127.0.0.1:3001 POST content-type)
  [ -z "$(header access-control-allow-origin "$out")" ]
}

@test "a POST from osionos is proxied and carries exactly one Allow-Origin, the edge's" {
  out=$(edge POST /v1/boards -H "Origin: $OSIONOS" -H 'Content-Type: application/json' --data '{}')
  [ "$(status_of "$out")" = 200 ]
  [ "$(header x-stub-method "$out")" = POST ]
  [ "$(header access-control-allow-origin "$out")" = "$OSIONOS" ]
  [ "$(grep -c '^access-control-allow-origin:' <<<"$out")" -eq 1 ]
  [ -z "$(header access-control-expose-headers "$out")" ]
  [ "$(header content-security-policy "$out")" = "frame-ancestors $OSIONOS" ]
}

@test "negative control: a POST from another origin gets no Allow-Origin, upstream's is hidden" {
  out=$(edge POST /v1/boards -H 'Origin: https://evil.example' -H 'Content-Type: application/json' --data '{}')
  [ "$(header x-stub-method "$out")" = POST ]
  [ -z "$(header access-control-allow-origin "$out")" ]
}

@test "upstream CORS headers are hidden outside /v1/boards too" {
  out=$(edge GET /healthz -H 'Origin: https://evil.example')
  [ "$(header x-stub-method "$out")" = GET ]
  [ -z "$(header access-control-allow-origin "$out")" ]
  [ -z "$(header access-control-allow-methods "$out")" ]
}

@test "DELETE on a board stays denied and never reaches upstream" {
  out=$(edge DELETE /v1/boards/abc123 -H "Origin: $OSIONOS")
  [ "$(status_of "$out")" = 403 ]
  [ -z "$(header x-stub-method "$out")" ]
}

@test "/v1/share stays denied, preflight included" {
  out=$(edge POST /v1/share -H "Origin: $OSIONOS")
  [ "$(status_of "$out")" = 403 ]
  out=$(preflight /v1/share "$OSIONOS" POST content-type)
  [ "$(status_of "$out")" = 403 ]
  [ -z "$(header access-control-allow-origin "$out")" ]
  [ -z "$(header x-stub-method "$out")" ]
}

@test "the embed document keeps its framing rule" {
  out=$(edge GET / -H "Origin: $OSIONOS")
  [ "$(header content-security-policy "$out")" = "frame-ancestors $OSIONOS" ]
}
