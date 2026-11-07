#!/usr/bin/env bats
# scripts/cert-trust-mode.sh picks how make all trusts the local CA, and must never stop at a
# password on the host. sudo is a stub.

setup() {
  MODE="$BATS_TEST_DIRNAME/../cert-trust-mode.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  printf '#!/bin/sh\nexit 1\n' >"$BIN/sudo"
  chmod +x "$BIN/sudo"
}

@test "sudo that wants a password: browsers only, never a prompt" {
  run bash "$MODE"
  [ "$output" = user ]
}

@test "auto is the default spelling too" {
  run bash "$MODE" auto
  [ "$output" = user ]
}

@test "passwordless sudo keeps the system store" {
  printf '#!/bin/sh\nexit 0\n' >"$BIN/sudo"
  run bash "$MODE"
  [ "$output" = system ]
}

@test "the sudo check never waits on a password" {
  printf '#!/bin/sh\necho "$*" >"%s/args"\nexit 1\n' "$BATS_TEST_TMPDIR" >"$BIN/sudo"
  run bash "$MODE"
  [ "$(cat "$BATS_TEST_TMPDIR/args")" = "-n true" ]
}

@test "no sudo binary at all: browsers only" {
  rm "$BIN/sudo"
  PATH="$BIN:/usr/bin:/bin" run bash "$MODE"
  [ "$output" = user ]
}

@test "an explicit mode stands, whatever the rights" {
  run bash "$MODE" system
  [ "$output" = system ]
  run bash "$MODE" skip
  [ "$output" = skip ]
}
