#!/usr/bin/env bats
# The osionos web image owns the app's Content-Security-Policy (osionos#314). The two edges that
# front it add `frame-ancestors 'none'` ONLY when the upstream sent no CSP, so a browser sees one
# CSP header, not two that must both pass. nginx skips an add_header whose value is empty; this
# file proves that behaviour on the real configs instead of assuming it:
#   - an upstream that sends a CSP keeps exactly that one (and its Report-Only copy) on both edges;
#   - an upstream that sends none (a Kong stub) and an upstream that is down (the edge's own 502)
#     get the edge's `frame-ancestors 'none'`;
#   - a storage answer that already carries `sandbox` is not given a frame-ancestors copy;
#   - the beta edge sends one X-Frame-Options, like production.
#
# Runs infrastructure/tls/nginx.conf (:3001) and infrastructure/beta/edge.conf (:3010) in the
# image compose runs them in. One stub container answers as the app (osionos-app and
# osionos-beta-app, :80) and as Kong (mini-baas-kong, :8000); the production edge is also the beta
# edge's `track-binocle-local-https-proxy-1` upstream, so beta is measured through the real chain.
# Needs docker and openssl; skips without docker, and runs with no skips allowed in
# .github/workflows/storage-edge.yml.
# Caveat: header lines are counted from curl -D output with a case-insensitive grep, so a header
# folded across lines would be undercounted; nginx never folds.

NGINX_IMAGE=public.ecr.aws/docker/library/nginx:1.27-alpine
APP_CSP="frame-ancestors 'none'; script-src 'self'"

d() { timeout 60 docker "$@"; }

setup_file() {
  command -v docker >/dev/null 2>&1 || skip "needs docker (runs in storage-edge.yml)"
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  NET=tec-net-$$ UPSTREAM=tec-upstream-$$ EDGE=tec-edge-$$ BETA=tec-beta-$$
  d network create "$NET" >/dev/null

  d create --name "$UPSTREAM" --network "$NET" --network-alias osionos-app \
    --network-alias osionos-beta-app --network-alias mini-baas-kong "$NGINX_IMAGE" >/dev/null
  cat >"$BATS_FILE_TMPDIR/stub.conf" <<NGINX
events {}
http {
  server {
    listen 80;
    location = /with-csp {
      add_header Content-Security-Policy "$APP_CSP" always;
      add_header Content-Security-Policy-Report-Only "script-src 'self'" always;
      return 200 "app\n";
    }
    location = /report-only { add_header Content-Security-Policy-Report-Only "script-src 'self'" always; return 200 "app\n"; }
    location / { return 200 "app\n"; }
  }
  server {
    listen 8000;
    location = /storage/v1/sandboxed { add_header Content-Security-Policy "sandbox" always; return 200 "kong\n"; }
    location / { return 200 "kong\n"; }
  }
}
NGINX
  d cp "$BATS_FILE_TMPDIR/stub.conf" "$UPSTREAM:/etc/nginx/nginx.conf"
  d start "$UPSTREAM" >/dev/null

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
    [ "$(d exec "$EDGE" curl -sk -o /dev/null -w '%{http_code}' https://localhost:3001/rest/v1/x)" = 200 ] &&
      [ "$(d exec "$BETA" curl -s -o /dev/null -w '%{http_code}' http://localhost:3010/)" = 200 ] && break
    sleep 0.2
  done
  export REPO NET UPSTREAM EDGE BETA
}

teardown_file() {
  d rm -f "${EDGE:-x}" "${BETA:-x}" "${UPSTREAM:-x}" >/dev/null 2>&1 || true
  d network rm "${NET:-x}" >/dev/null 2>&1 || true
}

# Response headers, CR stripped, names lower-cased. $1 = container, $2 = url.
fetch() { d exec "$1" curl -sk --max-time 5 -o /dev/null -D - "$2" | tr -d '\r' | awk '{ i = index($0, ":"); if (i) $0 = tolower(substr($0, 1, i)) substr($0, i + 1); print }'; }
app() { fetch "$EDGE" "https://localhost:3001$1"; }
beta() { fetch "$BETA" "http://localhost:3010$1"; }
count() { grep -c "^$1:" <<<"$2" || true; }
header() { sed -n "s/^$1: //p" <<<"$2"; }

@test "nginx -t accepts both real configs" {
  run d exec "$EDGE" nginx -t
  [ "$status" -eq 0 ]
  run d exec "$BETA" nginx -t
  [ "$status" -eq 0 ]
}

@test "app edge: an upstream CSP is the only CSP, with its Report-Only copy" {
  out=$(app /with-csp)
  [ "$(count content-security-policy "$out")" -eq 1 ]
  [ "$(header content-security-policy "$out")" = "$APP_CSP" ]
  [ "$(count content-security-policy-report-only "$out")" -eq 1 ]
  [ "$(count x-frame-options "$out")" -eq 1 ]
}

@test "app edge: a Report-Only-only upstream still gets the enforced frame-ancestors" {
  out=$(app /report-only)
  [ "$(count content-security-policy-report-only "$out")" -eq 1 ]
  [ "$(count content-security-policy "$out")" -eq 1 ]
  [ "$(header content-security-policy "$out")" = "frame-ancestors 'none'" ]
}

@test "app edge: a Kong answer with no CSP gets the edge frame-ancestors, once" {
  out=$(app /rest/v1/x)
  [ "$(count content-security-policy "$out")" -eq 1 ]
  [ "$(header content-security-policy "$out")" = "frame-ancestors 'none'" ]
}

@test "app edge: a storage answer that sends sandbox gets no frame-ancestors copy" {
  out=$(app /storage/v1/sandboxed)
  [ -n "$(header content-security-policy "$out")" ]
  if header content-security-policy "$out" | grep -qv '^sandbox$'; then return 1; fi
}

@test "beta edge: an upstream CSP is the only CSP, and X-Frame-Options is sent once" {
  out=$(beta /with-csp)
  [ "$(count content-security-policy "$out")" -eq 1 ]
  [ "$(header content-security-policy "$out")" = "$APP_CSP" ]
  [ "$(count content-security-policy-report-only "$out")" -eq 1 ]
  [ "$(count x-frame-options "$out")" -eq 1 ]
}

@test "beta edge: an app answer with no CSP gets the edge frame-ancestors, once" {
  out=$(beta /)
  [ "$(count content-security-policy "$out")" -eq 1 ]
  [ "$(header content-security-policy "$out")" = "frame-ancestors 'none'" ]
  [ "$(count x-frame-options "$out")" -eq 1 ]
}

@test "beta edge: the storage path through production carries one X-Frame-Options, the frame CSP and sandbox" {
  out=$(beta /storage/v1/x)
  [ "$(count x-frame-options "$out")" -eq 1 ]
  [ "$(count content-security-policy "$out")" -eq 2 ]
  header content-security-policy "$out" | grep -qx sandbox
}

@test "negative control: an edge with no map would send two CSPs on an upstream CSP" {
  # The old line, replayed on a copy: proves the count above can see a duplicate.
  sed "s|add_header Content-Security-Policy \$edge_frame_csp always;|add_header Content-Security-Policy \"frame-ancestors 'none'\" always;|" \
    "$REPO/infrastructure/beta/edge.conf" >"$BATS_TEST_TMPDIR/old.conf"
  d cp "$BATS_TEST_TMPDIR/old.conf" "$BETA:/etc/nginx/conf.d/old.conf"
  d exec "$BETA" sh -c 'mv /etc/nginx/conf.d/default.conf /tmp/default.conf'
  d exec "$BETA" nginx -s reload
  sleep 0.5
  out=$(beta /with-csp)
  d exec "$BETA" sh -c 'rm /etc/nginx/conf.d/old.conf; mv /tmp/default.conf /etc/nginx/conf.d/default.conf'
  d exec "$BETA" nginx -s reload
  [ "$(count content-security-policy "$out")" -eq 2 ]
}

@test "app edge: a stopped upstream is the edge's own 502 with frame-ancestors, once" {
  d stop "$UPSTREAM" >/dev/null
  # The edge caches the upstream address for 10 s (resolver valid=); past that the name is gone and
  # the answer is an immediate 502 instead of a connect timeout against the dead address.
  sleep 11
  out=$(app /)
  [ "$(sed -n '1s/.* \([0-9][0-9][0-9]\).*/\1/p' <<<"$out")" = 502 ]
  [ "$(count content-security-policy "$out")" -eq 1 ]
  [ "$(header content-security-policy "$out")" = "frame-ancestors 'none'" ]
}
