#!/usr/bin/env bats
# scripts/verify/https-only.sh fails when the resolved compose config or the env file hands a
# plaintext URL to anything outside the backend, or publishes a plaintext port beyond loopback.
# Fixtures under BATS_TEST_TMPDIR; the last test runs it against the repo itself.
#   bats tests/https-only

bats_require_minimum_version 1.5.0

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  SCRIPT="$REPO/scripts/verify/https-only.sh"
  FIX=$BATS_TEST_TMPDIR
  printf 'INTERNAL_URL=http://kong:8000\n' >"$FIX/env"
  export HTTPS_ONLY_ENV_FILE="$FIX/env" HTTPS_ONLY_COMPOSE_FILES="$FIX/compose.yml"
}

compose() { cat >"$FIX/compose.yml"; }

@test "internal service URLs and TLS proxy ports pass" {
  compose <<'YML'
services:
  local-https-proxy:
    image: nginx
    ports: ["${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:4000:4000"]
  bridge:
    image: node
    environment:
      LIVEKIT_URL: http://livekit:7880
      LIVEKIT_CLIENT_URL: wss://localhost:4000/livekit
    ports: ["127.0.0.1:7880:7880"]
YML
  run -0 "$SCRIPT"
  [[ "$output" == *"PASS"* ]]
}

@test "a ws:// URL on a browser-reachable host fails" {
  compose <<'YML'
services:
  bridge:
    image: node
    environment:
      LIVEKIT_CLIENT_URL: ws://127.0.0.1:7880
YML
  run -1 "$SCRIPT"
  [[ "$output" == *"FAIL"*"bridge LIVEKIT_CLIENT_URL=ws://127.0.0.1:7880"* ]]
}

@test "an http:// build arg baked into a bundle fails" {
  compose <<'YML'
services:
  web:
    build:
      context: .
      args:
        VITE_BAAS_URL: http://example.com:8000
YML
  run -1 "$SCRIPT"
  [[ "$output" == *"web VITE_BAAS_URL=http://example.com:8000"* ]]
}

@test "a plaintext URL in the env file fails" {
  compose <<'YML'
services:
  bridge:
    image: node
YML
  printf 'LIVEKIT_CLIENT_URL=ws://127.0.0.1:7880\n' >>"$FIX/env"
  run -1 "$SCRIPT"
  [[ "$output" == *"env LIVEKIT_CLIENT_URL=ws://127.0.0.1:7880"* ]]
}

@test "a non-proxy port on the VM bind address fails" {
  compose <<'YML'
services:
  web:
    image: nginx
    ports: ["${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:4323:8080"]
YML
  run -1 "$SCRIPT"
  [[ "$output" == *"web publishes 0.0.0.0:4323->8080/tcp"* ]]
}

@test "LiveKit media ports may leave loopback, its signalling port may not" {
  compose <<'YML'
services:
  livekit:
    image: livekit
    ports:
      - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:7880:7880"
      - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:7881:7881"
      - "${TRACK_BINOCLE_BIND_ADDR:-127.0.0.1}:50000-50001:50000-50001/udp"
YML
  run -1 "$SCRIPT"
  [[ "$output" == *"livekit publishes 0.0.0.0:7880->7880/tcp"* ]]
  [[ "$output" != *"7881"* ]]
  [[ "$output" != *"50000"* ]]
}

@test "the repo's own compose files and .env.example pass" {
  unset HTTPS_ONLY_ENV_FILE HTTPS_ONLY_COMPOSE_FILES
  run -0 "$SCRIPT"
}
