#!/usr/bin/env bats
# grobase-link-ide.bats — the ssh link's IDE plane relay: selecting the VM's
# osionos-ide-server by compose labels, forwarding its 4100 to a socket, and
# answering to its name only on the edge network. These tests source
# scripts/grobase-link.sh (which sources the IDE lib) and cover the pure parts:
# the endpoint filter, the forward-or-note decision, the socket check and the
# verb's exit codes, with `mux`/`forward`/`note` as bash functions — no ssh, no
# docker, no network.
#
# Ponytail: the 172.18.0.x addresses are examples; a real plane address differs
# and the filter accepts any IPv4, so a test IP never proves a live forward.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link-ide.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../grobase-link.sh"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/absent.env"
}

helper() { run bash -c "source '$SCRIPT' && $1"; }

@test "ide_plane_endpoint: one healthy line becomes ok" {
  helper 'mux() { cat >/dev/null; printf "healthy 172.18.0.5\n"; }; ide_plane_endpoint'
  [ "$status" -eq 0 ]
  [ "$output" = "ok 172.18.0.5" ]
}

@test "ide_plane_endpoint: no lines becomes none" {
  helper 'mux() { cat >/dev/null; printf ""; }; ide_plane_endpoint'
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "ide_plane_endpoint: two lines becomes many 2" {
  helper 'mux() { cat >/dev/null; printf "healthy 172.18.0.5\nhealthy 172.18.0.6\n"; }; ide_plane_endpoint'
  [ "$status" -eq 0 ]
  [ "$output" = "many 2" ]
}

@test "ide_plane_endpoint: a non-healthy status becomes unhealthy" {
  helper 'mux() { cat >/dev/null; printf "starting 172.18.0.5\n"; }; ide_plane_endpoint'
  [ "$status" -eq 0 ]
  [ "$output" = "unhealthy starting" ]
}

@test "ide_plane_endpoint: healthy without an edge address becomes noip" {
  helper 'mux() { cat >/dev/null; printf "healthy -\n"; }; ide_plane_endpoint'
  [ "$status" -eq 0 ]
  [ "$output" = "noip" ]
}

@test "link_ide_plane: the ok case forwards the socket to the plane IP" {
  helper 'mux() { cat >/dev/null; printf "healthy 172.18.0.9\n"; }; forward() { printf "forward %s %s\n" "$1" "$2"; }; note() { printf "note %s\n" "$*"; }; link_ide_plane'
  [ "$status" -eq 0 ]
  [[ "$output" == *"forward $GROBASE_LINK_DIR/ide/ide-server-4100.sock 172.18.0.9:4100"* ]]
  [[ "$output" == *"IDE plane relayed: osionos-ide-server -> 172.18.0.9:4100"* ]]
}

@test "link_ide_plane: without a plane it removes a stale socket and names the reason" {
  mkdir -p "$GROBASE_LINK_DIR/ide"
  : >"$GROBASE_LINK_DIR/ide/ide-server-4100.sock"
  helper 'mux() { cat >/dev/null; printf ""; }; forward() { printf "forward %s %s\n" "$1" "$2"; }; note() { printf "note %s\n" "$*"; }; link_ide_plane'
  [ "$status" -eq 0 ]
  [[ "$output" != *"forward "* ]]
  [ ! -e "$GROBASE_LINK_DIR/ide/ide-server-4100.sock" ]
  [[ "$output" == *"no IDE plane on the target"* ]]
}

@test "link_ide_plane: two planes refuse to pick one and remove the socket" {
  mkdir -p "$GROBASE_LINK_DIR/ide"
  : >"$GROBASE_LINK_DIR/ide/ide-server-4100.sock"
  helper 'mux() { cat >/dev/null; printf "healthy 172.18.0.5\nhealthy 172.18.0.6\n"; }; forward() { printf "forward %s %s\n" "$1" "$2"; }; note() { printf "note %s\n" "$*"; }; link_ide_plane'
  [ "$status" -eq 0 ]
  [[ "$output" != *"forward "* ]]
  [ ! -e "$GROBASE_LINK_DIR/ide/ide-server-4100.sock" ]
  [[ "$output" == *"2 IDE planes running; refusing to pick one"* ]]
}

@test "link_ide_plane: an unhealthy plane removes the socket and names the status" {
  mkdir -p "$GROBASE_LINK_DIR/ide"
  : >"$GROBASE_LINK_DIR/ide/ide-server-4100.sock"
  helper 'mux() { cat >/dev/null; printf "starting 172.18.0.5\n"; }; forward() { printf "forward %s %s\n" "$1" "$2"; }; note() { printf "note %s\n" "$*"; }; link_ide_plane'
  [ "$status" -eq 0 ]
  [[ "$output" != *"forward "* ]]
  [ ! -e "$GROBASE_LINK_DIR/ide/ide-server-4100.sock" ]
  [[ "$output" == *"starting"* ]]
}

@test "ide_linked: a missing or regular file is not linked; a socket is" {
  rm -rf "$GROBASE_LINK_DIR"
  helper 'ide_linked'
  [ "$status" -eq 1 ]
  mkdir -p "$GROBASE_LINK_DIR/ide"
  : >"$GROBASE_LINK_DIR/ide/ide-server-4100.sock"
  helper 'ide_linked'
  [ "$status" -eq 1 ]
  rm -f "$GROBASE_LINK_DIR/ide/ide-server-4100.sock"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import socket as s; q=s.socket(s.AF_UNIX); q.bind('$GROBASE_LINK_DIR/ide/ide-server-4100.sock')"
    helper 'ide_linked'
    [ "$status" -eq 0 ]
  elif command -v perl >/dev/null 2>&1; then
    perl -MSocket -e "socket(S, PF_UNIX, SOCK_STREAM, 0); bind(S, sockaddr_un('$GROBASE_LINK_DIR/ide/ide-server-4100.sock'))"
    helper 'ide_linked'
    [ "$status" -eq 0 ]
  else
    skip "neither python3 nor perl is on PATH to make a socket"
  fi
}

@test "grobase-link.sh ide-linked exits 1 with no link dir" {
  rm -rf "$GROBASE_LINK_DIR"
  run bash "$SCRIPT" ide-linked
  [ "$status" -eq 1 ]
}

@test "compose: grobase-link-ide answers only on the edge network" {
  command -v docker >/dev/null 2>&1 || skip "docker is not on PATH inside the bats container; the host gate checks the shape"
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH inside the bats container; the host gate checks the shape"
  run env GROBASE_LINK_DIR=/tmp/x docker compose -f "$BATS_TEST_DIRNAME/../../docker-compose.yml" -f "$BATS_TEST_DIRNAME/../../docker-compose.grobase-link.yml" --profile link-ide --env-file /dev/null config --format json
  [ "$status" -eq 0 ]
  jq -e '.services["grobase-link-ide"] | ((.ports // []) == []) and ((.networks | keys) == ["osionos-ide-edge-net"])' <<<"$output" >/dev/null
  jq -e '.services["grobase-link-ide"] | (.read_only == true) and (.cap_drop == ["ALL"])' <<<"$output" >/dev/null
  jq -e '.services["grobase-link-ide"] | ((.networks["osionos-ide-edge-net"].aliases // []) == ["osionos-ide-server"])' <<<"$output" >/dev/null
}
