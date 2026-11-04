#!/usr/bin/env bats
# GROBASE_ADMIN_SSH and GROBASE_CONNECT_IP: a direct link whose runtime traffic stays on verified
# TLS, with ssh for bring-up only. These source grobase-link.sh, as grobase-link.bats does; ssh and
# docker are stubs, so nothing reaches a VM.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link-admin.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../grobase-link.sh"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/conf.env"
  export GROBASE_REMOTE_ENV="$BATS_TEST_TMPDIR/remote.env"
  export LOG="$BATS_TEST_TMPDIR/log"
  mkdir -p "$GROBASE_LINK_DIR" "$BATS_TEST_TMPDIR/bin"
  : >"$LOG"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
}
helper() { run bash -c "source '$SCRIPT' && $1"; }

@test "kong_addr: GROBASE_CONNECT_IP moves the dial, the certificate is still checked for the URL's name" {
  export GROBASE_CONNECT_IP=10.12.19.4
  helper "kong_addr https://localhost:8443 /link/ca.pem"
  [ "$output" = "OPENSSL:10.12.19.4:8443,verify=1,cafile=/link/ca.pem,commonname=localhost,snihost=localhost" ]
}

@test "kong_addr: without GROBASE_CONNECT_IP the URL's name is resolved as before" {
  stub getent 'echo "192.0.2.9 STREAM x"'
  helper "kong_addr https://kong.lan:8443 /link/ca.pem"
  [ "$output" = "OPENSSL:192.0.2.9:8443,verify=1,cafile=/link/ca.pem,commonname=kong.lan,snihost=kong.lan" ]
}

@test "open_admin_master: drops the alias's options and accepts only the pinned key" {
  stub ssh 'echo "ssh $*" >>"$LOG"; case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser dlesieur\n" ;; esac'
  export GROBASE_ADMIN_SSH=b2b GROBASE_ADMIN_HOST_KEY='ssh-ed25519 AAAApinned'
  helper open_admin_master
  [ "$status" -eq 0 ]
  line=$(grep ControlMaster=yes "$LOG")
  [[ "$line" == *"-F /dev/null"* ]]
  [[ "$line" == *"StrictHostKeyChecking=yes"* ]]
  [[ "$line" == *"HostKeyAlias=grobase-admin"* ]]
  [[ "$line" == *"-p 4242 -l dlesieur"* ]]
  grep -qx 'grobase-admin ssh-ed25519 AAAApinned' "$GROBASE_LINK_DIR/admin_known_hosts"
}

@test "open_admin_master: refuses without a pinned key, and a value ssh would read as an option" {
  stub ssh 'exit 0'
  export GROBASE_ADMIN_SSH=b2b
  helper open_admin_master
  [ "$status" -eq 1 ]
  [[ "$output" == *"GROBASE_ADMIN_HOST_KEY"* ]]
  export GROBASE_ADMIN_SSH=-oProxyCommand=x GROBASE_ADMIN_HOST_KEY='ssh-ed25519 A'
  helper open_admin_master
  [ "$status" -eq 1 ]
  [[ "$output" == *"plain ssh alias"* ]]
}

@test "docker-host: a direct link refuses until the admin socket exists" {
  printf 'mode=direct\ntarget=https://localhost:8443\n' >"$GROBASE_LINK_DIR/state"
  run bash "$SCRIPT" docker-host
  [ "$status" -eq 1 ]
  [[ "$output" == *"no daemon"* ]]
}

@test "docker-host: a direct link with the socket answers with it" {
  printf 'mode=direct\ntarget=https://localhost:8443\n' >"$GROBASE_LINK_DIR/state"
  command -v socat >/dev/null 2>&1 || skip "needs socat to create a unix socket"
  socat UNIX-LISTEN:"$GROBASE_LINK_DIR/docker.sock" - &
  sleep 0.2
  run bash "$SCRIPT" docker-host
  kill %1
  [ "$output" = "unix://$GROBASE_LINK_DIR/docker.sock" ]
}

@test "env: a direct link with an admin alias reads the VM's own .env, not a stale local copy" {
  printf 'mode=direct\ntarget=https://localhost:8443\n' >"$GROBASE_LINK_DIR/state"
  printf 'JWT_SECRET=stale\n' >"$GROBASE_REMOTE_ENV"
  export GROBASE_ADMIN_SSH=b2b
  stub ssh 'case "$*" in *"cat "*) echo JWT_SECRET=fresh ;; esac'
  helper 'fetch_remote_env'
  [ "$status" -eq 0 ]
  grep -qx 'JWT_SECRET=fresh' "$GROBASE_REMOTE_ENV"
}
