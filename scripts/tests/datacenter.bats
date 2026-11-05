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
  export DATACENTER_WAIT_SCALE=0
  export B2B_BOOT_ID_FILE="$BATS_TEST_TMPDIR/boot_id"
  echo boot-1 >"$B2B_BOOT_ID_FILE"
  mkdir -p "$ROOT/scripts/lib" "$ROOT/models" "$ROOT/secrets" "$CTL_CFG_DIR/secrets" "$GROBASE_LINK_DIR"
  mkdir -p "$ROOT/apps/grobase/certs" "$ROOT/vendor/born2root/setup/host" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../datacenter.sh" "$ROOT/scripts/"
  cp "$BATS_TEST_DIRNAME/../lib/envfile.sh" "$BATS_TEST_DIRNAME/../lib/datacenter-vm.sh" \
    "$BATS_TEST_DIRNAME/../lib/datacenter-models.sh" "$BATS_TEST_DIRNAME/../lib/datacenter-gate.sh" \
    "$BATS_TEST_DIRNAME/../lib/datacenter-build.sh" "$BATS_TEST_DIRNAME/../lib/datacenter-verify.sh" \
    "$BATS_TEST_DIRNAME/../lib/datacenter-binds.sh" \
    "$BATS_TEST_DIRNAME/../lib/vault42-session.sh" "$ROOT/scripts/lib/"
  mkdir -p "$ROOT/tools/seeds"
  cp "$BATS_TEST_DIRNAME/../../tools/seeds/agency-roster.sh" "$ROOT/tools/seeds/"
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
  stub docker 'echo "docker $*" >>"$LOG"
case "$*" in *"select sha"*) cat "$LOG.applied" 2>/dev/null ;; esac'
  stub ss 'exit 0'
  stub make 'echo "make $*" >>"$LOG"'
  stub crontab "printf '%s\\n' '# b2b-autostart baas begin' '* * * * * cd / && B2B_CONFIG=profiles/server.toml VM_PATH=$BATS_TEST_TMPDIR/vms VM_NAME=baas autostart --tick' '# b2b-autostart baas end'"
  mkdir -p "$BATS_TEST_TMPDIR/vms/baas"
  : >"$BATS_TEST_TMPDIR/vms/baas/baas.qcow2"
  echo 'SELECT 1;' >"$ROOT/models/a.sql"
  sha256=$(cat "$ROOT"/models/*.sql | sha256sum | cut -d' ' -f1)
  printf '%s\n' "$sha256" >"$LOG.applied"
}

# vm_says TENANTS LAST — an answering VM with a running WAF, TENANTS rows and seeds.last = LAST.
vm_says() {
  stub ssh "echo \"ssh \$*\" >>\"\$LOG\"
case \"\$*\" in
  -G*) printf 'hostname 127.0.0.1\\nport 4242\\nuser dlesieur\\n' ;;
  *'docker ps'*) echo mini-baas-waf ;;
  *public.tenants*) echo '$1' ;;
  *seeds.last*) [ -z '$2' ] || echo '$2' ;;
esac"
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

@test "setting: a keystore carried in the credentials file counts, so such a seat cannot go local" {
  printf 'FT_PASSPHRASE=x\nFT_KEYSTORE_B64=eA==\n' >"$CTL_CFG_DIR/secrets/42admin.env"
  dc setting
  [ "$output" = b2b ]
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
  dc vault-needed
  [ "$status" -eq 1 ]
  VAULT42_REFRESH=1 dc vault-needed
  [ "$status" -eq 0 ]
}

@test "certs: copies the CA and the WAF's leaf from the VM, and never touches the CA key" {
  vault_set
  stub openssl 'echo same'
  stub ssh 'echo "ssh $*" >>"$LOG"
case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *localhost_key*) echo KEY ;; *localhost_cert*) echo LEAF ;; *) echo CA ;; esac'
  dc certs
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/apps/grobase/certs/track-binocle-local-ca.pem")" = CA ]
  [ "$(cat "$ROOT/apps/grobase/certs/localhost.pem")" = LEAF ]
  [ "$(cat "$ROOT/apps/grobase/certs/localhost-key.pem")" = KEY ]
  [ ! -e "$ROOT/apps/grobase/certs/track-binocle-local-ca-key.pem" ]
  ! grep -q 'ca-key' "$LOG"
  grep -q 'StrictHostKeyChecking=yes' "$LOG"
  [ -z "$(ls -A "$ROOT/apps/grobase/certs" | grep incoming || true)" ]
}

@test "certs: a key that is not the leaf's leaves the tree as it was" {
  vault_set
  echo OLD >"$ROOT/apps/grobase/certs/localhost.pem"
  stub openssl 'case "$*" in *pkey*) echo other ;; *) echo same ;; esac'
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *) echo x ;; esac'
  dc certs
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match"* ]]
  [ "$(cat "$ROOT/apps/grobase/certs/localhost.pem")" = OLD ]
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

@test "configure: a rebuilt VM's new key replaces the pin by itself" {
  vault_set
  fake_own_vm
  printf 'GROBASE_ADMIN_HOST_KEY=ssh-ed25519 AAAAold\n' >"$CTL_CFG_DIR/secrets/datacenter.env"
  stub ip 'echo "1.1.1.1 dev eth0 src 10.12.19.4"'
  dc configure
  [ "$status" -eq 0 ]
  grep -qx 'GROBASE_ADMIN_HOST_KEY=ssh-ed25519 AAAAhostkey' "$CTL_CFG_DIR/secrets/datacenter.env"
  grep -qx 'grobase-admin ssh-ed25519 AAAAhostkey' "$XDG_STATE_HOME/groot/admin_known_hosts"
}

@test "vm: grobase running and seeded: no make, no write" {
  vault_set
  vm_says 9 'vintage=2026-11-04'
  dc vm
  [ "$status" -eq 0 ]
  ! grep -q '^make' "$LOG"
}

@test "vm: down and held stops at once, with the way out" {
  vault_set
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *) exit 255 ;; esac'
  echo boot-1 >"$BATS_TEST_TMPDIR/vms/baas/.autostart-hold"
  dc vm
  [ "$status" -eq 1 ]
  [[ "$output" == *"Stopped on purpose"* ]]
  [[ "$output" == *"make qemu_start B2B_CONFIG=profiles/server.toml"* ]]
  [[ "$output" != *"waiting for"* ]]
}

@test "vm: a hold from before the last reboot does not stop it" {
  vault_set
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *) exit 255 ;; esac'
  echo boot-0 >"$BATS_TEST_TMPDIR/vms/baas/.autostart-hold"
  dc vm
  [ "$status" -eq 1 ]
  [[ "$output" != *"Stopped on purpose"* ]]
}

# no_vm — ssh refuses, no crontab, and born2root's Makefile answers for the profile's VM.
no_vm() {
  vault_set
  rm -f "$BATS_TEST_TMPDIR/vms/baas/baas.qcow2"
  stub crontab 'exit 0'
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *) exit 255 ;; esac'
  stub make "echo \"make \$*\" >>\"\$LOG\"
case \"\$*\" in
  *print-VM_NAME*) echo baas ;;
  *print-VM_PATH*) echo '$BATS_TEST_TMPDIR/vms' ;;
esac"
  mkdir -p "$ROOT/vendor/born2root/setup/host"
  printf '#!/bin/sh\necho %s/backups\n' "$BATS_TEST_TMPDIR" >"$ROOT/vendor/born2root/setup/host/backup_pull.sh"
}

@test "vm: no VM and no terminal builds nothing, whatever DATACENTER_ALLOW_WRITES says" {
  no_vm
  DATACENTER_ALLOW_WRITES=1 run bash "$ROOT/scripts/datacenter.sh" vm </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"run make all at a terminal"* ]]
  ! grep -qE '^make .* (all|secrets_pull)( |$)' "$LOG"
}

@test "vm: never a local grobase when there is no VM" {
  no_vm
  dc vm
  [[ "$output" != *"GROBASE_DATACENTER="* ]]
}

@test "vm: an unreadable disk is not an absent one, so nothing is built over it" {
  no_vm
  stub stat 'echo "stat: cannot statx: Permission denied" >&2; exit 1'
  dc vm
  [ "$status" -eq 1 ]
  [[ "$output" == *"not provably absent"* ]]
  [[ "$output" != *"run make all at a terminal"* ]]
}

@test "vm: an occupied VM port is not an absent VM" {
  no_vm
  stub ss 'echo "LISTEN 0 1 127.0.0.1:4242"'
  dc vm
  [ "$status" -eq 1 ]
  [[ "$output" == *"not provably absent"* ]]
}

@test "vm: another alias is never built" {
  no_vm
  printf 'GROBASE_DATACENTER=dc-lan\n' >"$CTL_CFG_DIR/secrets/datacenter.env"
  dc vm
  [ "$status" -eq 1 ]
  [[ "$output" != *"run make all at a terminal"* ]]
}

@test "vm: a disk without .installed stops and never installs autostart over it" {
  no_vm
  : >"$BATS_TEST_TMPDIR/vms/baas/baas.qcow2"
  dc vm
  [ "$status" -eq 1 ]
  [[ "$output" == *"install was interrupted"* ]]
  ! grep -q 'autostart' "$LOG"
}

@test "vm: a built VM with no auto-start block gets one from born2root" {
  no_vm
  : >"$BATS_TEST_TMPDIR/vms/baas/baas.qcow2"
  : >"$BATS_TEST_TMPDIR/vms/baas/.installed"
  export B2B_KVM_DEVICE="$BATS_TEST_TMPDIR/kvm"
  : >"$B2B_KVM_DEVICE"
  DATACENTER_ALLOW_WRITES=1 dc vm
  grep -q '^make .*autostart' "$LOG"
}

@test "vm: stopped grobase goes through born2root, with no make flags leaking in" {
  vault_set
  stub ssh 'echo "ssh $*" >>"$LOG"
case "$*" in
  -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;;
  *"docker ps"*) [ -f "$LOG.up" ] && echo mini-baas-waf ;;
  *public.tenants*) echo 9 ;;
  *seeds.last*) echo vintage=x ;;
esac'
  stub make 'echo "make $* flags=${MAKEFLAGS:-none}" >>"$LOG"; case " $* " in *" -n "*) ;; *grobase*) touch "$LOG.up" ;; esac'
  MAKEFLAGS=FORCE=1 DATACENTER_ALLOW_WRITES=1 dc vm
  [ "$status" -eq 0 ]
  grep -E '^make .*grobase .*B2B_CONFIG=profiles/server.toml' "$LOG" | grep -v -- ' -n ' | grep -q 'flags=none'
}

@test "vm: make grobase leaving no WAF stops, whatever it exited with" {
  vault_set
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *"docker ps"*) ;; esac'
  DATACENTER_ALLOW_WRITES=1 dc vm
  [ "$status" -eq 1 ]
  [[ "$output" == *"after make grobase"* ]]
}

@test "vm: with no terminal, as under the Update button, nothing is started" {
  vault_set
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *"docker ps"*) ;; esac'
  run bash "$ROOT/scripts/datacenter.sh" vm </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"from a terminal"* ]]
  ! grep -q '^make' "$LOG"
}

@test "vm: a born2root pin without the target stops, naming that the pin must move" {
  vault_set
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *"docker ps"*) ;; esac'
  stub make 'exit 2'
  DATACENTER_ALLOW_WRITES=1 dc vm
  [ "$status" -eq 1 ]
  [[ "$output" == *"pin has to move"* ]]
}

@test "vm: an empty platform is seeded unforced" {
  vault_set
  stub ssh 'echo "ssh $*" >>"$LOG"
case "$*" in
  -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;;
  *"docker ps"*) echo mini-baas-waf ;;
  *public.tenants*) echo 0 ;;
  *seeds.last*) [ -f "$LOG.seeded" ] && echo vintage=x ;;
esac'
  stub make 'echo "make $*" >>"$LOG"; case " $* " in *" -n "*) ;; *set_seeds*) touch "$LOG.seeded" ;; esac'
  DATACENTER_ALLOW_WRITES=1 dc vm
  [ "$status" -eq 0 ]
  grep -E '^make .*set_seeds' "$LOG" | grep -v -- ' -n ' | grep -vq FORCE
}

@test "vm: rows with no record of a seed stop, naming the forced seed; nothing is seeded" {
  vault_set
  vm_says 9 ''
  dc vm
  [ "$status" -eq 1 ]
  [[ "$output" == *"make set_seeds FORCE=1"* ]]
  ! grep -q '^make' "$LOG"
}

@test "dc: ps, logs and health run in the VM over the pinned path" {
  vault_set
  vm_says 9 x
  dc dc health
  [ "$status" -eq 0 ]
  grep -q 'make -C /opt/grobase health' "$LOG"
  grep -q 'StrictHostKeyChecking=yes' "$LOG"
}

@test "dc: up goes through born2root, never a bare make up in the VM" {
  vault_set
  vm_says 9 x
  dc dc up
  [ "$status" -eq 0 ]
  grep -E '^make .*grobase .*B2B_CONFIG' "$LOG" | grep -qv -- ' -n '
  ! grep -q 'make -C /opt/grobase up' "$LOG"
}

@test "dc: anything else is refused, and CONFIRM never reaches the VM" {
  vault_set
  vm_says 9 x
  CONFIRM=1 dc dc fclean
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"* ]]
  ! grep -q fclean "$LOG"
}

@test "preflight: a converged VM gets no write" {
  dc preflight
  [ "$status" -eq 0 ]
  grep -qx 'models --check' "$LOG"
  grep -qx 'live-data --check' "$LOG"
  ! grep -qE 'docker exec -i|pg_dump' "$LOG"
}

@test "preflight: armed triggers alone run realtime-cdc-off and nothing else" {
  echo 'SELECT 1;' >"$ROOT/models/realtime-cdc-off-migration.sql"
  printf '%s\n' "$(cat "$ROOT"/models/*.sql | sha256sum | cut -d' ' -f1)" >"$LOG.applied"
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"
if [ ! -f "$LOG.cleared" ]; then touch "$LOG.cleared"; echo "[models] realtime row broadcasts armed: users" >&2; exit 1; fi'
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 0 ]
  grep -q 'docker exec -i mini-baas-postgres psql' "$LOG"
  [ "$(grep -c '^models' "$LOG")" -eq 2 ]
  ! grep -qx 'models ' "$LOG"
}

@test "preflight: armed triggers with no terminal are noted and left; the Update button writes nothing" {
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"; echo "[models] realtime row broadcasts armed: users" >&2; exit 1'
  run bash "$ROOT/scripts/datacenter.sh" preflight </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"armed"* ]]
  ! grep -q 'docker exec -i' "$LOG"
}

@test "preflight: a trigger a busy table kept stops the run and names the likely cause" {
  echo 'SELECT 1;' >"$ROOT/models/realtime-cdc-off-migration.sql"
  printf '%s\n' "$(cat "$ROOT"/models/*.sql | sha256sum | cut -d' ' -f1)" >"$LOG.applied"
  in_tree apply-models-migrations.sh 'echo "[models] realtime row broadcasts armed: users" >&2; exit 1'
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"hourly backup"* ]]
  [ "$(grep -c '^live-data' "$LOG")" -eq 0 ]
}

@test "preflight: pending models with no terminal stop, and nothing is written" {
  in_tree apply-models-migrations.sh 'echo "[models] pending: x.sql (missing table: x)" >&2; exit 1'
  run bash "$ROOT/scripts/datacenter.sh" preflight </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"from a terminal"* ]]
  ! grep -qE 'pg_dump|docker exec -i' "$LOG"
}

@test "preflight: models apply only after the dump is read back in full, then record their hash" {
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"; [ "${1:-}" != --check ] || { [ -f "$LOG.done" ] || { echo "[models] pending: x.sql (missing table: x)" >&2; exit 1; }; }; [ "${1:-}" = --check ] || touch "$LOG.done"'
  stub docker 'echo "docker $*" >>"$LOG"
case "$*" in *pg_dump*) echo dump ;; *"pg_restore -l"*) echo "1; 2 TABLE DATA public osionos_pages postgres" ;; esac'
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 0 ]
  [ "$(grep -n 'pg_restore -f /dev/null' "$LOG" | cut -d: -f1)" -lt "$(grep -nx 'models ' "$LOG" | cut -d: -f1)" ]
  grep -q 'docker exec -i mini-baas-postgres psql' "$LOG"
}

@test "preflight: a listing longer than a pipe buffer is not mistaken for a bad dump" {
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"; [ "${1:-}" != --check ] || { [ -f "$LOG.done" ] || { echo "[models] pending: x.sql (missing table: x)" >&2; exit 1; }; }; [ "${1:-}" = --check ] || touch "$LOG.done"'
  stub docker 'echo "docker $*" >>"$LOG"
case "$*" in *"pg_restore -l"*) echo "1; 2 TABLE DATA public osionos_pages postgres"; i=0; while [ $i -lt 20000 ]; do echo "; padding line $i"; i=$((i+1)); done ;; esac'
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 0 ]
  grep -qx 'models ' "$LOG"
  [ "$(stat -c %a "$(ls "$XDG_STATE_HOME"/groot/datacenter-dumps/*.dump)")" = 600 ]
}

@test "preflight: a column-only models change is seen from the hash, though no table is missing" {
  rm "$LOG.applied"
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"'
  stub docker 'echo "docker $*" >>"$LOG"
case "$*" in *"pg_restore -l"*) echo "1; 2 TABLE DATA public osionos_pages postgres" ;; esac'
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 0 ]
  grep -qx 'models ' "$LOG"
}

@test "preflight: a dump whose table of contents is fine but whose body is not stops before any DDL" {
  in_tree apply-models-migrations.sh 'echo "models $*" >>"$LOG"; [ "${1:-}" != --check ] || { echo "[models] pending: x.sql (missing table: x)" >&2; exit 1; }'
  stub docker 'echo "docker $*" >>"$LOG"
case "$*" in *"pg_restore -l"*) echo "1; 2 TABLE DATA public osionos_pages postgres" ;; *"pg_restore -f"*) exit 1 ;; esac'
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"read back in full"* ]]
  ! grep -qx 'models ' "$LOG"
}

# A seed on record, S1 unless SEED says otherwise, and a docker that answers the marker from a file.
seed_on_record() {
  vault_set
  stub ssh 'echo "ssh $*" >>"$LOG"; case "$*" in *seeds.last*) echo "seeded_at=${SEED-S1}" ;; esac'
  stub docker 'echo "docker $*" >>"$LOG"
case "$*" in *"select sha"*) cat "$LOG.applied" ;; *"select seeded_at"*) cat "$LOG.seed" 2>/dev/null ;; esac'
}

@test "preflight: a seed not yet converged moves its rows onto the key, once, and records it" {
  seed_on_record
  in_tree ensure-live-data-access.sh 'echo "live-data $*" >>"$LOG"; [ -f "$LOG.fixed" ] && exit 0; [ "${1:-}" = --check ] && exit 1; touch "$LOG.fixed"'
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 0 ]
  grep -qx 'live-data ' "$LOG"
  [[ "$output" == *"seed S1 has not been converged"* ]]
  grep -q 'docker exec -i mini-baas-postgres psql' "$LOG"
}

@test "preflight: the same seed never re-stamps twice, so later rows are left alone" {
  seed_on_record
  echo S1 >"$LOG.seed"
  in_tree ensure-live-data-access.sh 'echo "live-data $*" >>"$LOG"; exit 1'
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"link-live-data-ensure"* ]]
  ! grep -qx 'live-data ' "$LOG"
}

@test "preflight: with no seed on record the repair stays manual" {
  seed_on_record
  export SEED=
  stub ssh 'echo "ssh $*" >>"$LOG"'
  in_tree ensure-live-data-access.sh 'echo "live-data $*" >>"$LOG"; exit 1'
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 1 ]
  ! grep -qx 'live-data ' "$LOG"
}

@test "preflight: with no terminal a seed needing a repair stops, and nothing is written" {
  seed_on_record
  in_tree ensure-live-data-access.sh 'echo "live-data $*" >>"$LOG"; exit 1'
  run bash "$ROOT/scripts/datacenter.sh" preflight </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"from a terminal"* ]]
  ! grep -qx 'live-data ' "$LOG"
}

@test "preflight: a seed that already converges is recorded, so a later drift cannot re-stamp" {
  seed_on_record
  DATACENTER_ALLOW_WRITES=1 dc preflight
  [ "$status" -eq 0 ]
  grep -q 'docker exec -i mini-baas-postgres psql' "$LOG"
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
repo() {
  rm -f "$BATS_TEST_TMPDIR/bin/make"
  cd "$BATS_TEST_DIRNAME/../.." || return 1
}

@test "make all: a machine with no data center runs the local pipeline it always ran" {
  repo
  stub openssl 'exit 0' # `certs` holds $(MAKE), so its recipe runs even under make -n
  run make -n all GROBASE_DATACENTER= SKIP_SYNC=1
  [[ "$output" == *"apply-models-migrations.sh"* ]]
  [[ "$output" != *"datacenter.sh configure"* ]]
}

@test "make all: a data center runs its own steps and never reaches apps/grobase up" {
  repo
  stub openssl 'exit 0' # `certs` holds $(MAKE), so its recipe runs even under make -n
  run make -n all GROBASE_DATACENTER=b2b SKIP_SYNC=1
  [[ "$output" == *"datacenter.sh configure"* ]]
  [[ "$output" == *"datacenter.sh preflight"* ]]
  [[ "$output" == *"mail-bridge"* ]]
  [[ "$output" == *"calendar-bridge"* ]]
  [[ "$output" != *"apps/grobase up"* ]]
  [[ "$output" != *"-C apps/grobase up"* ]]
}

@test "make all: local on the command line is the opt-out, as it is in a credential file" {
  repo
  stub openssl 'exit 0'
  run make -n all GROBASE_DATACENTER=local SKIP_SYNC=1
  [[ "$output" == *"apply-models-migrations.sh"* ]]
  [[ "$output" != *"datacenter.sh configure"* ]]
  [[ "$output" != *"datacenter.sh gate"* ]]
}

@test "make all: the gate comes first, before the sync touches a submodule" {
  repo
  stub openssl 'exit 0'
  run make -n all GROBASE_DATACENTER=b2b
  [[ "$output" == *"datacenter.sh gate"* ]]
  gate=$(grep -n 'datacenter.sh gate' <<<"$output" | head -n 1 | cut -d: -f1)
  sync=$(grep -n 'syncro-submodule\|SKIP_SYNC' <<<"$output" | head -n 1 | cut -d: -f1)
  [ "$gate" -lt "$sync" ]
}

@test "gate: no credentials at all is the local pipeline" {
  dc gate
  [ "$status" -eq 0 ]
}

@test "gate: a machine that opted out is not checked" {
  printf 'GROBASE_DATACENTER=local\nFT_PASSPHRASE=x\n' >"$CTL_CFG_DIR/secrets/datacenter.env"
  dc gate
  [ "$status" -eq 0 ]
}

@test "gate: half-set credentials stop and name each missing key, never a value" {
  printf 'FT_PASSPHRASE=do-not-print\nFT_EMAIL=a@b\n' >"$CTL_CFG_DIR/secrets/42admin.env"
  dc gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"FT_PASSWORD"* ]]
  [[ "$output" == *"FT_TENANT"* ]]
  [[ "$output" != *"do-not-print"* ]]
}

# full_credentials CTL_BODY — every key set, and a 42ctl behaving as CTL_BODY says.
full_credentials() {
  printf 'FT_PASSPHRASE=p\nFT_PASSWORD=q\nFT_EMAIL=a@b\nFT_TENANT=t\nFT_KEYSTORE_B64=a2V5\n' >"$CTL_CFG_DIR/secrets/42admin.env"
  stub 42ctl "$1"
}

@test "gate: restores the keystore from the credentials file, mode 600" {
  full_credentials 'case "$*" in "auth status") echo contract ;; esac; exit 0'
  dc gate
  [ "$status" -eq 0 ]
  [ "$(cat "$CTL_CFG_DIR/keystore.v42")" = key ]
  [ "$(stat -c %a "$CTL_CFG_DIR/keystore.v42")" = 600 ]
}

@test "gate: records the object store, which only config.json holds and a new machine lacks" {
  full_credentials 'echo "ctl $*" >>"$LOG"; case "$*" in "auth status") echo contract ;; esac; exit 0'
  dc gate
  [ "$status" -eq 0 ]
  grep -q "ctl config endpoint --blobstore https://fly.storage.tigris.dev --bucket vault42-seeds" "$LOG"
}

@test "gate: a vault that refuses, with nothing set by hand, stops naming the files" {
  full_credentials 'case "$*" in "auth status") echo contract ;; env*) echo refused >&2; exit 1 ;; esac; exit 0'
  dc gate
  [ "$status" -eq 1 ]
  [[ "$output" == *".env.local"* ]]
  [[ "$output" == *"apps/grobase/.env"* ]]
}

@test "gate: a vault that refuses, with the files set by hand, continues and says so" {
  full_credentials 'case "$*" in "auth status") echo contract ;; env*) exit 1 ;; esac; exit 0'
  mkdir -p "$ROOT/apps/grobase"
  echo a=b >"$ROOT/.env.local"
  echo a=b >"$ROOT/apps/grobase/.env"
  dc gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot be built from this run"* ]]
}

# verified_stack — a VM on its plan, pages answering, no containers.
verified_stack() {
  vault_set
  stub curl 'printf 200'
  stub docker 'case "$1" in exec) echo 21 ;; esac'
  stub xargs 'exit 0'
  mkdir -p "$ROOT/apps/grobase/certs" "$ROOT/tests/e2e"
}

@test "verify: a VM off its plan fails however good the pages are" {
  verified_stack
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *health*) exit 1 ;; esac'
  dc verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"not healthy on its plan"* ]]
}

@test "verify: a 404 is not a page that answers" {
  verified_stack
  stub curl 'printf 404'
  dc verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"answered 404"* ]]
}

@test "verify: Mail's bridge is probed on the port it moved to" {
  verified_stack
  printf 'MAIL_BRIDGE_HOST_PORT=4101\n' >"$ROOT/.env.ports"
  stub curl 'echo "$*" >>"$LOG"; printf 200'
  dc verify
  grep -q 'localhost:4101/health' "$LOG"
}

@test "verify: a file mount Docker turned into an empty directory fails" {
  verified_stack
  empty="$BATS_TEST_TMPDIR/agency-people.env"
  mkdir "$empty"
  stub docker "case \"\$1\" in ps) echo abc ;; esac"
  stub xargs "echo '$empty'"
  dc verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty directory"* ]]
}

@test "verify: an empty file mount fails, since touching the path proves nothing" {
  verified_stack
  empty="$BATS_TEST_TMPDIR/agency-people.env"
  : >"$empty"
  stub docker "case \"\$1\" in ps) echo abc ;; esac"
  stub xargs "echo '$empty'"
  dc verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty file"* ]]
}

@test "verify: a bridge that cannot read the roster fails however green its health is" {
  verified_stack
  stub docker 'case "$1" in exec) echo 0; exit 1 ;; esac'
  dc verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read its agency roster"* ]]
}

@test "verify: with no terminal the browsers say SKIP, never a pass" {
  verified_stack
  run bash "$ROOT/scripts/datacenter.sh" verify </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP browsers"* ]]
  [[ "$output" == *"The browsers did not run"* ]]
  [[ "$output" != *"and the browsers"* ]]
}

# roster_vm [MISSING] — a VM with every agency account, less the one named.
roster_vm() {
  vault_set
  . "$ROOT/tools/seeds/agency-roster.sh"
  : >"$BATS_TEST_TMPDIR/accounts"
  for entry in "${ROSTER[@]}"; do
    [ "${entry%%|*}" = "${1:-}" ] || echo "${entry%%|*}|id-${entry%%@*}" >>"$BATS_TEST_TMPDIR/accounts"
  done
  stub ssh "case \"\$*\" in -G*) printf 'hostname 127.0.0.1\\nport 4242\\nuser d\\n' ;; *auth.users*) cat '$BATS_TEST_TMPDIR/accounts' ;; esac"
}

@test "roster: written from the VM's accounts with the columns the bridge parses" {
  roster_vm
  dc binds
  [ "$status" -eq 0 ]
  out="$ROOT/tools/seeds/.agency-people.env"
  [ "$(grep -c '^AGENCY_PERSON_[0-9]' "$out")" = 21 ]
  grep -q '^AGENCY_OWNER_UUID=id-owner$' "$out"
  grep -q '^AGENCY_PERSON_0=id-owner|owner@agency.local|Helena Voss|director|command|5|EU|owner$' "$out"
}

@test "roster: rewritten in place, so a running bridge keeps seeing the file" {
  roster_vm
  out="$ROOT/tools/seeds/.agency-people.env"
  echo stale >"$out"
  inode=$(stat -c %i "$out")
  dc binds
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$out")" = "$inode" ]
  ! grep -q stale "$out"
}

@test "roster: an account the VM lacks stops the run and leaves no partial file" {
  roster_vm e07.sullivan@agency.local
  dc binds
  [ "$status" -eq 1 ]
  [[ "$output" == *"e07.sullivan@agency.local"* ]]
  [ ! -e "$ROOT/tools/seeds/.agency-people.env" ]
}

@test "roster: the directory Docker left is replaced and the bridge bound to it recreated" {
  roster_vm
  mkdir "$ROOT/tools/seeds/.agency-people.env"
  stub docker 'echo "docker $*" >>"$LOG"; case "$1" in ps) echo abc ;; esac'
  stub xargs 'echo "xargs $*" >>"$LOG"'
  dc binds
  [ "$status" -eq 0 ]
  [ -f "$ROOT/tools/seeds/.agency-people.env" ]
  grep -q 'xargs -r docker rm -f' "$LOG"
}

@test "roster: a directory holding files is never removed" {
  roster_vm
  mkdir "$ROOT/tools/seeds/.agency-people.env"
  echo keep >"$ROOT/tools/seeds/.agency-people.env/kept"
  dc binds
  [ "$status" -eq 1 ]
  [ -f "$ROOT/tools/seeds/.agency-people.env/kept" ]
}

@test "read-binds: a local checkout keeps its paths, whatever Docker is" {
  stub stat 'echo ext2/ext3'
  stub docker 'echo "[name=rootless]"'
  dc read-binds
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "read-binds: NFS under rootful Docker keeps its paths" {
  stub stat 'echo nfs'
  stub docker 'echo "[name=seccomp]"'
  dc read-binds
  [ -z "$output" ]
}

@test "read-binds: NFS under rootless Docker uses the disk Docker runs from" {
  stub stat 'echo nfs'
  stub docker 'case "$*" in *SecurityOptions*) echo "[name=rootless]" ;; *) echo /goinfre/me/docker ;; esac'
  dc read-binds
  [ "$output" = /goinfre/me/groot-read-binds ]
}

@test "binds: an NFS checkout gets every read-bind source in the copy" {
  roster_vm
  root="$BATS_TEST_TMPDIR/local/docker"
  stub stat 'echo nfs'
  stub docker "case \"\$*\" in *SecurityOptions*) echo '[name=rootless]' ;; *DockerRootDir*) echo '$root' ;; esac"
  mkdir -p "$ROOT/infrastructure/tls/api-docs" "$ROOT/apps/grobase/infra/config/openapi"
  echo docs >"$ROOT/infrastructure/tls/api-docs/index.html"
  echo spec >"$ROOT/apps/grobase/infra/config/openapi/grobase-public.json"
  dc binds
  [ "$status" -eq 0 ]
  dest="$BATS_TEST_TMPDIR/local/groot-read-binds"
  [ -s "$dest/infrastructure/tls/api-docs/index.html" ]
  [ -s "$dest/apps/grobase/infra/config/openapi/grobase-public.json" ]
  [ "$(grep -c '^AGENCY_PERSON_[0-9]' "$dest/tools/seeds/.agency-people.env")" = 21 ]
  [ ! -e "$ROOT/tools/seeds/.agency-people.env" ]
}

@test "read-binds: a directory already chosen wins over detection" {
  stub stat 'echo ext2/ext3'
  GROOT_READ_BINDS=/chosen/copy dc read-binds
  [ "$output" = /chosen/copy ]
}

# nfs_under_rootless DOCKER_ROOT — the machine this bug needs; every other docker call is logged.
nfs_under_rootless() {
  stub stat 'echo nfs'
  stub docker "echo \"docker \$*\" >>\"\$LOG\"
case \"\$*\" in *SecurityOptions*) echo '[name=rootless]' ;; *DockerRootDir*) echo '$1' ;; *'ps -aq'*) echo bridge-id ;; esac"
  mkdir -p "$ROOT/infrastructure/tls/api-docs" "$ROOT/apps/grobase/infra/config/openapi"
  echo docs >"$ROOT/infrastructure/tls/api-docs/index.html"
  echo spec >"$ROOT/apps/grobase/infra/config/openapi/grobase-public.json"
  COPY="$(dirname "$1")/groot-read-binds"
}

@test "local-binds: off NFS it copies nothing, so a normal checkout does not change" {
  stub stat 'echo ext2/ext3'
  stub docker 'echo "docker $*" >>"$LOG"'
  dc local-binds
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -q docker "$LOG"
}

@test "local-binds: NFS under rootful Docker copies nothing" {
  nfs_under_rootless "$BATS_TEST_TMPDIR/local/docker"
  stub docker 'echo "[name=seccomp]"'
  dc local-binds
  [ "$status" -eq 0 ]
  [ ! -e "$COPY" ]
}

@test "local-binds: an NFS checkout with no data center gets every read-bind source in the copy" {
  nfs_under_rootless "$BATS_TEST_TMPDIR/local/docker"
  echo 'AGENCY_PERSON_0=one' >"$ROOT/tools/seeds/.agency-people.env"
  chmod 600 "$ROOT/tools/seeds/.agency-people.env"
  dc local-binds
  [ "$status" -eq 0 ]
  [ -s "$COPY/infrastructure/tls/api-docs/index.html" ]
  [ -s "$COPY/apps/grobase/infra/config/openapi/grobase-public.json" ]
  cmp "$ROOT/tools/seeds/.agency-people.env" "$COPY/tools/seeds/.agency-people.env"
  [ "$(stat() { command -p stat "$@"; }; stat -c %a "$COPY/tools/seeds/.agency-people.env")" = 644 ]
}

@test "local-binds: no roster in the checkout leaves an empty file, so Docker binds no directory" {
  nfs_under_rootless "$BATS_TEST_TMPDIR/local/docker"
  mkdir -p "$COPY/tools/seeds"
  echo 'AGENCY_PERSON_0=from-the-vm' >"$COPY/tools/seeds/.agency-people.env"
  dc local-binds
  [ "$status" -eq 0 ]
  [ -f "$COPY/tools/seeds/.agency-people.env" ]
  [ ! -s "$COPY/tools/seeds/.agency-people.env" ]
}

@test "local-binds: an empty directory Docker left in the checkout is no roster" {
  nfs_under_rootless "$BATS_TEST_TMPDIR/local/docker"
  mkdir "$ROOT/tools/seeds/.agency-people.env"
  dc local-binds
  [ "$status" -eq 0 ]
  [ -f "$COPY/tools/seeds/.agency-people.env" ]
}

@test "local-binds: a directory Docker made in the copy goes, and so does the bridge binding it" {
  nfs_under_rootless "$BATS_TEST_TMPDIR/local/docker"
  mkdir -p "$COPY/tools/seeds/.agency-people.env"
  echo 'AGENCY_PERSON_0=one' >"$ROOT/tools/seeds/.agency-people.env"
  dc local-binds
  [ "$status" -eq 0 ]
  [ -s "$COPY/tools/seeds/.agency-people.env" ]
  grep -q 'docker rm -f bridge-id' "$LOG"
}

@test "local-binds: a directory chosen by hand is the one written" {
  stub stat 'echo ext2/ext3'
  mkdir -p "$ROOT/infrastructure/tls/api-docs" "$ROOT/apps/grobase/infra/config/openapi"
  chosen="$BATS_TEST_TMPDIR/chosen"
  GROOT_READ_BINDS="$chosen" dc local-binds
  [ "$status" -eq 0 ]
  [ -f "$chosen/tools/seeds/.agency-people.env" ]
}

@test "binds: a directory chosen by hand is the one written" {
  roster_vm
  mkdir -p "$ROOT/infrastructure/tls/api-docs" "$ROOT/apps/grobase/infra/config/openapi"
  chosen="$BATS_TEST_TMPDIR/chosen"
  GROOT_READ_BINDS="$chosen" dc binds
  [ "$status" -eq 0 ]
  [ -s "$chosen/tools/seeds/.agency-people.env" ]
}

@test "make all: the local pipeline copies before compose starts anything" {
  repo
  stub openssl 'exit 0'
  run make -n all GROBASE_DATACENTER= SKIP_SYNC=1
  [[ "$output" == *"datacenter.sh local-binds"* ]]
  copied=$(grep -n 'datacenter.sh local-binds' <<<"$output" | head -n 1 | cut -d: -f1)
  started=$(grep -n 'compose up -d\|compose up' <<<"$output" | grep -v 'apps/grobase' | head -n 1 | cut -d: -f1)
  [ -n "$started" ]
  [ "$copied" -lt "$started" ]
}

@test "make frontends-up: a data center never reaches local-binds, which would empty the VM's roster" {
  repo
  stub openssl 'exit 0'
  run make -n frontends-up GROBASE_DATACENTER=b2b SKIP_SYNC=1
  [[ "$output" != *"local-binds"* ]]
}

@test "make link-frontends-start: the same frontends with no data center get the copy" {
  repo
  stub openssl 'exit 0'
  run make -n link-frontends-start GROBASE_DATACENTER= SKIP_SYNC=1
  [[ "$output" == *"datacenter.sh local-binds"* ]]
}

@test "make all: a data center keeps its own binds step, which holds the VM's roster" {
  repo
  stub openssl 'exit 0'
  run make -n all GROBASE_DATACENTER=b2b SKIP_SYNC=1
  [[ "$output" == *"datacenter.sh binds"* ]]
  [[ "$output" != *"local-binds"* ]]
}

# binds_seen_by_recipes — what a recipe's compose would read, from the real Makefile. Prints
# "unset" when the variable is not in the recipe's environment at all.
binds_seen_by_recipes() {
  make --no-print-directory GROBASE_DATACENTER= \
    --eval 'show-binds: ; @printf "[%s]\n" "$${GROOT_READ_BINDS-unset}"' show-binds
}

@test "make: recipes on the local path see no setting off NFS" {
  repo
  stub stat 'echo ext2/ext3'
  run binds_seen_by_recipes
  [ "$output" = "[unset]" ]
}

@test "make: recipes on the local path see the copy on NFS under rootless Docker" {
  repo
  stub stat 'echo nfs'
  stub docker 'case "$*" in *SecurityOptions*) echo "[name=rootless]" ;; *DockerRootDir*) echo /goinfre/me/docker ;; esac'
  run binds_seen_by_recipes
  [ "$output" = "[/goinfre/me/groot-read-binds]" ]
}

@test "verify: API docs the edge refuses fail the run" {
  verified_stack
  stub curl 'case "$*" in */docs/*) printf 403 ;; *) printf 200 ;; esac'
  dc verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"/docs/ answered 403"* ]]
}

@test "roster: a VM that does not answer says so, not that an account is missing" {
  vault_set
  stub ssh 'case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser d\n" ;; *) exit 255 ;; esac'
  dc binds
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not read the agency accounts"* ]]
}

@test "verify: a browser run that passes by skipping is not a pass" {
  verified_stack
  mkdir -p "$ROOT/tests/e2e"
  printf '#!/bin/sh\necho "  2 skipped"\necho "  20 passed"\n' >"$ROOT/tests/e2e/run.sh"
  DATACENTER_VERIFY_BROWSERS=1 dc verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"skipped"* ]]
}

# pinned_vm — an answering VM whose grobase is at no pin; fake_own_vm decides whose it is.
pinned_vm() {
  vault_set
  mkdir -p "$ROOT/vendor/born2root/profiles"
  printf 'grobase_ref = "%s"\n' "$(printf 'a%.0s' $(seq 40))" >"$ROOT/vendor/born2root/profiles/server.toml"
  vm_says 3 2026-01-01
}

@test "vm: this machine's own VM off the pinned commit is reinstalled on the local plan" {
  pinned_vm
  fake_own_vm
  DATACENTER_ALLOW_WRITES=1 dc vm
  [[ "$output" == *"not at the pinned commit"* ]]
  grep -q '^make .*grobase .*GROBASE_ADDONS=observability engines ops studio control playground secrets mysql8 vault42' "$LOG"
}

@test "vm: an auto-start block whose checkout is gone is reinstalled from this clone" {
  pinned_vm
  fake_own_vm
  stub crontab "printf '%s\\n' '# b2b-autostart baas begin' '* * * * * cd /gone/born2root && B2B_CONFIG=profiles/server.toml VM_NAME=baas VM_PATH=$BATS_TEST_TMPDIR/vms x' '# b2b-autostart baas end'"
  DATACENTER_ALLOW_WRITES=1 dc vm
  grep -q '^make .*autostart' "$LOG"
}

# seed_vm COUNT — this user's own VM at the pin, on the plan, whose platform answers COUNT; the
# record appears once make runs, as set_seeds would write it.
seed_vm() {
  mkdir -p "$ROOT/vendor/born2root/profiles"
  printf 'grobase_ref = "%s"\n' "$(printf 'a%.0s' $(seq 40))" >"$ROOT/vendor/born2root/profiles/server.toml"
  vault_set
  fake_own_vm
  stub ssh "case \"\$*\" in
  -G*) printf 'hostname 127.0.0.1\\nport 4242\\nuser dlesieur\\n' ;;
  *'docker ps'*) echo mini-baas-waf ;;
  *rev-parse*) printf 'a%.0s' \$(seq 40) ;;
  *grobase.conf*) echo 'GROBASE_ADDONS=observability engines ops studio control playground secrets mysql8 vault42' ;;
  *public.tenants*) printf '$1' ;;
  *seeds.last*) [ ! -e '$LOG.seeded' ] || echo seeded ;;
esac"
  stub make "echo \"make \$*\" >>\"\$LOG\"; case \"\$*\" in *set_seeds*) : >\"$LOG.seeded\" ;; esac"
}

@test "seed: a fresh grobase holding only its vault42 tenant is seeded, then that plane comes back" {
  seed_vm 0
  DATACENTER_ALLOW_WRITES=1 dc vm
  [ "$status" -eq 0 ]
  grep -q '^make .*set_seeds .*FORCE=1' "$LOG"
  [ "$(grep -n 'set_seeds' "$LOG" | cut -d: -f1 | head -n 1)" -lt "$(grep -n 'make grobase\|make .*grobase GROBASE_ADDONS' "$LOG" | cut -d: -f1 | tail -n 1)" ]
}

@test "seed: a platform with accounts and no record stops, and nothing is forced" {
  seed_vm 3
  DATACENTER_ALLOW_WRITES=1 dc vm
  [ "$status" -eq 1 ]
  [[ "$output" == *"no record of a seed"* ]]
  ! grep -q 'FORCE=1' "$LOG"
}

@test "seed: a count Postgres could not give is never forced" {
  seed_vm ''
  DATACENTER_ALLOW_WRITES=1 dc vm
  ! grep -q 'FORCE=1' "$LOG"
}

@test "seed: the query leaves out only the vault42 plane's tenant, and counts accounts" {
  grep -q "where slug <> 'vault42'" "$ROOT/scripts/lib/datacenter-vm.sh"
  grep -q 'count(\*) from auth.users' "$ROOT/scripts/lib/datacenter-vm.sh"
}

@test "vm: a repair that leaves grobase unhealthy names what is failing" {
  pinned_vm
  fake_own_vm
  stub ssh 'case "$*" in
  -G*) printf "hostname 127.0.0.1\nport 4242\nuser dlesieur\n" ;;
  *"docker ps"*) echo mini-baas-waf ;;
  *rev-parse*) printf "a%.0s" $(seq 40) ;;
  *grobase.conf*) ;;
  *public.tenants*) echo 3 ;;
  *seeds.last*) echo 2026-01-01 ;;
esac
case "$*" in *grobase-health*) echo "  ✗ scrape targets DOWN: vault:8200"; exit 1 ;; esac'
  DATACENTER_ALLOW_WRITES=1 dc vm
  [ "$status" -eq 1 ]
  [[ "$output" == *"scrape targets DOWN: vault:8200"* ]]
}

@test "vm: a grobase behind another alias is never reinstalled, whatever its state" {
  pinned_vm
  printf 'GROBASE_DATACENTER=prod-host\n' >"$CTL_CFG_DIR/secrets/datacenter.env"
  DATACENTER_ALLOW_WRITES=1 dc vm
  ! grep -q '^make .*grobase' "$LOG"
}

@test "vm: a loopback port this user does not own is not this user's VM" {
  pinned_vm
  DATACENTER_ALLOW_WRITES=1 dc vm
  ! grep -q '^make .*grobase' "$LOG"
}

@test "plan: production's own definitions are left alone" {
  repo
  ! grep -qE '^dc-tunnel' vendor/born2root/profiles/server.toml
  grep -q 'LOCAL_GROBASE_ADDONS=' scripts/lib/datacenter-vm.sh
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

# Measured 2026-11-04: osionos-node held 127.0.0.1:4100, and the edge publishes that port for the
# Mail bridge, so the whole edge refused to start. The container's own port stays fixed: nginx
# proxies to mail-bridge:4100, so moving that with the host's would break Mail.
@test "host ports: the Mail and Calendar bridges move like every other published port" {
  run bash "$BATS_TEST_DIRNAME/../host-ports.sh" list
  [[ "$output" == *"MAIL_BRIDGE_HOST_PORT=4100"* ]]
  [[ "$output" == *"CALENDAR_BRIDGE_HOST_PORT=4200"* ]]
  grep -q 'MAIL_BRIDGE_PORT: ${MAIL_BRIDGE_PORT:-4100}' "$BATS_TEST_DIRNAME/../../docker-compose.yml"
  ! grep -q 'https://localhost:${MAIL_BRIDGE_PORT' "$BATS_TEST_DIRNAME/../../docker-compose.yml"
}

@test "sync: vendor/born2root stays at its gitlink, because groot drives that tested commit" {
  grep -E '^PARENT_PINNED' "$BATS_TEST_DIRNAME/../../utils/mk/repo.mk" | grep -q 'vendor/born2root'
}

@test "dev-rebuild-server: the Update button's make all runs with no terminal on stdin" {
  grep -q 'stdin=subprocess.DEVNULL' "$BATS_TEST_DIRNAME/../dev-rebuild-server.py"
}
