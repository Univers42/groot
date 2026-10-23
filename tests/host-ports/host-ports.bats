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
  mkdir -p "$STUBS" "$ROOT" "$ROOT/infrastructure/tls/host-ports.d"
  # Copy the tracked nginx.conf so tests can verify it's not rewritten
  cp "$REPO/infrastructure/tls/nginx.conf" "$ROOT/infrastructure/tls/nginx.conf"
  cat >"$ROOT/docker-compose.yml" <<'COMPOSE'
services:
  app:
    ports:
      - "127.0.0.1:${OSIONOS_APP_HOST_PORT:-3001}:3001"
      - "127.0.0.1:${BETA_HOST_PORT:-8444}:8444"
      - "127.0.0.1:${GAMMA_HOST_PORT:-8445}:8445"
      - "127.0.0.1:${DELTA_HOST_PORT:-4322}:4322"
COMPOSE
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/ss"
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/docker"
  chmod +x "$STUBS"/*
  export HOST_PORTS_ROOT="$ROOT" HOST_PORTS_LISTENERS="$STUBS/ss" HOST_PORTS_DOCKER="$STUBS/docker"
  export LOG="$BATS_TEST_TMPDIR/invocations.log"
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

# override_port NAME — the value recorded for NAME in host-ports.d/osionos-origin.conf.
override_port() {
  sed -n "s/.*localhost:\([0-9]*\);/\1/p" "$ROOT/infrastructure/tls/host-ports.d/osionos-origin.conf"
}

@test "list prints every scraped NAME=default, sorted and unique" {
  run bash "$REPO/scripts/host-ports.sh" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[0]}" = "BETA_HOST_PORT=8444" ]
  [ "${lines[1]}" = "DELTA_HOST_PORT=4322" ]
  [ "${lines[2]}" = "GAMMA_HOST_PORT=8445" ]
  [ "${lines[3]}" = "OSIONOS_APP_HOST_PORT=3001" ]
}

@test "list refuses a NAME that carries two different defaults" {
  cat >"$ROOT/docker-compose.local.yml" <<'COMPOSE'
services:
  other:
    ports:
      - "127.0.0.1:${OSIONOS_APP_HOST_PORT:-9999}:3001"
COMPOSE
  run bash "$REPO/scripts/host-ports.sh" list
  [ "$status" -eq 2 ]
  [[ "$output" == *"OSIONOS_APP_HOST_PORT"* ]]
  [[ "$output" == *"docker-compose.local.yml"* ]]
  [[ "$output" == *"docker-compose.yml"* ]]
}

@test "every default free: .env.ports holds them and nothing is printed" {
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(port OSIONOS_APP_HOST_PORT)" = "3001" ]
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
  [ "$(port OSIONOS_APP_HOST_PORT)" = "3001" ]
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

@test "invalid environment ports fail before either generated file changes" {
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  cp "$ROOT/.env.ports" "$BATS_TEST_TMPDIR/ports.before"
  cp "$ROOT/infrastructure/tls/host-ports.d/osionos-origin.conf" "$BATS_TEST_TMPDIR/origin.before"
  for value in 0 65536 -1 1.5 abc '3001;bad' $'3001\nINJECTED=1' 999999999999999999999; do
    OSIONOS_APP_HOST_PORT="$value" run bash "$REPO/scripts/host-ports.sh" resolve
    [ "$status" -eq 2 ]
    [[ "$output" == *"OSIONOS_APP_HOST_PORT must be an integer port from 1 through 65535"* ]]
    cmp -s "$ROOT/.env.ports" "$BATS_TEST_TMPDIR/ports.before"
    cmp -s "$ROOT/infrastructure/tls/host-ports.d/osionos-origin.conf" "$BATS_TEST_TMPDIR/origin.before"
  done
}

@test "port range endpoints and decimal ports with leading zeros are accepted" {
  for value in 1 65535 03001; do
    OSIONOS_APP_HOST_PORT="$value" run bash "$REPO/scripts/host-ports.sh" resolve
    [ "$status" -eq 0 ]
    [ "$(port OSIONOS_APP_HOST_PORT)" -eq "$((10#$value))" ]
    [ "$(override_port OSIONOS_APP_HOST_PORT)" -eq "$((10#$value))" ]
  done
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

# ── New tests for the fix ── #

@test "a moved OSIONOS_APP_HOST_PORT writes the override file with that port, and nginx.conf is byte-identical before and after resolve" {
  # First, copy the tracked nginx.conf to a temp location for comparison
  cp "$ROOT/infrastructure/tls/nginx.conf" "$BATS_TEST_TMPDIR/nginx.conf.before"

  # Make 3001 busy so OSIONOS_APP_HOST_PORT moves
  listeners "LISTEN 0 4096 127.0.0.1:3001 0.0.0.0:* users:((\"dev-server\",pid=7,fd=3))"
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port OSIONOS_APP_HOST_PORT)" = "3002" ]
  [ "$(override_port OSIONOS_APP_HOST_PORT)" = "3002" ]

  # nginx.conf should be unchanged (tracked file never rewritten)
  cmp -s "$ROOT/infrastructure/tls/nginx.conf" "$BATS_TEST_TMPDIR/nginx.conf.before"
}

@test "a second resolve leaves the override file's mtime unchanged" {
  listeners "LISTEN 0 4096 127.0.0.1:3001 0.0.0.0:* users:((\"dev-server\",pid=7,fd=3))"
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  before=$(stat -c %Y "$ROOT/infrastructure/tls/host-ports.d/osionos-origin.conf")
  sleep 1
  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  after=$(stat -c %Y "$ROOT/infrastructure/tls/host-ports.d/osionos-origin.conf")
  [ "$before" = "$after" ]
}

@test "the ss stub and the docker stub are each invoked exactly once per resolve even when a default is busy and the walk tests many ports" {
  # Create wrappers that log invocations
  : >"$LOG"

  cat >"$STUBS/ss" <<'SS'
#!/bin/sh
echo "ss invoked" >>"$LOG"
cat <<'LISTENERS'
LISTEN 0 4096 127.0.0.1:3001 0.0.0.0:* users:(("dev-server",pid=7,fd=3))
LISTEN 0 4096 127.0.0.1:3002 0.0.0.0:* users:(("busy",pid=8,fd=3))
LISTEN 0 4096 127.0.0.1:3003 0.0.0.0:* users:(("busy",pid=9,fd=3))
LISTEN 0 4096 127.0.0.1:3004 0.0.0.0:* users:(("busy",pid=10,fd=3))
LISTEN 0 4096 127.0.0.1:3005 0.0.0.0:* users:(("busy",pid=11,fd=3))
LISTEN 0 4096 127.0.0.1:3006 0.0.0.0:* users:(("busy",pid=12,fd=3))
LISTEN 0 4096 127.0.0.1:3007 0.0.0.0:* users:(("busy",pid=13,fd=3))
LISTEN 0 4096 127.0.0.1:3008 0.0.0.0:* users:(("busy",pid=14,fd=3))
LISTEN 0 4096 127.0.0.1:3009 0.0.0.0:* users:(("busy",pid=15,fd=3))
LISTEN 0 4096 127.0.0.1:3010 0.0.0.0:* users:(("busy",pid=16,fd=3))
LISTEN 0 4096 127.0.0.1:3011 0.0.0.0:* users:(("busy",pid=17,fd=3))
LISTEN 0 4096 127.0.0.1:3012 0.0.0.0:* users:(("busy",pid=18,fd=3))
LISTEN 0 4096 127.0.0.1:3013 0.0.0.0:* users:(("busy",pid=19,fd=3))
LISTEN 0 4096 127.0.0.1:3014 0.0.0.0:* users:(("busy",pid=20,fd=3))
LISTEN 0 4096 127.0.0.1:3015 0.0.0.0:* users:(("busy",pid=21,fd=3))
LISTEN 0 4096 127.0.0.1:3016 0.0.0.0:* users:(("busy",pid=22,fd=3))
LISTEN 0 4096 127.0.0.1:3017 0.0.0.0:* users:(("busy",pid=23,fd=3))
LISTEN 0 4096 127.0.0.1:3018 0.0.0.0:* users:(("busy",pid=24,fd=3))
LISTEN 0 4096 127.0.0.1:3019 0.0.0.0:* users:(("busy",pid=25,fd=3))
LISTEN 0 4096 127.0.0.1:3020 0.0.0.0:* users:(("busy",pid=26,fd=3))
LISTEN 0 4096 127.0.0.1:3021 0.0.0.0:* users:(("busy",pid=27,fd=3))
LISTEN 0 4096 127.0.0.1:3022 0.0.0.0:* users:(("busy",pid=28,fd=3))
LISTEN 0 4096 127.0.0.1:3023 0.0.0.0:* users:(("busy",pid=29,fd=3))
LISTEN 0 4096 127.0.0.1:3024 0.0.0.0:* users:(("busy",pid=30,fd=3))
LISTEN 0 4096 127.0.0.1:3025 0.0.0.0:* users:(("busy",pid=31,fd=3))
LISTEN 0 4096 127.0.0.1:3026 0.0.0.0:* users:(("busy",pid=32,fd=3))
LISTEN 0 4096 127.0.0.1:3027 0.0.0.0:* users:(("busy",pid=33,fd=3))
LISTEN 0 4096 127.0.0.1:3028 0.0.0.0:* users:(("busy",pid=34,fd=3))
LISTEN 0 4096 127.0.0.1:3029 0.0.0.0:* users:(("busy",pid=35,fd=3))
LISTEN 0 4096 127.0.0.1:3030 0.0.0.0:* users:(("busy",pid=36,fd=3))
LISTEN 0 4096 127.0.0.1:3031 0.0.0.0:* users:(("busy",pid=37,fd=3))
LISTEN 0 4096 127.0.0.1:3032 0.0.0.0:* users:(("busy",pid=38,fd=3))
LISTEN 0 4096 127.0.0.1:3033 0.0.0.0:* users:(("busy",pid=39,fd=3))
LISTEN 0 4096 127.0.0.1:3034 0.0.0.0:* users:(("busy",pid=40,fd=3))
LISTEN 0 4096 127.0.0.1:3035 0.0.0.0:* users:(("busy",pid=41,fd=3))
LISTEN 0 4096 127.0.0.1:3036 0.0.0.0:* users:(("busy",pid=42,fd=3))
LISTEN 0 4096 127.0.0.1:3037 0.0.0.0:* users:(("busy",pid=43,fd=3))
LISTEN 0 4096 127.0.0.1:3038 0.0.0.0:* users:(("busy",pid=44,fd=3))
LISTEN 0 4096 127.0.0.1:3039 0.0.0.0:* users:(("busy",pid=45,fd=3))
LISTEN 0 4096 127.0.0.1:3040 0.0.0.0:* users:(("busy",pid=46,fd=3))
LISTEN 0 4096 127.0.0.1:3041 0.0.0.0:* users:(("busy",pid=47,fd=3))
LISTEN 0 4096 127.0.0.1:3042 0.0.0.0:* users:(("busy",pid=48,fd=3))
LISTEN 0 4096 127.0.0.1:3043 0.0.0.0:* users:(("busy",pid=49,fd=3))
LISTEN 0 4096 127.0.0.1:3044 0.0.0.0:* users:(("busy",pid=50,fd=3))
LISTEN 0 4096 127.0.0.1:3045 0.0.0.0:* users:(("busy",pid=51,fd=3))
LISTEN 0 4096 127.0.0.1:3046 0.0.0.0:* users:(("busy",pid=52,fd=3))
LISTEN 0 4096 127.0.0.1:3047 0.0.0.0:* users:(("busy",pid=53,fd=3))
LISTEN 0 4096 127.0.0.1:3048 0.0.0.0:* users:(("busy",pid=54,fd=3))
LISTEN 0 4096 127.0.0.1:3049 0.0.0.0:* users:(("busy",pid=55,fd=3))
LISTEN 0 4096 127.0.0.1:3050 0.0.0.0:* users:(("busy",pid=56,fd=3))
LISTENERS
SS
  chmod +x "$STUBS/ss"

  cat >"$STUBS/docker" <<'DOCKER'
#!/bin/sh
echo "docker invoked" >>"$LOG"
cat <<'PORTS'
PORTS
DOCKER
  chmod +x "$STUBS/docker"

  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port OSIONOS_APP_HOST_PORT)" = "3051" ]

  # Count invocations
  ss_count=$(grep -c "ss invoked" "$LOG" || true)
  docker_count=$(grep -c "docker invoked" "$LOG" || true)
  [ "$ss_count" -eq 1 ]
  [ "$docker_count" -eq 1 ]
}

@test "a failing docker stub prints the warning once and the run still resolves" {
  cat >"$STUBS/docker" <<'DOCKER'
#!/bin/sh
exit 1
DOCKER
  chmod +x "$STUBS/docker"

  run bash "$REPO/scripts/host-ports.sh" resolve
  [ "$status" -eq 0 ]
  [ "$(port OSIONOS_APP_HOST_PORT)" = "3001" ]
  # Warning should appear exactly once on stderr
  warning_count=$(printf '%s\n' "$output" | grep -c "cannot list this project's containers" || true)
  [ "$warning_count" -eq 1 ]
  [[ "$output" == *"a running groot's own ports look busy"* ]]
}

@test "utils/mk/common.mk contains no shell sed that can run without a file argument" {
  # The HOST_PORT_NAMES line must contain $(wildcard .env.ports) inside an $(if
  grep -n 'HOST_PORT_NAMES' "$REPO/utils/mk/common.mk" | grep -q '\$(if.*\$(wildcard .env.ports)'
}

@test "git ls-files infrastructure/tls contains no nginx.conf.template and no host-ports.d/*.conf" {
  # nginx.conf.template should not exist (deleted)
  [ ! -f "$REPO/infrastructure/tls/nginx.conf.template" ]
  # host-ports.d/.gitkeep should exist (tracked in git)
  [ -f "$REPO/infrastructure/tls/host-ports.d/.gitkeep" ]
  # .gitignore should ignore *.conf in host-ports.d
  grep -q 'infrastructure/tls/host-ports.d/\*.conf' "$REPO/.gitignore"
}

@test "make preserves an environment-pinned host port over the saved .env.ports value" {
  printf 'OSIONOS_APP_HOST_PORT=3001\n' >"$ROOT/.env.ports"
  mkdir -p "$ROOT/scripts"
  ln -s "$REPO/scripts/host-ports.sh" "$ROOT/scripts/host-ports.sh"
  cat >"$ROOT/Makefile" <<MAKEFILE
include $REPO/utils/mk/common.mk
show-host-port:
	@printf '%s\\n' "\$(OSIONOS_APP_HOST_PORT)"
MAKEFILE
  run bash -c 'cd "$1" && OSIONOS_APP_HOST_PORT=4324 make -s TRACK_BINOCLE_BIND_ADDR=127.0.0.1 -f Makefile show-host-port' _ "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "4324" ]
}
