#!/usr/bin/env bats
# scripts/datacenter.sh decides whether `make all` deploys against the VM on this host, and what
# it may write there. Each test runs a copy of the script in a tree of its own, with the scripts
# it calls replaced by stubs that log, so no test reaches a VM, a vault, a daemon or a browser.
#
# Run: docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/datacenter.bats

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  LOG="$BATS_TEST_TMPDIR/log"
  export CTL_CFG_DIR="$BATS_TEST_TMPDIR/42ctl"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export GROBASE_LINK_CONF="$ROOT/.env.grobase-link.local"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$ROOT/scripts/lib" "$ROOT/models" "$ROOT/secrets" "$CTL_CFG_DIR/secrets" "$GROBASE_LINK_DIR"
  mkdir -p "$ROOT/apps/grobase/certs" "$ROOT/vendor/born2root/setup/host" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../datacenter.sh" "$ROOT/scripts/"
  cp "$BATS_TEST_DIRNAME/../lib/envfile.sh" "$ROOT/scripts/lib/"
  : >"$LOG"
  export LOG PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  in_tree grobase-link.sh 'printf "unix:///link/docker.sock\n"'
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"'
  in_tree ensure-live-data-access.sh 'echo "live-data $*" >>"$LOG"'
  in_tree certs-trust-user.sh 'echo "trust $*" >>"$LOG"; [ "$1" != --check ] || echo "ok chrome /c current"; [ "$1" != --check ] || echo "ok firefox /f current"'
  stub ssh 'echo "ssh $*" >>"$LOG"
case "$*" in
  -G*) printf "hostname 127.0.0.1\nport 4242\nuser dlesieur\n" ;;
  *ssh_host_ed25519*) echo "ssh-ed25519 AAAAhostkey root@vm" ;;
  *"docker ps"*) echo mini-baas-waf ;;
esac'
  stub docker 'echo "docker $*" >>"$LOG"'
  stub ss 'exit 0'
}

teardown() {
  [ -z "${VM_PID:-}" ] || kill "$VM_PID" 2>/dev/null || true
}

# fake_own_vm — a live process of this user named like qemu, listening as far as `ss` can tell: a
# script's /proc/<pid>/comm is its own name.
fake_own_vm() {
  stub qemu-system-x86 'sleep 30'
  qemu-system-x86 >/dev/null 2>&1 3>&- &
  VM_PID=$!
  stub ss "echo 'LISTEN 0 1 127.0.0.1:4242 0.0.0.0:* users:((\"qemu-system-x86\",pid=$VM_PID,fd=21))'"
}

# in_tree NAME BODY — NAME under the test's scripts/, standing in for the real one.
in_tree() {
  printf '#!/bin/sh\n%s\n' "$2" >"$ROOT/scripts/$1"
  chmod +x "$ROOT/scripts/$1"
}
stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
}
vault_set() {
  printf 'FT_PASSPHRASE=not-a-real-one\n' >"$CTL_CFG_DIR/secrets/42admin.env"
  : >"$CTL_CFG_DIR/keystore.v42"
}
dc() { run bash "$ROOT/scripts/datacenter.sh" "$@"; }

@test "setting: no vault42 credentials means no data center, so make all stays what it was" {
  dc setting
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "setting: vault42 credentials mean the default alias, and the passphrase is never printed" {
  vault_set
  dc setting
  [ "$output" = b2b ]
}

@test "setting: credentials without a keystore are not a vault42 identity" {
  vault_set
  rm "$CTL_CFG_DIR/keystore.v42"
  dc setting
  [ -z "$output" ]
}

@test "setting: an explicit alias wins, and local opts this machine out" {
  vault_set
  printf 'GROBASE_DATACENTER=dc-lan\n' >"$CTL_CFG_DIR/secrets/datacenter.env"
  dc setting
  [ "$output" = dc-lan ]
  printf 'GROBASE_DATACENTER=local\n' >"$CTL_CFG_DIR/secrets/datacenter.env"
  dc setting
  [ -z "$output" ]
}

@test "vault-needed: a missing file pulls, a complete tree does not, VAULT42_REFRESH=1 always does" {
  dc vault-needed
  [ "$status" -eq 0 ]
  mkdir -p "$ROOT/apps/grobase"
  printf x >"$ROOT/.env.local"
  printf x >"$ROOT/apps/grobase/.env"
  printf x >"$ROOT/secrets/grobase-certs.tar.gz"
  dc vault-needed
  [ "$status" -eq 1 ]
  VAULT42_REFRESH=1 dc vault-needed
  [ "$status" -eq 0 ]
}

@test "certs: restores the CA certificate and the leaf, and never the CA key" {
  stub openssl 'exit 0'
  src="$BATS_TEST_TMPDIR/src/apps/grobase/certs"
  mkdir -p "$src"
  for f in track-binocle-local-ca.pem track-binocle-local-ca-key.pem localhost.pem localhost-key.pem; do echo x >"$src/$f"; done
  tar -czf "$ROOT/secrets/grobase-certs.tar.gz" -C "$BATS_TEST_TMPDIR/src" apps
  dc certs
  [ "$status" -eq 0 ]
  [ -s "$ROOT/apps/grobase/certs/track-binocle-local-ca.pem" ]
  [ -s "$ROOT/apps/grobase/certs/localhost-key.pem" ]
  [ ! -e "$ROOT/apps/grobase/certs/track-binocle-local-ca-key.pem" ]
}

@test "certs-verify: a leaf that does not chain to the CA stops, naming the repair" {
  stub openssl 'exit 1'
  echo key >"$ROOT/apps/grobase/certs/localhost-key.pem"
  dc certs-verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not chain"* ]]
}

@test "configure: the link's settings point at the WAF over this machine's address, with the key pinned" {
  vault_set
  fake_own_vm
  stub ip 'echo "1.1.1.1 via 10.0.0.1 dev eth0 src 10.12.19.4 uid 1000"'
  dc configure
  [ "$status" -eq 0 ]
  grep -qx 'GROBASE_TARGET=https://localhost:8443' "$GROBASE_LINK_CONF"
  grep -qx 'GROBASE_CONNECT_IP=10.12.19.4' "$GROBASE_LINK_CONF"
  grep -qx 'GROBASE_ADMIN_SSH=b2b' "$GROBASE_LINK_CONF"
  grep -qx 'GROBASE_ADMIN_HOST_KEY=ssh-ed25519 AAAAhostkey' "$GROBASE_LINK_CONF"
  grep -qx "GROBASE_CA_FILE=$ROOT/apps/grobase/certs/track-binocle-local-ca.pem" "$GROBASE_LINK_CONF"
  grep -qx 'GROBASE_ADMIN_HOST_KEY=ssh-ed25519 AAAAhostkey' "$CTL_CFG_DIR/secrets/datacenter.env"
}

@test "configure: a key already pinned is used, not read from the VM again" {
  vault_set
  printf 'GROBASE_ADMIN_HOST_KEY=ssh-ed25519 AAAApinned\n' >"$CTL_CFG_DIR/secrets/datacenter.env"
  stub ip 'echo "1.1.1.1 dev eth0 src 10.12.19.4"'
  dc configure
  grep -qx 'GROBASE_ADMIN_HOST_KEY=ssh-ed25519 AAAApinned' "$GROBASE_LINK_CONF"
  ! grep -q ssh_host_ed25519 "$LOG"
}

@test "configure: no first-use pin when the loopback port is not this user's own VM" {
  vault_set
  stub ip 'echo "1.1.1.1 dev eth0 src 10.12.19.4"'
  stub ss 'exit 0'
  dc configure
  [ "$status" -eq 1 ]
  [[ "$output" == *"GROBASE_ADMIN_HOST_KEY"* ]]
  [ ! -e "$GROBASE_LINK_CONF" ]
}

@test "configure: a VM that does not answer stops with the repair, never a local grobase" {
  vault_set
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *) exit 255 ;; esac'
  dc configure
  [ "$status" -eq 1 ]
  [[ "$output" == *"qemu_start"* ]]
  [[ "$output" == *"never starts grobase"* ]]
}

@test "preflight: a converged VM gets no write" {
  dc preflight
  [ "$status" -eq 0 ]
  grep -qx 'models --check' "$LOG"
  grep -qx 'live-data --check' "$LOG"
  ! grep -q 'docker exec' "$LOG"
}

@test "preflight: armed triggers alone run realtime-cdc-off and nothing else" {
  echo 'SELECT 1;' >"$ROOT/models/realtime-cdc-off-migration.sql"
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"
if [ ! -f "$LOG.cleared" ]; then touch "$LOG.cleared"; echo "[models] realtime row broadcasts armed: users" >&2; exit 1; fi'
  dc preflight
  [ "$status" -eq 0 ]
  grep -q 'docker exec -i mini-baas-postgres psql' "$LOG"
  [ "$(grep -c '^models' "$LOG")" -eq 2 ]
  ! grep -qx 'models ' "$LOG"
}

@test "preflight: unapplied DDL stops without DATACENTER_MIGRATE=1, and nothing is written" {
  in_tree apply-models-migrations.sh 'echo "[models] pending: x.sql (missing table: x)" >&2; exit 1'
  dc preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"DATACENTER_MIGRATE=1"* ]]
  ! grep -q 'docker exec' "$LOG"
  ! grep -q 'live-data' "$LOG"
}

@test "preflight: DATACENTER_MIGRATE=1 applies the DDL only after a dump is verified" {
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"; [ "${1:-}" != --check ] || { [ -f "$LOG.done" ] || { echo "[models] pending: x.sql (missing table: x)" >&2; exit 1; }; }; [ "${1:-}" = --check ] || touch "$LOG.done"'
  stub docker 'echo "docker $*" >>"$LOG"
case "$*" in *pg_dump*) echo dump ;; *pg_restore*) echo "1; 2 TABLE DATA public osionos_pages postgres" ;; esac'
  DATACENTER_MIGRATE=1 dc preflight
  [ "$status" -eq 0 ]
  [ "$(grep -n 'pg_restore' "$LOG" | cut -d: -f1)" -lt "$(grep -nx 'models ' "$LOG" | cut -d: -f1)" ]
}

@test "preflight: a dump that does not verify stops before any DDL" {
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"; [ "${1:-}" != --check ] || { echo "[models] pending: x.sql (missing table: x)" >&2; exit 1; }'
  stub docker 'echo "docker $*" >>"$LOG"; case "$*" in *pg_dump*) echo dump ;; esac'
  DATACENTER_MIGRATE=1 dc preflight
  [ "$status" -eq 1 ]
  ! grep -qx 'models ' "$LOG"
}

@test "preflight: a key that does not verify stops; make all never issues one" {
  in_tree ensure-live-data-access.sh 'echo "live-data $*" >>"$LOG"; exit 1'
  dc preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"link-live-data-ensure"* ]]
  [ "$(grep -c '^live-data' "$LOG")" -eq 1 ]
  grep -qx 'live-data --check' "$LOG"
}

@test "preflight: a database it cannot see is a stop, not a pass" {
  in_tree apply-models-migrations.sh 'echo "[models] mini-baas-postgres not running — skipping" >&2'
  dc preflight
  [ "$status" -eq 1 ]
  [ "$(grep -c live-data "$LOG")" -eq 0 ]
}

@test "trust: a CA that does not verify the WAF is never imported" {
  stub curl 'echo 000; exit 60'
  dc trust
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not verify"* ]]
  ! grep -qE '^trust [^-]' "$LOG"
}

@test "trust: current stores change nothing and leave no restart behind" {
  stub curl 'echo 401'
  dc trust
  [ "$status" -eq 0 ]
  ! grep -qE '^trust [^-]' "$LOG"
  [ ! -e "$GROBASE_LINK_DIR/browsers-stale" ]
}

@test "trust: a stale store is imported, gated, and marks the browsers for a relaunch" {
  stub curl 'echo 401'
  stub firefox 'exit 0'
  in_tree certs-trust-user.sh 'echo "trust $*" >>"$LOG"
[ "$1" = --check ] || { touch "$LOG.imported"; exit 0; }
[ -f "$LOG.imported" ] || { echo "FAIL firefox /f stale"; exit 1; }
echo "ok firefox /f current"'
  dc trust
  [ "$status" -eq 0 ]
  grep -qE '^trust [^-]' "$LOG"
  [ -e "$GROBASE_LINK_DIR/browsers-stale" ]
}

@test "trust: an import that leaves a store stale fails the build" {
  stub curl 'echo 401'
  in_tree certs-trust-user.sh 'echo "trust $*" >>"$LOG"; [ "$1" != --check ] || { echo "FAIL firefox /f stale"; exit 1; }'
  dc trust
  [ "$status" -eq 1 ]
}

@test "trust: a browser installed with no profile fails: --check alone passes with no store" {
  stub curl 'echo 401'
  stub firefox 'exit 0'
  in_tree certs-trust-user.sh 'echo "trust $*" >>"$LOG"; [ "$1" != --check ] || echo "ok chrome /c current"'
  dc trust
  [ "$status" -eq 1 ]
  [[ "$output" == *"Firefox"* ]]
}

@test "browsers: nothing changed, nothing restarts" {
  printf '#!/bin/sh\necho restart >>"$LOG"\n' >"$ROOT/vendor/born2root/setup/host/restart_browsers.sh"
  dc browsers
  [ "$status" -eq 0 ]
  ! grep -q restart "$LOG"
}

@test "browsers: with no terminal, as under the Update button, it says relaunch and kills nothing" {
  printf '#!/bin/sh\necho restart >>"$LOG"\n' >"$ROOT/vendor/born2root/setup/host/restart_browsers.sh"
  : >"$GROBASE_LINK_DIR/browsers-stale"
  run bash "$ROOT/scripts/datacenter.sh" browsers </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"relaunch"* ]]
  ! grep -q restart "$LOG"
  [ ! -e "$GROBASE_LINK_DIR/browsers-stale" ]
}

# The Make side, against the real tree. REPO is read here so the tree above keeps its stubs.
repo() { cd "$BATS_TEST_DIRNAME/../.." || return 1; }

@test "make all: a machine with no data center runs the local pipeline it always ran" {
  repo
  run make -n all GROBASE_DATACENTER= SKIP_SYNC=1
  [[ "$output" == *"apply-models-migrations.sh"* ]]
  [[ "$output" != *"datacenter.sh configure"* ]]
}

@test "make all: a data center runs its own steps and never reaches apps/grobase up" {
  repo
  run make -n all GROBASE_DATACENTER=b2b SKIP_SYNC=1
  [[ "$output" == *"datacenter.sh configure"* ]]
  [[ "$output" == *"datacenter.sh preflight"* ]]
  [[ "$output" != *"apps/grobase up"* ]]
  [[ "$output" != *"-C apps/grobase up"* ]]
}

@test "make backend-up: refused on a machine with a data center" {
  repo
  run make backend-up GROBASE_DATACENTER=b2b
  [ "$status" -ne 0 ]
  [[ "$output" == *"starts no grobase"* ]]
}

@test "make certs: a CA without its key is verified, never handed to the generator" {
  repo
  stub openssl 'exit 0'
  certs="$BATS_TEST_TMPDIR/certs"
  mkdir -p "$certs"
  for f in track-binocle-local-ca.pem localhost.pem localhost-key.pem; do echo x >"$certs/$f"; done
  run make certs LOCAL_CERT_DIR="$certs" GROBASE_DATACENTER=
  [ "$status" -eq 0 ]
  [ "$(cat "$certs/track-binocle-local-ca.pem")" = x ]
  [[ "$output" != *"apps/grobase"* ]]
}

@test "dev-rebuild-server: the Update button's make all runs with no terminal on stdin" {
  grep -q 'stdin=subprocess.DEVNULL' "$BATS_TEST_DIRNAME/../dev-rebuild-server.py"
}
