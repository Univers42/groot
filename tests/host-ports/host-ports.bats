#!/usr/bin/env bats
# scripts/host-ports.sh picks the host ports the compose files publish: a busy default moves,
# a free one stays, and the choice is recorded in .env.ports. The listeners and the docker
# daemon are stubs (HOST_PORTS_LISTENERS / HOST_PORTS_DOCKER) and the compose files are a
# fixture under BATS_TEST_TMPDIR (HOST_PORTS_ROOT): nothing here touches the real host.
#   bats tests/host-ports

bats_require_minimum_version 1.5.0

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  STUBS=$BATS_TEST_TMPDIR/bin
  ROOT=$BATS_TEST_TMPDIR/root
  mkdir -p "$STUBS" "$ROOT"
  cat >"$ROOT/docker-compose.yml" <<'COMPOSE'
services:
  app:
    ports:
      - "127.0.0.1:${ALPHA_HOST_PORT:-3001}:3001"
      - "127.0.0.1:${BETA_HOST_PORT:-8444}:8444"
      - "127.0.0.1:${GAMMA_HOST_PORT:-8445}:8445"
      - "127.0.0.1:${DELTA_HOST_PORT:-4322}:4322"
COMPOSE
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/ss"
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/docker"
  chmod +x "$STUBS"/*
  export HOST_PORTS_ROOT="$ROOT" HOST_PORTS_LISTENERS="$STUBS/ss" HOST_PORTS_DOCKER="$STUBS/docker"
}

# listeners <line>... — the ss stub reports those listening sockets.
listeners() {
  {
    printf '#!/bin/sh\n'
    printf 'cat <<'"'"'LISTENERS'"'"'\n'
    printf '%s\n' "$@"
    printf 'LISTENERS\n'
  } >"$STUBS/ss"
  chmod +x "$STUBS/ss"
}

# our_containers <ports>... — the docker stub reports the ports this project publishes.
our_containers() {
  {
    printf '#!/bin/sh\n'
    printf 'cat <<'"'"'PORTS'"'"'\n'
    printf '%s\n' "$@"
    printf 'PORTS\n'
  } >"$STUBS/docker"
  chmod +x "$STUBS/docker"
}

# port NAME — the value recorded for NAME in .env.ports.
port() {
  sed -n "s/^$1=//p" "$ROOT/.env.ports"
}

@test "list prints every scraped NAME=default, sorted and unique" {
  run bash "$REPO/scripts/host-ports.sh" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[0]}" = "ALPHA_HOST_PORT=3001" ]
  [ "${lines[1]}" = "BETA_HOST_PORT=8444" ]
  [ "${lines[2]}" = "DELTA_HOST_PORT=4322" ]
  [ "${lines[3]}" = "GAMMA_HOST_PORT=8445" ]
}

@test "list refuses a NAME that carries two different defaults" {
  cat >"$ROOT/docker-compose.local.yml" <<'COMPOSE'
services:
  other:
    ports:
      - "127.0.0.1:${ALPHA_HOST_PORT:-9999}:3001"
COMPOSE
  run bash "$REPO/scripts/host-ports.sh" list
  [ "$status" -eq 2 ]
  [[ "$output" == *"ALPHA_HOST_PORT"* ]]
  [[ "$output" == *"docker-compose.local.yml"* ]]
  [[ "$output" == *"docker-compose.yml"* ]]
}

@test "every default free: .env.ports holds them and nothing is printed" {
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(port ALPHA_HOST_PORT)" = "3001" ]
  [ "$(port BETA_HOST_PORT)" = "8444" ]
  [ "$(port GAMMA_HOST_PORT)" = "8445" ]
  [ "$(port DELTA_HOST_PORT)" = "4322" ]
  head -1 "$ROOT/.env.ports" | grep -q "scripts/host-ports.sh resolve"
}

@test "a busy default moves to the next free port, skipping the one another NAME took" {
  listeners "LISTEN 0 4096 127.0.0.1:8444 0.0.0.0:* users:((\"qemu-system-x86\",pid=42,fd=3))"
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port BETA_HOST_PORT)" = "8446" ]
  [ "$(port GAMMA_HOST_PORT)" = "8445" ]
  [[ "$output" == *"BETA_HOST_PORT default 8444 is held by qemu-system-x86; using 8446"* ]]
}

@test "our own container keeps the port it publishes" {
  listeners "LISTEN 0 4096 127.0.0.1:3001 0.0.0.0:* users:((\"docker-proxy\",pid=9,fd=3))"
  our_containers "127.0.0.1:3001->3001/tcp"
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port ALPHA_HOST_PORT)" = "3001" ]
  [ -z "$output" ]
}

@test "a wildcard listener on 0.0.0.0:4322 conflicts" {
  listeners "LISTEN 0 4096 0.0.0.0:4322 0.0.0.0:* users:((\"dev-server\",pid=7,fd=3))"
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port DELTA_HOST_PORT)" = "4323" ]
}

@test "a listener on 192.168.1.5:4322 does not conflict with a 127.0.0.1 bind" {
  listeners "LISTEN 0 4096 192.168.1.5:4322 0.0.0.0:* users:((\"dev-server\",pid=7,fd=3))"
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port DELTA_HOST_PORT)" = "4322" ]
  [ -z "$output" ]
}

@test "a moved port stays while its default is busy, and goes back when it frees" {
  listeners "LISTEN 0 4096 127.0.0.1:8444 0.0.0.0:* users:((\"qemu-system-x86\",pid=42,fd=3))"
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port BETA_HOST_PORT)" = "8446" ]
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/ss"
  chmod +x "$STUBS/ss"
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port BETA_HOST_PORT)" = "8444" ]
}

@test "an explicit environment value wins even when it is busy" {
  listeners "LISTEN 0 4096 127.0.0.1:8444 0.0.0.0:* users:((\"qemu-system-x86\",pid=42,fd=3))"
  listeners "LISTEN 0 4096 127.0.0.1:9999 0.0.0.0:* users:((\"dev-server\",pid=7,fd=3))"
  BETA_HOST_PORT=9999 run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port BETA_HOST_PORT)" = "9999" ]
  [ -n "$output" ]
}

@test "no free port in the window: the NAME is named and the run fails" {
  {
    printf '#!/bin/sh\n'
    printf 'cat <<'"'"'LISTENERS'"'"'\n'
    for p in $(seq 8444 8494); do
      printf 'LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:* users:(("busy",pid=1,fd=3))\n' "$p"
    done
    printf 'LISTENERS\n'
  } >"$STUBS/ss"
  chmod +x "$STUBS/ss"
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 1 ]
  [[ "$output" == *"BETA_HOST_PORT"* ]]
  [[ "$output" == *"8444"* ]]
}

@test "a second resolve with nothing changed leaves the mtime alone" {
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  before=$(stat -c %Y "$ROOT/.env.ports")
  sleep 1
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  after=$(stat -c %Y "$ROOT/.env.ports")
  [ "$before" = "$after" ]
}

@test "no consumer keeps a literal localhost port" {
  for f in scripts/check-health-apps.sh scripts/showcase.sh utils/mk/common.mk; do
    out=$(sed -E 's/\$\{[A-Za-z0-9_]+:-[0-9]+\}/PORT/g' "$REPO/$f" |
      grep -nE 'localhost:(4322|3001|4000|8787|8444)' || true)
    [ -z "$out" ] || {
      echo "$f still hardcodes a localhost port:"
      echo "$out"
      false
    }
  done
}
