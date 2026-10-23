#!/usr/bin/env bats
# ide-plane.sh is the operator's kill switch (`off`) and per-user removal (`remove-user`) for the
# docker-ide daemon. A fake docker records "<DOCKER_HOST> <args>" per call and answers from files in
# $STATE: running.ids, all.ps ("<id> <owner>"), mounts.<id>, volumes, ledger. Plane calls must reach
# DOCKER_HOST, ledger calls must reach OSIONOS_IDE_LEDGER_DOCKER_HOST. Assertions read `status`,
# `output` or a grep count out of `run`; none is a bare negation.

OWNER_A=11111111-1111-4111-8111-111111111111
OWNER_B=22222222-2222-4222-8222-222222222222
WS_A=osio-ide-vol-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WS_B=osio-ide-vol-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PLANE=unix:///plane.sock
MAIN=unix:///main.sock

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  SCRIPT="$REPO/scripts/ide-plane.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$STATE"
  export STATE CALLS="$STATE/calls"
  : > "$CALLS"
  HOME_A=osio-ide-home-$(printf '%s' "$OWNER_A" | sha256sum | cut -c1-32)
  HOME_B=osio-ide-home-$(printf '%s' "$OWNER_B" | sha256sum | cut -c1-32)
  printf '{"owner":"%s","uid":20000}\n{"owner":"%s","uid":20001}\n' "$OWNER_A" "$OWNER_B" > "$STATE/ledger"
  printf 'c1 %s\nc2 %s\nc3 %s\n' "$OWNER_A" "$OWNER_B" "$OWNER_A" > "$STATE/all.ps"
  printf '%s\n%s\n%s\n' "$WS_A" "$HOME_A" pgdata > "$STATE/mounts.c1"
  printf '%s\n%s\n' "$WS_B" "$HOME_B" > "$STATE/mounts.c2"
  printf '%s\n' "$WS_A" > "$STATE/mounts.c3"
  printf '%s\n%s\n%s\n%s\npgdata\n' "$WS_A" "$WS_B" "$HOME_A" "$HOME_B" > "$STATE/volumes"
  printf 'c1\nc2\n' > "$STATE/running.ids"
  cat > "$BIN/docker" <<'FAKE'
#!/bin/sh
echo "${DOCKER_HOST:-none} $*" >> "$CALLS"
case "$1" in
  ps) if [ "$2" = -a ]; then cat "$STATE/all.ps"; else cat "$STATE/running.ids"; fi ;;
  stop) [ -z "$STOP_FAIL" ] || exit 1 ;;
  inspect) for last; do :; done; cat "$STATE/mounts.$last" ;;
  rm) ;;
  volume)
    case "$2" in
      inspect) grep -qx "$3" "$STATE/volumes" ;;
      rm) [ "$3" != "$VOL_RM_FAIL" ] || exit 1 ;;
    esac ;;
  exec)
    if [ "$2" = -i ]; then cat > "$STATE/ledger.new"
    else [ -z "$LEDGER_UNREADABLE" ] || exit 1; cat "$STATE/ledger"; fi ;;
  restart) ;;
esac
FAKE
  chmod +x "$BIN/docker"
  export PATH="$BIN:$PATH"
  export DOCKER_HOST=$PLANE OSIONOS_IDE_LEDGER_DOCKER_HOST=$MAIN
}

calls_matching() { grep -c -- "$1" "$CALLS" || true; }

@test "off without DOCKER_HOST: usage error, docker never called" {
  unset DOCKER_HOST
  run bash "$SCRIPT" off
  [ "$status" -eq 2 ]
  [ ! -s "$CALLS" ]
}

@test "off stops every managed box in one call on the given daemon and prints the count" {
  run bash "$SCRIPT" off
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped 2"* ]]
  [[ "$output" == *"OSIONOS_IDE_ACCESS=off"* ]]
  run grep -x "$PLANE stop -t 5 c1 c2" "$CALLS"
  [ "$status" -eq 0 ]
  run grep -x "$PLANE ps -q --filter label=osio.ide.managed=1" "$CALLS"
  [ "$status" -eq 0 ]
}

@test "off with no running box: stopped 0 and no stop call" {
  : > "$STATE/running.ids"
  run bash "$SCRIPT" off
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped 0"* ]]
  [ "$(calls_matching ' stop ')" = 0 ]
}

@test "off: a failing stop is exit 1, not a printed count" {
  STOP_FAIL=1 run bash "$SCRIPT" off
  [ "$status" -eq 1 ]
  [[ "$output" != *"stopped 2"* ]]
}

@test "remove-user without --yes: refused, no mutating call" {
  run bash "$SCRIPT" remove-user 20000
  [ "$status" -eq 2 ]
  [[ "$output" == *"--yes"* ]]
  [ "$(calls_matching ' rm ')" = 0 ]
  [ "$(calls_matching 'volume rm')" = 0 ]
  [ ! -e "$STATE/ledger.new" ]
  [ "$(calls_matching ' restart ')" = 0 ]
}

@test "remove-user rejects an argument that is neither a uid nor a digest" {
  run bash "$SCRIPT" remove-user 'x;rm -rf /' --yes
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" remove-user 123 --yes
  [ "$status" -eq 2 ]
  [ "$(calls_matching ' rm ')" = 0 ]
}

@test "remove-user by uid: that user's boxes and plane volumes go, nobody else's, and the ledger line" {
  run bash "$SCRIPT" remove-user 20000 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed containers=2 volumes=2 ledger=1 uid=20000"* ]]
  run grep -x "$PLANE rm -f c1" "$CALLS"; [ "$status" -eq 0 ]
  run grep -x "$PLANE rm -f c3" "$CALLS"; [ "$status" -eq 0 ]
  [ "$(calls_matching 'rm -f c2')" = 0 ]
  run grep -x "$PLANE volume rm $WS_A" "$CALLS"; [ "$status" -eq 0 ]
  run grep -x "$PLANE volume rm $HOME_A" "$CALLS"; [ "$status" -eq 0 ]
  [ "$(calls_matching "volume rm $WS_B")" = 0 ]
  [ "$(calls_matching "volume rm $HOME_B")" = 0 ]
  [ "$(calls_matching 'volume rm pgdata')" = 0 ]
  [ "$(calls_matching 'volume rm')" = 2 ]
}

@test "remove-user rewrites the ledger without the line, on the main daemon, then restarts the proxy" {
  run bash "$SCRIPT" remove-user 20000 --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/ledger.new")" = "{\"owner\":\"$OWNER_B\",\"uid\":20001}" ]
  run grep "^$MAIN exec -i osionos-ide-socket-proxy sh -c" "$CALLS"; [ "$status" -eq 0 ]
  run grep -x "$MAIN restart osionos-ide-socket-proxy" "$CALLS"; [ "$status" -eq 0 ]
  [ "$(calls_matching "^$PLANE exec")" = 0 ]
}

@test "remove-user by home digest resolves the same owner" {
  digest=${HOME_A#osio-ide-home-}
  run bash "$SCRIPT" remove-user "$digest" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"uid=20000"* ]]
  run grep -x "$PLANE volume rm $HOME_A" "$CALLS"; [ "$status" -eq 0 ]
}

@test "remove-user of the last ledger line leaves an empty ledger" {
  printf '{"owner":"%s","uid":20000}\n' "$OWNER_A" > "$STATE/ledger"
  run bash "$SCRIPT" remove-user 20000 --yes
  [ "$status" -eq 0 ]
  [ ! -s "$STATE/ledger.new" ]
}

@test "remove-user of a user with no boxes removes only the home volume" {
  printf 'c2 %s\n' "$OWNER_B" > "$STATE/all.ps"
  run bash "$SCRIPT" remove-user 20000 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed containers=0 volumes=1"* ]]
}

@test "remove-user for an unknown uid: exit 1, nothing removed" {
  run bash "$SCRIPT" remove-user 20009 --yes
  [ "$status" -eq 1 ]
  [ "$(calls_matching ' rm ')" = 0 ]
  [ ! -e "$STATE/ledger.new" ]
}

@test "remove-user: a volume that will not delete keeps the ledger line and does not restart the proxy" {
  VOL_RM_FAIL=$HOME_A run bash "$SCRIPT" remove-user 20000 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"ledger line kept"* ]]
  [ ! -e "$STATE/ledger.new" ]
  [ "$(calls_matching ' restart ')" = 0 ]
}

@test "remove-user: an unreadable ledger stops everything before any removal" {
  LEDGER_UNREADABLE=1 run bash "$SCRIPT" remove-user 20000 --yes
  [ "$status" -eq 1 ]
  [ "$(calls_matching ' rm ')" = 0 ]
  [ "$(calls_matching 'volume')" = 0 ]
}

@test "unknown subcommand: usage, exit 2" {
  run bash "$SCRIPT" nuke
  [ "$status" -eq 2 ]
}
