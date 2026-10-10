#!/usr/bin/env bats
# grobase-link.sh's parsers decide how the frontends reach grobase: a mis-read target
# would open the link to the wrong host, or probe nothing. These tests source the script
# (its dispatcher steps aside when sourced) and cover the pure helpers, the settings
# precedence, the state file and the exit codes only — no ssh, no docker, no network.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../grobase-link.sh"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  # Point the settings file away from the repo's real ./.env.grobase-link: a test must not
  # inherit this machine's target.
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/absent.env"
}

# Runs shell code in a bash that sourced the script, so its functions are callable.
helper() { run bash -c "source '$SCRIPT' && $1"; }
resolve_target() { run env GROBASE_TARGET="$1" bash -c "source '$SCRIPT' && resolve"; }

@test "ssh_args: ssh:// with user and port becomes dest plus -p" {
  helper 'ssh_args ssh://alice@10.0.0.7:2222'
  [ "$status" -eq 0 ]
  [ "$output" = "alice@10.0.0.7 -p 2222" ]
}

@test "ssh_args: an alias and a user@host pass through untouched" {
  helper 'ssh_args b2b; ssh_args ssh://alice@box'
  [ "$output" = $'b2b\nalice@box' ]
}

@test "url_hostport: the scheme sets the default port; explicit port and path are split off" {
  helper 'url_hostport http://kong.lan/; url_hostport https://api.example.org; url_hostport https://10.1.2.3:8443/x/y'
  [ "$output" = $'kong.lan 80\napi.example.org 443\n10.1.2.3 8443' ]
}

@test "resolve: an explicit target is taken as given, nothing is probed" {
  resolve_target local
  [ "$output" = "local local" ]
  resolve_target ssh://alice@box:2222
  [ "$output" = "ssh ssh://alice@box:2222" ]
  resolve_target https://kong.example.org
  [ "$output" = "direct https://kong.example.org" ]
}

@test "conf: the environment beats the file, the file beats the default; an unknown key exits 1" {
  printf '# this machine\nGROBASE_TARGET=ssh://box\n' >"$GROBASE_LINK_CONF"
  run bash "$SCRIPT" conf GROBASE_TARGET
  [ "$output" = ssh://box ]
  run env GROBASE_TARGET=local bash "$SCRIPT" conf GROBASE_TARGET
  [ "$output" = local ]
  run env GROBASE_TARGET= bash "$SCRIPT" conf GROBASE_TARGET # make's unset variable arrives empty
  [ "$output" = ssh://box ]
  run bash "$SCRIPT" conf GROBASE_LINK_HOST_PORT
  [ "$output" = 28000 ]
  run bash "$SCRIPT" conf NOPE
  [ "$status" -eq 1 ]
}

@test "conf: without a file every setting is its default; no key lists all three" {
  run bash "$SCRIPT" conf GROBASE_TARGET
  [ "$output" = auto ]
  run bash "$SCRIPT" conf
  [ "$status" -eq 0 ]
  [ "$output" = $'GROBASE_TARGET=auto\nGROBASE_LINK_HOST_PORT=28000\nGROBASE_REMOTE_DIR=/opt/grobase' ]
}

@test "resolve: the file's target is resolved like one from the environment" {
  printf 'GROBASE_TARGET=https://kong.example.org\n' >"$GROBASE_LINK_CONF"
  helper 'resolve'
  [ "$output" = "direct https://kong.example.org" ]
}

@test "state: set then get round-trips a target that contains ':' and '@'" {
  helper 'mkdir -p "$LINK_DIR"; state_set ssh ssh://alice@box:2222; state_get target; state_get mode'
  [ "$output" = $'ssh://alice@box:2222\nssh' ]
}

@test "mode and status: exit 1 with no link; mode prints the recorded mode once set" {
  run bash "$SCRIPT" mode
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"make link"* ]]
  mkdir -p "$GROBASE_LINK_DIR" && printf 'mode=direct\ntarget=https://k\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" mode
  [ "$status" -eq 0 ]
  [ "$output" = direct ]
}

@test "--help exits 0 and names every verb; misuse exits 1" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  for verb in up down status env verify mode conf docker-host; do [[ "$output" == *" $verb "* ]]; done
  run bash "$SCRIPT" bogus
  [ "$status" -eq 1 ]
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "up: an explicit local target still needs mini-baas-kong on this daemon" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/docker" # a daemon running nothing
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  run env GROBASE_TARGET=local PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPT" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"no mini-baas-kong on this daemon"* ]]
  [ ! -e "$GROBASE_LINK_DIR/state" ]
}

@test "docker-host: this daemon in local mode, the ssh target as a DOCKER_HOST in ssh mode, refused in direct mode" {
  mkdir -p "$GROBASE_LINK_DIR"
  printf 'mode=local\ntarget=local\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" docker-host
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'mode=ssh\ntarget=b2b\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" docker-host
  [ "$output" = ssh://b2b ]
  printf 'mode=ssh\ntarget=ssh://alice@box:2222\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" docker-host
  [ "$output" = ssh://alice@box:2222 ]
  printf 'mode=direct\ntarget=https://k\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" docker-host
  [ "$status" -eq 1 ]
  [[ "$output" == *"no postgres"* ]]
}
