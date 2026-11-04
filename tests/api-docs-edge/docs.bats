#!/usr/bin/env bats
# The :8444 front door (infrastructure/tls/nginx.conf) serves the public API documentation:
# /openapi.json is grobase's document, /docs/ renders it with a local script under a CSP that
# allows no other origin, and every other path still reaches Kong. These tests run the REAL
# nginx.conf in the image compose runs it in, with the files docker-compose.yml mounts, in
# front of a stub `mini-baas-kong` that answers like key-auth does without a key.
#
# Needs docker and openssl; files go in with `docker cp`, like tests/hydrawn-edge.

NGINX_IMAGE=public.ecr.aws/docker/library/nginx:1.27-alpine
CURL_IMAGE=curlimages/curl:8.10.1

setup_file() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  SPEC=$REPO/apps/grobase/infra/config/openapi/grobase-public.json
  [ -f "$SPEC" ] || {
    echo "missing $SPEC: run git submodule update --init apps/grobase" >&2
    return 1
  }
  NET=api-docs-edge-$$
  docker network create "$NET" >/dev/null

  STUB=$(docker create --network "$NET" --network-alias mini-baas-kong "$NGINX_IMAGE")
  cat >"$BATS_FILE_TMPDIR/stub.conf" <<'NGINX'
events {}
http {
  server {
    listen 8000;
    location / {
      add_header WWW-Authenticate 'Key realm="kong"' always;
      return 401 '{"message":"No API key found in request"}';
    }
  }
}
NGINX
  docker cp "$BATS_FILE_TMPDIR/stub.conf" "$STUB:/etc/nginx/nginx.conf"
  docker start "$STUB" >/dev/null

  local etc=$BATS_FILE_TMPDIR/etc share=$BATS_FILE_TMPDIR/share
  mkdir -p "$etc/track-binocle/certs" "$share/track-binocle/openapi"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$etc/track-binocle/certs/localhost-key.pem" \
    -out "$etc/track-binocle/certs/localhost.pem" 2>/dev/null
  cp -R "$REPO/infrastructure/tls/api-docs" "$share/track-binocle/api-docs"
  cp "$SPEC" "$share/track-binocle/openapi/"
  PROXY=$(docker create --network "$NET" --network-alias edge "$NGINX_IMAGE")
  docker cp "$REPO/infrastructure/tls/nginx.conf" "$PROXY:/etc/nginx/nginx.conf"
  docker cp "$etc/." "$PROXY:/etc/"
  docker cp "$share/." "$PROXY:/usr/share/"
  docker start "$PROXY" >/dev/null

  CURL=$(docker run -d --network "$NET" --entrypoint sleep "$CURL_IMAGE" 600)
  for _ in $(seq 50); do
    docker exec "$CURL" curl -sk -o /dev/null https://edge:8444/ && break
    sleep 0.2
  done
  export NET STUB PROXY CURL SPEC
}

teardown_file() {
  docker rm -f "${CURL:-}" "${PROXY:-}" "${STUB:-}" >/dev/null 2>&1 || true
  docker network rm "${NET:-}" >/dev/null 2>&1 || true
}

# Headers (lower-cased names, CR stripped) then a blank line then the body.
edge() {
  docker exec "$CURL" curl -sk -D - "https://edge:8444$1" | tr -d '\r' |
    awk 'body { print; next } /^$/ { body = 1; print; next }
         { i = index($0, ":"); if (i) $0 = tolower(substr($0, 1, i)) substr($0, i + 1); print }'
}

status_of() { sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' <<<"$1"; }
body_of() { sed '1,/^$/d' <<<"$1"; }

@test "/openapi.json is grobase's public document, byte for byte" {
  out=$(edge /openapi.json)
  [ "$(status_of "$out")" = 200 ]
  grep -q '^content-type: application/json' <<<"$out"
  diff <(body_of "$out") "$SPEC"
}

@test "/docs redirects to /docs/" {
  out=$(edge /docs)
  [ "$(status_of "$out")" = 301 ]
  grep -qE '^location: .*/docs/$' <<<"$out"
}

@test "/docs/ is the page, its script and stylesheet, under a self-only CSP" {
  out=$(edge /docs/)
  [ "$(status_of "$out")" = 200 ]
  grep -q '^content-type: text/html' <<<"$out"
  grep -q "^content-security-policy: default-src 'none'; script-src 'self'" <<<"$out"
  grep -q '<script src="docs.js">' <<<"$out"
  [ "$(status_of "$(edge /docs/docs.js)")" = 200 ]
  [ "$(status_of "$(edge /docs/docs.css)")" = 200 ]
}

@test "the page loads nothing from another origin" {
  run grep -rnE '(src|href)="(https?:)?//' "$BATS_TEST_DIRNAME/../../infrastructure/tls/api-docs"
  [ "$status" -eq 1 ]
}

@test "the rest of :8444 still reaches Kong (401 without a key)" {
  out=$(edge /rest/v1/)
  [ "$(status_of "$out")" = 401 ]
  grep -qi '^www-authenticate: Key' <<<"$out"
}
