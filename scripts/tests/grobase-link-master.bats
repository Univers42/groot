#!/usr/bin/env bats
# The link's ssh master authenticates the VM by the host key pinned in the link conf, never by the
# user's ssh config (ruling LM-2, 2026-11-23). That config says StrictHostKeyChecking no for the
# loopback port a stopped qemu leaves free, and whoever binds it there would hand the link its own
# .env. A real sshd on 127.0.0.1 plays the VM, presenting the pinned key (genuine) or another one
# (impostor); every key is generated per test and nothing here reaches a real host.
# The sshd tests need sshd, ssh and ssh-keygen (CI: apk add openssh) and skip without them; the
# others stub ssh.
#
# Run: docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#        -c 'apk add -q --no-cache openssh && bats scripts/tests/grobase-link-master.bats'
# shellcheck disable=SC2016 # stub bodies are single-quoted on purpose: they expand when the stub runs

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/scripts/lib" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/home/.ssh"
  cp "$BATS_TEST_DIRNAME/../grobase-link.sh" "$BATS_TEST_DIRNAME/../gen-local-env.sh" "$ROOT/scripts/"
  cp "$BATS_TEST_DIRNAME"/../lib/envfile.sh "$BATS_TEST_DIRNAME"/../lib/grobase-remote-dir.sh \
    "$BATS_TEST_DIRNAME"/../lib/grobase-link*.sh "$ROOT/scripts/lib/"
  SCRIPT="$ROOT/scripts/grobase-link.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  export GROBASE_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export GROBASE_LINK_CONF="$BATS_TEST_TMPDIR/link.env"
  export GROBASE_REMOTE_ENV="$ROOT/.env.grobase-datacenter.local"
  export GROBASE_LINK_HOST_PORT=0
  mkdir -p "$GROBASE_LINK_DIR" # cmd_up makes it (own_link_dir); the helper calls skip cmd_up
  printf 'JWT_SECRET=the-link-s-own-fake\nKEEP=1\n' >"$ROOT/.env.local"
  cp "$ROOT/.env.local" "$BATS_TEST_TMPDIR/env.local.before"
}

teardown() {
  [ ! -S "$GROBASE_LINK_DIR/ssh.ctl" ] || ssh -F /dev/null -S "$GROBASE_LINK_DIR/ssh.ctl" -O exit x 2>/dev/null || true
  [ -z "${SSHD_PID:-}" ] || kill "$SSHD_PID" 2>/dev/null || true
  [ -z "${OWN_SSH_CONFIG:-}" ] || rm -f "$OWN_SSH_CONFIG"
}

stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

need_sshd() {
  SSHD=$(command -v sshd || true)
  if [ -z "$SSHD" ] || ! command -v ssh >/dev/null || ! command -v ssh-keygen >/dev/null; then
    skip "needs sshd, ssh and ssh-keygen (apk add openssh)"
  fi
  mkdir -p "$BATS_TEST_TMPDIR/keys"
  ssh-keygen -q -t ed25519 -N '' -C genuine -f "$BATS_TEST_TMPDIR/keys/genuine"
  ssh-keygen -q -t ed25519 -N '' -C impostor -f "$BATS_TEST_TMPDIR/keys/impostor"
  ssh-keygen -q -t ed25519 -N '' -C link-user -f "$HOME/.ssh/id_ed25519"
  cp "$HOME/.ssh/id_ed25519.pub" "$BATS_TEST_TMPDIR/authorized_keys"
  GENUINE_KEY=$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/keys/genuine.pub")
}

# start_vm HOSTKEY_FILE — sshd on a free loopback port with that host key, the link user's key
# authorized, and a `docker` on its PATH that shows one Kong, as the VM would; sets PORT.
start_vm() {
  local _
  mkdir -p "$BATS_TEST_TMPDIR/vm-bin" "$BATS_TEST_TMPDIR/vm-grobase"
  printf '#!/bin/sh\ncase "$*" in\n"ps "*) echo mini-baas-kong ;;\n*NetworkSettings.Ports*) printf "N /mini-baas-kong 127.0.0.1\\nP /mini-baas-kong 8000/tcp 127.0.0.1:8000\\n" ;;\nesac\n' \
    >"$BATS_TEST_TMPDIR/vm-bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/vm-bin/docker"
  printf 'JWT_SECRET=served-by-%s\n' "${1##*/}" >"$BATS_TEST_TMPDIR/vm-grobase/.env"
  export GROBASE_REMOTE_DIR="$BATS_TEST_TMPDIR/vm-grobase"
  for _ in 1 2 3 4 5; do
    PORT=$((20000 + RANDOM % 30000))
    cat >"$BATS_TEST_TMPDIR/sshd_config" <<EOF
ListenAddress 127.0.0.1:$PORT
HostKey $1
PidFile none
AuthorizedKeysFile $BATS_TEST_TMPDIR/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
AllowTcpForwarding yes
SetEnv PATH=$BATS_TEST_TMPDIR/vm-bin:/usr/bin:/bin:/usr/sbin:/sbin
LogLevel VERBOSE
EOF
    "$SSHD" -D -f "$BATS_TEST_TMPDIR/sshd_config" -E "$BATS_TEST_TMPDIR/sshd.log" 3>&- &
    SSHD_PID=$!
    for _ in $(seq 50); do
      kill -0 "$SSHD_PID" 2>/dev/null || break
      (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0
      sleep 0.1
    done
    kill "$SSHD_PID" 2>/dev/null || true
  done
  return 1
}

# The production host's alias config (ruling F2): accept any host key, keep none, forward the agent.
# ssh reads it from the passwd home, not $HOME, so only a throwaway container's root may write it.
own_ssh_config_like_production() {
  if [ "$(id -u)" -ne 0 ] || [ ! -f /.dockerenv ] || [ -e /root/.ssh/config ]; then
    skip "writes /root/.ssh/config: only as root in a throwaway container that has none"
  fi
  mkdir -p /root/.ssh
  OWN_SSH_CONFIG=/root/.ssh/config
  printf 'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  ForwardAgent yes\n  IdentityFile %s\n' \
    "$HOME/.ssh/id_ed25519" >"$OWN_SSH_CONFIG"
}

link_conf() { printf 'GROBASE_TARGET=ssh://%s@127.0.0.1:%s\nGROBASE_LINK_HOST_KEY=%s\n' "$(id -un)" "$PORT" "$1" >"$GROBASE_LINK_CONF"; }

@test "impostor: a VM with another host key is refused even when the user's ssh config accepts any key" {
  need_sshd
  own_ssh_config_like_production
  start_vm "$BATS_TEST_TMPDIR/keys/impostor"
  link_conf "$GENUINE_KEY"
  run bash "$SCRIPT" up 3>&-
  [ "$status" -ne 0 ]
  [[ "$output" == *"GROBASE_LINK_HOST_KEY"* ]]
  run bash "$SCRIPT" env 3>&-
  [ "$status" -ne 0 ]
  [ ! -e "$GROBASE_REMOTE_ENV" ]
  cmp "$ROOT/.env.local" "$BATS_TEST_TMPDIR/env.local.before"
  [ ! -S "$GROBASE_LINK_DIR/ssh.ctl" ]
  [ ! -e "$GROBASE_LINK_DIR/state" ]
  run ! grep -q 'Accepted publickey' "$BATS_TEST_TMPDIR/sshd.log"
}

@test "genuine: the pinned key opens the master, and the VM's .env is read through it" {
  need_sshd
  start_vm "$BATS_TEST_TMPDIR/keys/genuine"
  link_conf "$GENUINE_KEY"
  run bash -c "source '$SCRIPT' && open_master ssh://$(id -un)@127.0.0.1:$PORT && fetch_remote_env" 3>&-
  [ "$status" -eq 0 ]
  grep -qx 'JWT_SECRET=served-by-genuine' "$GROBASE_REMOTE_ENV"
  grep -q 'Accepted publickey' "$BATS_TEST_TMPDIR/sshd.log"
}

@test "no pinned key: ssh mode refuses before any ssh, naming GROBASE_LINK_HOST_KEY and the conf" {
  stub ssh 'echo "ssh $*" >>"$BATS_TEST_TMPDIR/ssh.log"; exit 1'
  printf 'GROBASE_TARGET=ssh://alice@127.0.0.1:4242\n' >"$GROBASE_LINK_CONF"
  run bash "$SCRIPT" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"GROBASE_LINK_HOST_KEY"* ]]
  [[ "$output" == *"$GROBASE_LINK_CONF"* ]]
  run ! grep -q ControlMaster "$BATS_TEST_TMPDIR/ssh.log"
  [ ! -e "$GROBASE_LINK_DIR/state" ]
}

@test "open_master: the alias gives host, port, user and key file only; agent, forwards and host-key policy are pinned" {
  stub ssh 'echo "ssh $*" >>"$BATS_TEST_TMPDIR/ssh.log"
case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser alice\nidentityfile ~/.ssh/id_ed25519\nidentityfile ~/.ssh/absent\n" ;; -F\ /dev/null\ -S*) exit 1 ;; esac'
  : >"$HOME/.ssh/id_ed25519"
  GROBASE_LINK_HOST_KEY='ssh-ed25519 AAAAgenuine' run bash -c "source '$SCRIPT' && open_master b2b"
  [ "$status" -eq 0 ]
  line=$(grep ControlMaster=yes "$BATS_TEST_TMPDIR/ssh.log")
  for opt in '-F /dev/null' StrictHostKeyChecking=yes HostKeyAlias=grobase-link \
    "UserKnownHostsFile=$GROBASE_LINK_DIR/link_known_hosts" GlobalKnownHostsFile=/dev/null \
    IdentitiesOnly=yes IdentityAgent=none ForwardAgent=no ClearAllForwardings=yes \
    "-i $HOME/.ssh/id_ed25519 -p 4242 -l alice -N -f 127.0.0.1"; do
    [[ "$line" == *"$opt"* ]]
  done
  [[ "$line" != *absent* ]]
  [ "$(cat "$GROBASE_LINK_DIR/link_known_hosts")" = 'grobase-link ssh-ed25519 AAAAgenuine' ]
}

@test "open_master: a pinned key that is not one '<type> <base64>' line is refused before any ssh" {
  stub ssh 'echo "ssh $*" >>"$BATS_TEST_TMPDIR/ssh.log"; exit 1'
  local bad
  for bad in 'ssh-ed25519' $'ssh-ed25519 AAAA\n@cert-authority * ssh-ed25519 BBBB' 'ssh-ed25519 AA AA'; do
    rm -f "$BATS_TEST_TMPDIR/ssh.log"
    GROBASE_LINK_HOST_KEY="$bad" run bash -c "source '$SCRIPT' && open_master b2b"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GROBASE_LINK_HOST_KEY"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/ssh.log" ] || run ! grep -q ControlMaster "$BATS_TEST_TMPDIR/ssh.log"
  done
}

@test "open_master: a live master opened under another pin, or none, is closed and reopened" {
  stub ssh 'echo "ssh $*" >>"$BATS_TEST_TMPDIR/ssh.log"
case "$*" in -G*) printf "hostname 127.0.0.1\nport 4242\nuser alice\n" ;; esac'
  printf 'mode=ssh\ntarget=b2b\n' >"$GROBASE_LINK_DIR/state"
  GROBASE_LINK_HOST_KEY='ssh-ed25519 AAAAgenuine' run bash -c "source '$SCRIPT' && open_master b2b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"closing the master to b2b"* ]]
  [ "$(grep -c ControlMaster=yes "$BATS_TEST_TMPDIR/ssh.log")" -eq 1 ]
  : >"$BATS_TEST_TMPDIR/ssh.log"
  GROBASE_LINK_HOST_KEY='ssh-ed25519 AAAAgenuine' run bash -c "source '$SCRIPT' && open_master b2b"
  [ "$status" -eq 0 ]
  [[ "$output" != *"closing the master"* ]]
  run ! grep -q ControlMaster=yes "$BATS_TEST_TMPDIR/ssh.log"
  GROBASE_LINK_HOST_KEY='ssh-ed25519 AAAArepinned' run bash -c "source '$SCRIPT' && open_master b2b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"closing the master to b2b"* ]]
  grep -q ControlMaster=yes "$BATS_TEST_TMPDIR/ssh.log"
}
