#!/usr/bin/env bats
# scripts/grobase-link-set.sh — `make link-set` writes where grobase is into the file `make link`
# reads, refusing a malformed value before it touches the file. The closing probe is
# grobase-paths.sh's own job (its bats); here LINK_SET_PROBE=0 except where its exit is the point.
# Synthetic files only: no ssh, no docker, no network.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link-set.bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/../.."
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/link.env" LINK_SET_PROBE=0
}
set_link() { run bash "$ROOT/scripts/grobase-link-set.sh" "$@" </dev/null; }

@test "a new file starts from the example's comments and gets the keys, private" {
  set_link GROBASE_TARGET=ssh://dev@vm.lan:2222 GROBASE_API_URL=https://vm.example.ts.net:8443
  [ "$status" -eq 0 ]
  grep -q '^# .env.grobase-link' "$GROBASE_LINK_CONF"
  grep -qx 'GROBASE_TARGET=ssh://dev@vm.lan:2222' "$GROBASE_LINK_CONF"
  grep -qx 'GROBASE_API_URL=https://vm.example.ts.net:8443' "$GROBASE_LINK_CONF"
  [ "$(stat -c %a "$GROBASE_LINK_CONF")" = 600 ]
}

@test "rewrites a key in place and leaves the others" {
  printf 'GROBASE_TARGET=local\nGROBASE_LINK_HOST_PORT=28000\n' >"$GROBASE_LINK_CONF"
  set_link GROBASE_TARGET=https://baas.example.net
  [ "$status" -eq 0 ]
  [ "$(cat "$GROBASE_LINK_CONF")" = "$(printf 'GROBASE_TARGET=https://baas.example.net\nGROBASE_LINK_HOST_PORT=28000')" ]
}

@test "an empty value clears the key" {
  printf 'GROBASE_CONNECT_IP=10.0.0.5\n' >"$GROBASE_LINK_CONF"
  set_link GROBASE_CONNECT_IP=
  [ "$status" -eq 0 ]
  grep -qx 'GROBASE_CONNECT_IP=' "$GROBASE_LINK_CONF"
}

@test "a malformed value is refused before the file is touched" {
  printf 'GROBASE_TARGET=local\n' >"$GROBASE_LINK_CONF"
  for bad in GROBASE_TARGET=ftp://x GROBASE_API_URL=http://plain.example GROBASE_IDE_SSH=-oProxyCommand=x \
    GROBASE_CONNECT_IP=vm.lan GROBASE_LINK_HOST_PORT=70000 GROBASE_REMOTE_DIR=relative GROBASE_CA_FILE=/nope.pem \
    GROBASE_PASSWORD=x 'GROBASE_TARGET=ssh://h;id'; do
    set_link GROBASE_TARGET=ssh://ok "$bad"
    [ "$status" -eq 1 ] || { echo "accepted: $bad" && false; }
  done
  [ "$(cat "$GROBASE_LINK_CONF")" = GROBASE_TARGET=local ]
}

@test "a CA file must hold a PEM certificate" {
  printf 'not a cert\n' >"$BATS_TEST_TMPDIR/ca.pem"
  set_link GROBASE_CA_FILE="$BATS_TEST_TMPDIR/ca.pem"
  [ "$status" -eq 1 ]
  printf -- '-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n' >"$BATS_TEST_TMPDIR/ca.pem"
  set_link GROBASE_CA_FILE="$BATS_TEST_TMPDIR/ca.pem"
  [ "$status" -eq 0 ]
}

@test "no key and no terminal prints the settings and writes nothing" {
  printf 'GROBASE_TARGET=ssh://b2b\n' >"$GROBASE_LINK_CONF"
  set_link
  [ "$status" -eq 0 ]
  [[ $output == *GROBASE_TARGET=ssh://b2b* ]]
  [ "$(cat "$GROBASE_LINK_CONF")" = GROBASE_TARGET=ssh://b2b ]
}

@test "the probe's failure is the exit, after the write" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "curl: (7) refused" >&2\nexit 7\n' >"$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" LINK_SET_PROBE=1 set_link GROBASE_TARGET=local GROBASE_API_URL=https://127.0.0.1:1
  [ "$status" -eq 1 ]
  [[ $output == *"saved, but not every path answers"* ]]
  grep -qx 'GROBASE_TARGET=local' "$GROBASE_LINK_CONF"
}
