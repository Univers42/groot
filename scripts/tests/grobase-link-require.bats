#!/usr/bin/env bats
# GROBASE_LINK_REQUIRE names the one mode this host may link in (ruling LM-3, 2026-11-23). Without
# it a link whose resolution changed with no edit (a local mini-baas-kong appearing under `auto`, a
# settings file gone) silently switched this host's frontends to another grobase. With it, `up`
# exits non-zero before the ssh master, the forwards, the routes or the state change, so make link
# stops before it starts the relay. docker and ssh are stubs: nothing here reaches a daemon or host.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link-require.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../grobase-link.sh"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/link.env"
  export CAPABILITY_PAUSE=0
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$GROBASE_LINK_DIR"
  # The daemon here runs a Kong: `auto` resolves to local.
  printf '#!/bin/sh\necho "docker $*" >>"%s/docker.log"\ncase "$*" in "ps "*) echo mini-baas-kong ;; esac\n' \
    "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/docker"
  printf '#!/bin/sh\necho "ssh $*" >>"%s/ssh.log"\nexit 1\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/ssh"
  chmod +x "$BATS_TEST_TMPDIR"/bin/*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # A live ssh link, as the production host has it.
  printf 'mode=ssh\ntarget=b2b\nconnect_ip=\n' >"$GROBASE_LINK_DIR/state"
  printf '8000 UNIX-CONNECT:/link/kong-8000.sock\n' >"$GROBASE_LINK_DIR/routes"
  cp "$GROBASE_LINK_DIR/state" "$BATS_TEST_TMPDIR/state.before"
  cp "$GROBASE_LINK_DIR/routes" "$BATS_TEST_TMPDIR/routes.before"
}

link_untouched() {
  cmp "$GROBASE_LINK_DIR/state" "$BATS_TEST_TMPDIR/state.before"
  cmp "$GROBASE_LINK_DIR/routes" "$BATS_TEST_TMPDIR/routes.before"
  [ ! -e "$BATS_TEST_TMPDIR/ssh.log" ]
}

@test "mismatch: ssh required, a local Kong appears under auto: exit 1, the link untouched" {
  printf 'GROBASE_LINK_REQUIRE=ssh\n' >"$GROBASE_LINK_CONF"
  run bash "$SCRIPT" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"resolved to local"* ]]
  [[ "$output" == *"GROBASE_LINK_REQUIRE=ssh"* ]]
  [[ "$output" == *"$GROBASE_LINK_CONF"* ]]
  link_untouched
}

@test "mismatch: the environment's requirement (the unit's Environment=) wins over the file's" {
  printf 'GROBASE_TARGET=local\nGROBASE_LINK_REQUIRE=local\n' >"$GROBASE_LINK_CONF"
  GROBASE_LINK_REQUIRE=ssh run bash "$SCRIPT" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"GROBASE_LINK_REQUIRE=ssh"* ]]
  link_untouched
}

@test "mismatch: no settings file at all is named as such" {
  GROBASE_LINK_REQUIRE=direct run bash "$SCRIPT" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"$GROBASE_LINK_CONF does not exist"* ]]
  link_untouched
}

@test "a requirement that is not local, ssh or direct is refused before anything resolves" {
  GROBASE_LINK_REQUIRE=ssh-please run bash "$SCRIPT" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"GROBASE_LINK_REQUIRE=ssh-please"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/docker.log" ]
  link_untouched
}

@test "match: local required and resolved: exit 0, the link becomes local" {
  printf 'GROBASE_LINK_REQUIRE=local\n' >"$GROBASE_LINK_CONF"
  run bash "$SCRIPT" up
  [ "$status" -eq 0 ]
  grep -qx 'mode=local' "$GROBASE_LINK_DIR/state"
  [ ! -e "$GROBASE_LINK_DIR/routes" ]
}

@test "no requirement: today's behaviour, auto follows the local Kong" {
  run bash "$SCRIPT" up
  [ "$status" -eq 0 ]
  grep -qx 'mode=local' "$GROBASE_LINK_DIR/state"
}

@test "every up names the settings file it read the target from, or that it fell back to the default" {
  run bash "$SCRIPT" up
  [[ "$output" == *"target auto, the default: $GROBASE_LINK_CONF does not exist"* ]]
  printf 'GROBASE_LINK_HOST_PORT=0\n' >"$GROBASE_LINK_CONF"
  run bash "$SCRIPT" up
  [[ "$output" == *"target auto, the default: $GROBASE_LINK_CONF sets no GROBASE_TARGET"* ]]
  printf 'GROBASE_TARGET=local\n' >"$GROBASE_LINK_CONF"
  run bash "$SCRIPT" up
  [[ "$output" == *"target local, from $GROBASE_LINK_CONF"* ]]
  GROBASE_TARGET=local run bash "$SCRIPT" up
  [[ "$output" == *"target local, from the environment (settings file $GROBASE_LINK_CONF)"* ]]
}
