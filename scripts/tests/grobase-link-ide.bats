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
# The "direct" tests run `grobase-link.sh up` with GROBASE_IDE_SSH and an ssh stub recording every
# argv in ssh.log, so "no ssh call" and "one forward ending :4100" are asserted on the calls.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link-ide.bats

bats_require_minimum_version 1.5.0

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

# direct_up [ENV=value...] — `up` against a direct target; docker answers the reachability probe,
# ssh is the recorder: no master answers `-O check`, opening one fails when FAIL_MASTER=1, the
# plane probe reports one healthy plane.
direct_up() {
  SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"
  : >"$SSH_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/docker"
  printf '#!/bin/sh\necho "192.168.1.132 STREAM h"\n' >"$BATS_TEST_TMPDIR/bin/getent"
  {
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%s\n' "'$SSH_LOG'"
    cat <<'STUB'
case "$*" in
*"-O check"*) exit 1 ;;
*ControlMaster=yes*) [ -z "$FAIL_MASTER" ] || exit 255 ;;
*"sh -s"*)
  case "$(cat)" in
  *osionos-ide-plane*) echo "healthy 172.30.0.5" ;;
  *) echo "P /mini-baas-kong 8000/tcp 127.0.0.1:8000" ;;
  esac ;;
esac
exit 0
STUB
  } >"$BATS_TEST_TMPDIR/bin/ssh"
  chmod +x "$BATS_TEST_TMPDIR"/bin/*
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run env GROBASE_TARGET=https://kong.example.org "$@" bash "$SCRIPT" up
}

@test "up direct: GROBASE_IDE_SSH unset makes no ssh call at all" {
  direct_up
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/ssh.log" ]
}

@test "up direct: GROBASE_IDE_SSH opens one master to the alias and exactly one forward, to :4100" {
  direct_up
  cp "$GROBASE_LINK_DIR/routes" "$BATS_TEST_TMPDIR/routes.unset"
  direct_up GROBASE_IDE_SSH=b2b
  [ "$status" -eq 0 ]
  [ "$(grep -c 'ControlMaster=yes' "$BATS_TEST_TMPDIR/ssh.log")" -eq 1 ]
  [ "$(grep -c -- '-O forward' "$BATS_TEST_TMPDIR/ssh.log")" -eq 1 ]
  grep -- '-O forward' "$BATS_TEST_TMPDIR/ssh.log" | grep -q -- "-L $GROBASE_LINK_DIR/ide/ide-server-4100.sock:172.30.0.5:4100 x"
  [ "$(wc -l <"$GROBASE_LINK_DIR/forwards")" -eq 1 ]
  cmp "$GROBASE_LINK_DIR/routes" "$BATS_TEST_TMPDIR/routes.unset"
  [[ "$output" == *"IDE plane relayed"* ]]
}

@test "up direct: a failing ssh master is a note, exit 0, and the routes are those of the unset run" {
  direct_up
  cp "$GROBASE_LINK_DIR/routes" "$BATS_TEST_TMPDIR/routes.unset"
  direct_up GROBASE_IDE_SSH=b2b FAIL_MASTER=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"no ssh master to b2b"* ]]
  cmp "$GROBASE_LINK_DIR/routes" "$BATS_TEST_TMPDIR/routes.unset"
  run ! grep -q -- '-O forward' "$BATS_TEST_TMPDIR/ssh.log"
}

@test "up direct: an alias that is not plain (leading dash, space, quote) is refused naming the key, with no ssh call" {
  local bad
  for bad in '-oProxyCommand=x' '--help' 'a b' "a'b" 'a;b' '.x'; do
    direct_up GROBASE_IDE_SSH="$bad"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GROBASE_IDE_SSH is not a plain ssh alias"* ]]
    [ ! -s "$BATS_TEST_TMPDIR/ssh.log" ]
  done
}

@test "up direct: the alias is read from the settings file when the environment has none" {
  printf 'GROBASE_IDE_SSH=from-file\n' >"$BATS_TEST_TMPDIR/conf.env"
  direct_up GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/conf.env"
  [ "$status" -eq 0 ]
  grep -q 'from-file' "$BATS_TEST_TMPDIR/ssh.log"
}

@test "up ssh: GROBASE_IDE_SSH is ignored, the ssh target alone is used" {
  direct_up
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run env GROBASE_TARGET=ssh://box GROBASE_IDE_SSH=other bash "$SCRIPT" up
  [ "$status" -eq 0 ]
  [ -s "$SSH_LOG" ]
  run ! grep -q other "$BATS_TEST_TMPDIR/ssh.log"
}

@test "down: closes the IDE master (-O exit) and cancels its forward" {
  command -v perl >/dev/null 2>&1 || skip "perl is needed to make the control socket"
  direct_up GROBASE_IDE_SSH=b2b
  perl -MSocket -e "socket(S, PF_UNIX, SOCK_STREAM, 0); bind(S, sockaddr_un('$GROBASE_LINK_DIR/ssh.ctl'))"
  : >"$SSH_LOG"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$SCRIPT" down
  [ "$status" -eq 0 ]
  grep -q -- '-O cancel -L .*ide-server-4100.sock:172.30.0.5:4100' "$SSH_LOG"
  grep -q -- '-O exit' "$SSH_LOG"
  [ ! -e "$GROBASE_LINK_DIR/ssh.ctl" ]
}

@test "DOCKER_ROOTLESS is 1 on a rootless daemon and empty on a rootful one; the IDE relay's uid follows it" {
  local repo="$BATS_TEST_DIRNAME/../.." bin="$BATS_TEST_TMPDIR/rootless-bin"
  mkdir -p "$bin"
  print_rootless() { PATH="$bin:$PATH" make -s --no-print-directory -C "$repo" -f infrastructure/makes/common.mk -E 'p: ; @echo "[$(DOCKER_ROOTLESS)]"' p; }
  printf '#!/bin/sh\necho "[name=seccomp,profile=builtin name=rootless name=cgroupns]"\n' >"$bin/docker"
  chmod +x "$bin/docker"
  run print_rootless
  [ "$output" = "[1]" ]
  printf '#!/bin/sh\necho "[name=apparmor name=seccomp,profile=builtin]"\n' >"$bin/docker"
  run print_rootless
  [ "$output" = "[]" ]
  grep -q 'GROBASE_LINK_UID="$(if $(DOCKER_ROOTLESS),0,$$(id -u))" GROBASE_LINK_GID="$(if $(DOCKER_ROOTLESS),0,$$(id -g))"' \
    "$repo/infrastructure/makes/grobase-link.mk"
}

@test "make link: the grobase-link-ide relay is started on ide-linked in ssh and direct modes" {
  local mk="$BATS_TEST_DIRNAME/../../infrastructure/makes/grobase-link.mk"
  grep -q '= ssh \] || \[ "\$\$(\$(LINK_SCRIPT) mode)" = direct \]; then' "$mk"
  grep -q 'if \$(LINK_SCRIPT) ide-linked; then' "$mk"
}
