#!/usr/bin/env bats
# `make check_health_apps` probes the auth gateway at /api/auth/health and falls back to the
# old /api/auth/availability only on a 404 (same rule as docker-compose.yml's auth-gateway
# healthcheck). Drives the real script against a fake `curl` that answers a code chosen by
# URL, so no network is touched.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache coreutils && bats scripts/tests/check-health-apps.bats'

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../check-health-apps.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat >"$BIN/curl" <<'FAKE'
#!/bin/sh
# Fake curl: the URL is the last argument; HEALTH_CODE / AVAIL_CODE answer the gateway
# routes, everything else 200; CURL_UNREACHABLE=1 behaves like -w then exit 7.
for url; do :; done
printf '%s\n' "$url" >>"$ASKED"
if [ -n "${CURL_UNREACHABLE:-}" ]; then printf 000; exit 7; fi
case "$url" in
*/api/auth/health) printf '%s' "$HEALTH_CODE" ;;
*/api/auth/availability) printf '%s' "$AVAIL_CODE" ;;
*) printf 200 ;;
esac
exit 0
FAKE
  chmod +x "$BIN/curl"
  PATH="$BIN:$PATH"
  export ASKED="$BATS_TEST_TMPDIR/asked"
  : >"$ASKED"
  export HEALTH_TIMEOUT=1 HEALTH_CODE=200 AVAIL_CODE=503
  export PROD_WEBSITE_URL=https://site.invalid PROD_OSIONOS_URL=https://osionos.invalid
  export PROD_GROBASE_URL=https://grobase.invalid PROD_AUTH_URL=https://auth.invalid
}

# The auth-gateway row with colors stripped, whitespace squeezed.
gateway_row() {
  sh "$SCRIPT" | sed 's/\x1b\[[0-9;]*m//g' | grep "^  auth-gateway" | tr -s " " | sed "s/ *$//"
}

@test "gateway /health 200: local cell UP and /availability is never requested" {
  run gateway_row
  [ "$status" -eq 0 ]
  [[ "$output" == " auth-gateway https://localhost:8787 UP https://auth.invalid UP" ]]
  run grep -c '/api/auth/availability' "$ASKED"
  [ "$output" = 0 ]
}

@test "gateway /health 404, /availability 200: both cells UP" {
  HEALTH_CODE=404 AVAIL_CODE=200 run gateway_row
  [[ "$output" == " auth-gateway https://localhost:8787 UP https://auth.invalid UP" ]]
}

@test "gateway /health 500 does not fall back" {
  HEALTH_CODE=500 AVAIL_CODE=200 run gateway_row
  [[ "$output" == " auth-gateway https://localhost:8787 500 https://auth.invalid 500" ]]
}

@test "unreachable everywhere: cells read DOWN, not 000000" {
  CURL_UNREACHABLE=1 run gateway_row
  [[ "$output" == " auth-gateway https://localhost:8787 DOWN https://auth.invalid DOWN" ]]
}
