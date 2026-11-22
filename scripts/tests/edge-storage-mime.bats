#!/usr/bin/env bats
# osionos#314 D314-16(b): a stored file is served from the app origin, so a stored .js or .wasm
# would be a same-origin script the app's CSP (script-src 'self') allows. The edge answers
# executable MIME types on /storage/v1/ as application/octet-stream (nosniff is already there,
# ADR 0074), so the browser will not run them as a script, module or worker. Other types, and
# every other path, are untouched; the framing headers stay on the route.
#
# One stub container is Kong (mini-baas-kong:8000) and answers with the Content-Type it is asked
# for in the path; the real infrastructure/tls/nginx.conf fronts it. The beta edge is chained in
# front of the production edge to prove beta needs no rewrite of its own.
# Caveat: the rewrite is a denylist of script MIME types, so an executable type nobody listed
# passes through; text/html and SVG are covered by the CSP sandbox, not by this rewrite.

NGINX_IMAGE=public.ecr.aws/docker/library/nginx:1.27-alpine

d() { timeout 60 docker "$@"; }

setup_file() {
  command -v docker >/dev/null 2>&1 || skip "needs docker (runs in storage-edge.yml)"
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  NET=tsm-net-$$ KONG=tsm-kong-$$ EDGE=tsm-edge-$$ BETA=tsm-beta-$$
  d network create "$NET" >/dev/null
  d create --name "$KONG" --network "$NET" --network-alias mini-baas-kong \
    --network-alias osionos-app --network-alias osionos-beta-app "$NGINX_IMAGE" >/dev/null
  cat >"$BATS_FILE_TMPDIR/stub.conf" <<'NGINX'
events {}
http {
  server {
    listen 80;
    location / { return 200 "app\n"; }
  }
  server {
    listen 8000;
    default_type text/plain;
    location = /storage/v1/js          { default_type "text/javascript"; return 200 "x\n"; }
    location = /storage/v1/js-charset  { default_type "application/javascript; charset=utf-8"; return 200 "x\n"; }
    location = /storage/v1/ecma        { default_type "application/ecmascript"; return 200 "x\n"; }
    location = /storage/v1/wasm        { default_type "application/wasm"; return 200 "x\n"; }
    location = /storage/v1/upper       { default_type "Text/JavaScript"; return 200 "x\n"; }
    location = /storage/v1/png         { default_type "image/png"; return 200 "x\n"; }
    location = /storage/v1/json        { default_type "application/json"; return 200 "{}\n"; }
    location = /storage/v1/none        { default_type ""; return 204; }
    location = /rest/v1/js             { default_type "text/javascript"; return 200 "x\n"; }
  }
}
NGINX
  d cp "$BATS_FILE_TMPDIR/stub.conf" "$KONG:/etc/nginx/nginx.conf"
  d start "$KONG" >/dev/null

  local certs=$BATS_FILE_TMPDIR/etc/track-binocle/certs
  mkdir -p "$certs"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$certs/localhost-key.pem" -out "$certs/localhost.pem" 2>/dev/null
  d create --name "$EDGE" --network "$NET" --network-alias track-binocle-local-https-proxy-1 "$NGINX_IMAGE" >/dev/null
  d cp "$REPO/infrastructure/tls/nginx.conf" "$EDGE:/etc/nginx/nginx.conf"
  d cp "$BATS_FILE_TMPDIR/etc/." "$EDGE:/etc/"
  d start "$EDGE" >/dev/null
  d create --name "$BETA" --network "$NET" "$NGINX_IMAGE" >/dev/null
  d cp "$REPO/infrastructure/beta/edge.conf" "$BETA:/etc/nginx/conf.d/default.conf"
  d start "$BETA" >/dev/null

  for _ in $(seq 50); do
    [ "$(d exec "$EDGE" curl -sk -o /dev/null -w '%{http_code}' https://localhost:3001/rest/v1/js)" = 200 ] &&
      [ "$(d exec "$BETA" curl -s -o /dev/null -w '%{http_code}' http://localhost:3010/)" = 200 ] && break
    sleep 0.2
  done
  export REPO NET KONG EDGE BETA
}

teardown_file() {
  d rm -f "${EDGE:-x}" "${BETA:-x}" "${KONG:-x}" >/dev/null 2>&1 || true
  d network rm "${NET:-x}" >/dev/null 2>&1 || true
}

fetch() { d exec "$1" curl -sk --max-time 5 -o /dev/null -D - "$2" | tr -d '\r' | awk '{ i = index($0, ":"); if (i) $0 = tolower(substr($0, 1, i)) substr($0, i + 1); print }'; }
app() { fetch "$EDGE" "https://localhost:3001$1"; }
beta() { fetch "$BETA" "http://localhost:3010$1"; }
count() { grep -c "^$1:" <<<"$2" || true; }
header() { sed -n "s/^$1: //p" <<<"$2"; }

@test "nginx -t accepts the edge" {
  run d exec "$EDGE" nginx -t
  [ "$status" -eq 0 ]
}

@test "text/javascript on storage becomes application/octet-stream, once" {
  out=$(app /storage/v1/js)
  [ "$(count content-type "$out")" -eq 1 ]
  [ "$(header content-type "$out")" = application/octet-stream ]
}

@test "a javascript type with a charset parameter is rewritten too" {
  [ "$(header content-type "$(app /storage/v1/js-charset)")" = application/octet-stream ]
}

@test "application/ecmascript and application/wasm are rewritten" {
  [ "$(header content-type "$(app /storage/v1/ecma)")" = application/octet-stream ]
  [ "$(header content-type "$(app /storage/v1/wasm)")" = application/octet-stream ]
}

@test "the match ignores the case of the type" {
  [ "$(header content-type "$(app /storage/v1/upper)")" = application/octet-stream ]
}

@test "image/png and application/json keep their type" {
  [ "$(header content-type "$(app /storage/v1/png)")" = image/png ]
  [ "$(header content-type "$(app /storage/v1/json)")" = application/json ]
}

@test "an answer with no Content-Type gets none added" {
  [ "$(count content-type "$(app /storage/v1/none)")" -eq 0 ]
}

@test "other paths keep text/javascript" {
  [ "$(header content-type "$(app /rest/v1/js)")" = text/javascript ]
}

@test "the storage route keeps nosniff, sandbox, DENY and the permissions policy" {
  out=$(app /storage/v1/js)
  [ "$(header x-content-type-options "$out")" = nosniff ]
  [ "$(count x-frame-options "$out")" -eq 1 ]
  [ "$(count permissions-policy "$out")" -eq 1 ]
  [ "$(header content-security-policy "$out" | sort | tr '\n' '|')" = "frame-ancestors 'none'|sandbox|" ]
}

@test "beta reaches storage through production and gets the rewrite without its own" {
  out=$(beta /storage/v1/js)
  [ "$(count content-type "$out")" -eq 1 ]
  [ "$(header content-type "$out")" = application/octet-stream ]
  [ "$(header x-content-type-options "$out")" = nosniff ]
  ! grep -q 'application/' "$REPO/infrastructure/beta/edge.conf"
}
