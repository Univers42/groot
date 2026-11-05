#!/usr/bin/env bats
# scripts/verify/public-api.sh against a real Kong (the version grobase builds, DB-less) carrying
# the plugins grobase puts on its public routes: key-auth on `apikey` and rate-limiting by IP
# with the local policy. The upstream is a request-termination, so no stack is needed; the
# limit is 5 a minute so the 429 comes within the script's default cap of 30.
#
# Needs docker, curl and jq; the script reaches Kong on its published loopback port, so from
# inside a container that container needs --network host.

KONG_IMAGE=kong:3.8.0

setup_file() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  local spec
  spec=$(jq -c '{openapi: "3.1.0", info: {title: "stub", version: "0"}, paths: {
    "/rest/v1/{r}": {get: {}, post: {}, patch: {}, delete: {}},
    "/storage/v1/object/{b}/{k}": {put: {}}}}' <<<'null')
  cat >"$BATS_FILE_TMPDIR/kong.yml" <<YAML
_format_version: "3.0"
consumers:
  - username: demo
    keyauth_credentials:
      - key: demo-key
services:
  - name: rest
    url: http://127.0.0.1:1
    routes:
      - name: rest
        paths: [/rest/v1]
    plugins:
      - name: key-auth
        config: { key_names: [apikey] }
      - name: rate-limiting
        config: { policy: local, limit_by: ip, minute: 5 }
      - name: request-termination
        config: { status_code: 200, message: ok }
  - name: docs
    url: http://127.0.0.1:1
    routes:
      - name: docs
        paths: [/openapi.json]
    plugins:
      - name: request-termination
        config: { status_code: 200, content_type: application/json, body: '$spec' }
YAML
  # docker cp rather than a bind mount, so it also runs from a container holding the socket.
  KONG=$(docker create -p 127.0.0.1::8000 \
    -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/tmp/kong.yml \
    -e KONG_PROXY_LISTEN=0.0.0.0:8000 -e KONG_ADMIN_LISTEN=off "$KONG_IMAGE")
  docker cp "$BATS_FILE_TMPDIR/kong.yml" "$KONG:/tmp/kong.yml"
  docker start "$KONG" >/dev/null
  BASE=http://$(docker port "$KONG" 8000/tcp | head -n 1)
  for _ in $(seq 100); do
    curl -s -o /dev/null "$BASE/openapi.json" && break
    sleep 0.3
  done
  SCRIPT=$REPO/scripts/verify/public-api.sh
  export KONG BASE SCRIPT
}

teardown_file() {
  docker rm -f "${KONG:-}" >/dev/null 2>&1 || true
}

# Each test gets a fresh minute window: Kong's local counter is per IP per minute, and the
# tests share one IP. Restarting Kong resets the in-memory counter, and moves the published
# port, hence BASE is read again.
setup() {
  docker restart "$KONG" >/dev/null
  BASE=http://$(docker port "$KONG" 8000/tcp | head -n 1)
  for _ in $(seq 100); do
    curl -s -o /dev/null "$BASE/openapi.json" && return
    sleep 0.3
  done
}

@test "docs, 401 without a key, 401 with a wrong one, then a 429 inside the cap" {
  run "$SCRIPT" "$BASE" --key demo-key
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  documentation: $BASE/openapi.json is 3.1.0 with 5 operations"* ]]
  [[ "$output" == *"PASS  no key: GET /rest/v1/ -> 401"* ]]
  [[ "$output" == *"PASS  wrong key: GET /rest/v1/ -> 401"* ]]
  [[ "$output" == *"PASS  right key: GET /rest/v1/ -> 200, limit 5, 4 left"* ]]
  # 9 at the earliest (4 opening requests, then the 4 left, then one over). Kong's counter
  # lags a burst (15 measured on 2026-11-04), so only the bounds are asserted.
  [[ "$output" =~ "PASS  rate limit: request "([0-9]+)" -> 429" ]]
  [ "${BASH_REMATCH[1]}" -ge 9 ] && [ "${BASH_REMATCH[1]}" -le 30 ]
  [[ "$output" == *"retry-after:"* ]]
}

@test "stops with FAIL instead of exceeding --max" {
  run "$SCRIPT" "$BASE" --key demo-key --no-docs --max 5
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP  documentation (--no-docs)"* ]]
  [[ "$output" == *"FAIL  the 429 needs 5 more requests"* ]]
  [[ "$output" != *"-> 429"* ]]
}

@test "a key the gateway does not know is not taken for the right one" {
  run "$SCRIPT" "$BASE" --key wrong --no-docs
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  right key: GET /rest/v1/ answered 401"* ]]
}

@test "no key at all is a usage error" {
  API_KEY='' run "$SCRIPT" "$BASE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"an API key is required"* ]]
}
