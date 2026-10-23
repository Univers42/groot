#!/usr/bin/env bats
# `make healthcheck` probes the auth gateway on /api/auth/health, the route prismatica main serves,
# and falls back to /api/auth/availability only when /health is 404: the pin and older published
# gateway images serve nothing else. Drives the real Makefile against a fake `docker` and a fake
# `curl` that answers by URL.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache make coreutils && bats scripts/tests/healthcheck-auth-gateway.bats'

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN" "$BATS_TEST_TMPDIR/link"
  printf '#!/bin/sh\nexit 0\n' >"$BIN/docker"
  cat >"$BIN/curl" <<'FAKE'
#!/bin/sh
# Fake curl: the gateway's two routes answer GW_HEALTH / GW_AVAIL, the website's plain-HTTP port
# redirects, everything else is 200. Honours -f (exit 22 on >= 400) and -w '%{http_code}'.
fail=0 fmt= url=
while [ $# -gt 0 ]; do
  case "$1" in
  -w) fmt=$2 && shift ;;
  -H | -o | -m | --cacert | --retry | --retry-delay) shift ;;
  --*) ;;
  -*f*) fail=1 ;;
  http*) url=$1 ;;
  esac
  shift
done
case "$url" in
*/api/auth/health) code=$GW_HEALTH ;;
*/api/auth/availability) code=$GW_AVAIL ;;
http://localhost:*/) code=301 ;;
*) code=200 ;;
esac
echo "$url" >>"$CURL_LOG"
[ -z "$fmt" ] || printf "$(printf '%s' "$fmt" | sed "s/%{http_code}/$code/")"
[ "$fail" = 1 ] && [ "$code" -ge 400 ] && exit 22
exit 0
FAKE
  chmod +x "$BIN/docker" "$BIN/curl"
  PATH="$BIN:$PATH"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export GROBASE_LINK_CONF=/dev/null # this machine's .env.grobase-link must not leak in
}

# -o certs: the probes are under test, not the certificate generation healthcheck depends on.
healthcheck() { make -s -C "$REPO" -o certs healthcheck; }

@test "a gateway serving /health (prismatica main) passes on /health alone" {
  GW_HEALTH=200 GW_AVAIL=404 run healthcheck
  [ "$status" -eq 0 ]
  [[ "$output" == *auth-gateway-https-200* ]]
  run grep -c /api/auth/availability "$CURL_LOG"
  [ "$output" = 0 ]
}

@test "a gateway serving only /availability (the pin, older images) passes on /availability" {
  GW_HEALTH=404 GW_AVAIL=200 run healthcheck
  [ "$status" -eq 0 ]
  [[ "$output" == *auth-gateway-https-200* ]]
  grep -q /api/auth/availability "$CURL_LOG"
}

@test "a gateway answering neither route fails the healthcheck" {
  GW_HEALTH=404 GW_AVAIL=404 run healthcheck
  [ "$status" -ne 0 ]
}

@test "a /health that errors is reported, never masked by the old route" {
  GW_HEALTH=500 GW_AVAIL=200 run healthcheck
  [ "$status" -ne 0 ]
  run grep -c /api/auth/availability "$CURL_LOG"
  [ "$output" = 0 ]
}
