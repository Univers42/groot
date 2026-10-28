#!/usr/bin/env bats
# make publish-socket renders the systemd user unit that forwards this host's unix socket to
# the data center VM's Kong over ssh -L (0.43 ms p50 instead of the ~10 ms p50 tailnet hop), so
# the osionos bridge's co-edit publishes skip Tailscale. systemctl is a stub on PATH and HOME,
# XDG_CONFIG_HOME and XDG_STATE_HOME sit under $BATS_TEST_TMPDIR, with a plain fake
# ~/.ssh/id_ed25519: nothing here touches the host's units, keys or network (the script itself
# never runs ssh).
#   bats tests/osionos-publish-socket

bats_require_minimum_version 1.5.0

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  STUBS=$BATS_TEST_TMPDIR/bin
  mkdir -p "$STUBS"
  cat >"$STUBS/systemctl" <<STUB
#!/bin/sh
echo "systemctl \$*" >>"$BATS_TEST_TMPDIR/calls"
[ "\$2" != is-active ] || echo active
STUB
  chmod +x "$STUBS/systemctl"
  export PATH="$STUBS:$PATH" HOME=$BATS_TEST_TMPDIR/home XDG_CONFIG_HOME=$BATS_TEST_TMPDIR/config XDG_STATE_HOME=$BATS_TEST_TMPDIR/state
  mkdir -p "$HOME/.ssh"
  : >"$HOME/.ssh/id_ed25519"
  UNITS=$XDG_CONFIG_HOME/systemd/user
  STATE=$XDG_STATE_HOME/osionos-publish
  UNIT=osionos-publish-socket.service
  # a real key: install validates it with ssh-keygen -l
  ssh-keygen -q -t ed25519 -N '' -C vm-test -f "$BATS_TEST_TMPDIR/hostkey"
  KEY=$BATS_TEST_TMPDIR/hostkey.pub
}

refuses_install() { # every argument is an env assignment; the install must exit 2 and enable nothing
  run env "$@" bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 2 ]
  [ ! -e "$UNITS/$UNIT" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "install renders the unit: every pinned ssh option, Kong on 8000, nothing from ~/.ssh/config" {
  HOST_KEY_FILE=$KEY run bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 0 ]
  [ -f "$UNITS/$UNIT" ]
  run ! grep -q '@[A-Z_]*@' "$UNITS/$UNIT"
  # the unit wraps ExecStart with backslashes; join them, then assert every option of the ruling
  execstart=$(sed -e ':a' -e 'N' -e '$!ba' -e 's/\\\n/ /g' "$UNITS/$UNIT" | grep '^ExecStart=')
  opts=(
    '-F none'
    '-N'
    '-T'
    '-p 4242'
    "-i $HOME/.ssh/id_ed25519"
    '-o BatchMode=yes'
    '-o IdentitiesOnly=yes'
    '-o IdentityAgent=none'
    '-o ControlMaster=no'
    '-o ControlPath=none'
    '-o ExitOnForwardFailure=yes'
    '-o StreamLocalBindUnlink=yes'
    '-o StreamLocalBindMask=0177'
    '-o ServerAliveInterval=5'
    '-o ServerAliveCountMax=3'
    '-o StrictHostKeyChecking=yes'
    "-o UserKnownHostsFile=$STATE/known_hosts"
    '-o GlobalKnownHostsFile=/dev/null'
    '-o HostKeyAlias=b2b-publish'
    "-L $STATE/sock/kong.sock:127.0.0.1:8000"
    "$(id -un)@127.0.0.1"
  )
  for opt in "${opts[@]}"; do
    [[ " ${execstart#ExecStart=} " == *" $opt "* ]] || {
      echo "ExecStart is missing: $opt"
      return 1
    }
  done
  [[ "$execstart" == *"127.0.0.1:8000"* ]]
  run ! grep -q ':4000' "$UNITS/$UNIT"
  run ! grep -q 'accept-new' "$UNITS/$UNIT"
  run ! grep -q 'StrictHostKeyChecking=no' "$UNITS/$UNIT"
  # "b2b" appears only as the pinned alias and the After unit, never anywhere else
  grep -v -e 'HostKeyAlias=b2b-publish' -e 'After=b2b-vm-baas.service' "$UNITS/$UNIT" >"$BATS_TEST_TMPDIR/rest"
  run ! grep -q 'b2b' "$BATS_TEST_TMPDIR/rest"
}

@test "install pins exactly one host key line, keeps 0700/0600, and enables the unit" {
  HOST_KEY_FILE=$KEY run bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STATE/known_hosts")" -eq 1 ]
  read -r type key _ <"$KEY"
  kline=$(cat "$STATE/known_hosts")
  [[ "$kline" == "b2b-publish ssh-ed25519 "* ]]
  [ "$kline" = "b2b-publish $type $key" ]
  [ "$(stat -c %a "$STATE/known_hosts")" = 600 ]
  [ "$(stat -c %a "$STATE")" = 700 ]
  [ "$(stat -c %a "$STATE/sock")" = 700 ]
  grep -qx 'systemctl --user daemon-reload' "$BATS_TEST_TMPDIR/calls"
  grep -qx 'systemctl --user enable --now osionos-publish-socket.service' "$BATS_TEST_TMPDIR/calls"
  [[ "$output" == *"OSIONOS_PUBLISH_SOCKET_DIR=$STATE/sock"* ]]
}

@test "install without HOST_KEY_FILE refuses with exit 2 before writing or enabling anything" {
  run bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 2 ]
  [[ "$output" == *HOST_KEY_FILE* ]]
  [ ! -e "$UNITS/$UNIT" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "a HOST_KEY_FILE that is not one allowlisted host key line refuses with exit 2" {
  printf 'ssh-dss AAAAB3NzaC1kc3MAAAAANotAnAllowlistedHostKey vm-test\n' >"$BATS_TEST_TMPDIR/dss"
  HOST_KEY_FILE=$BATS_TEST_TMPDIR/dss run bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 2 ]
  printf 'this is not a host key at all\n' >"$BATS_TEST_TMPDIR/garbage"
  HOST_KEY_FILE=$BATS_TEST_TMPDIR/garbage run bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 2 ]
  printf 'ssh-ed25519\n' >"$BATS_TEST_TMPDIR/typeonly"
  HOST_KEY_FILE=$BATS_TEST_TMPDIR/typeonly run bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 2 ]
  [ ! -e "$UNITS/$UNIT" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "a HOST_KEY_FILE with two keys, or a key ssh-keygen rejects, refuses with exit 2" {
  ssh-keygen -q -t ed25519 -N '' -C other -f "$BATS_TEST_TMPDIR/other"
  cat "$KEY" "$BATS_TEST_TMPDIR/other.pub" >"$BATS_TEST_TMPDIR/two"
  refuses_install HOST_KEY_FILE="$BATS_TEST_TMPDIR/two"
  printf 'ssh-ed25519 definitely-not-base64\n' >"$BATS_TEST_TMPDIR/bad"
  refuses_install HOST_KEY_FILE="$BATS_TEST_TMPDIR/bad"
}

@test "a path or ssh user the unit cannot carry as one word refuses with exit 2" {
  refuses_install HOST_KEY_FILE="$KEY" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state with space"
  refuses_install HOST_KEY_FILE="$KEY" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state%n&x"
  refuses_install HOST_KEY_FILE="$KEY" XDG_STATE_HOME="$BATS_TEST_TMPDIR/$(printf 'é%.0s' $(seq 1 30))"
  refuses_install HOST_KEY_FILE="$KEY" PUBLISH_SSH_USER="victim -oProxyCommand=id victim"
  refuses_install HOST_KEY_FILE="$KEY" PUBLISH_SSH_USER="-oProxyCommand=id"
}

@test "a socket path longer than 100 bytes refuses with exit 1 and enables nothing" {
  long=$BATS_TEST_TMPDIR/$(printf 'x%.0s' $(seq 1 130))
  XDG_STATE_HOME=$long HOST_KEY_FILE=$KEY run bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 1 ]
  [ ! -e "$long/osionos-publish" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "remove disables the unit, deletes it, and keeps the pinned key" {
  HOST_KEY_FILE=$KEY run bash "$REPO/scripts/osionos-publish-socket.sh" install
  run bash "$REPO/scripts/osionos-publish-socket.sh" remove
  [ "$status" -eq 0 ]
  grep -qx 'systemctl --user disable --now osionos-publish-socket.service' "$BATS_TEST_TMPDIR/calls"
  [ ! -e "$UNITS/$UNIT" ]
  [ -f "$STATE/known_hosts" ]
}

@test "remove that cannot disable the unit fails and never reports off" {
  HOST_KEY_FILE=$KEY run bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 0 ]
  printf '#!/bin/sh\n[ "$2" != disable ] || exit 1\n' >"$STUBS/systemctl"
  run bash "$REPO/scripts/osionos-publish-socket.sh" remove
  [ "$status" -ne 0 ]
  [[ "$output" != *off* ]]
  [ -f "$UNITS/$UNIT" ]
}

@test "remove with no unit installed succeeds" {
  run bash "$REPO/scripts/osionos-publish-socket.sh" remove
  [ "$status" -eq 0 ]
  run ! grep -q disable "$BATS_TEST_TMPDIR/calls"
}

@test "the unit restarts forever and comes up with the user session" {
  HOST_KEY_FILE=$KEY run bash "$REPO/scripts/osionos-publish-socket.sh" install
  [ "$status" -eq 0 ]
  grep -qx 'Restart=always' "$UNITS/$UNIT"
  grep -qx 'RestartSec=5' "$UNITS/$UNIT"
  grep -qx 'StartLimitIntervalSec=0' "$UNITS/$UNIT"
  grep -qx 'WantedBy=default.target' "$UNITS/$UNIT"
}

@test "status reports the unit and the socket without ever printing key material" {
  HOST_KEY_FILE=$KEY run bash "$REPO/scripts/osionos-publish-socket.sh" install
  run bash "$REPO/scripts/osionos-publish-socket.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"unit: active"* ]]
  [[ "$output" == *"socket: $STATE/sock/kong.sock missing"* ]]
  [[ "$output" != *AAAAC3NzaC1lZDI1NTE5* ]]
}

@test "a fresh clone stays clean: the .in template ships, nothing rendered is committed (S13)" {
  [ -f "$REPO/infrastructure/systemd/user/osionos-publish-socket.service.in" ]
  run find "$REPO" -name osionos-publish-socket.service -not -path '*/.git/*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  if command -v git >/dev/null 2>&1; then
    if git -C "$REPO" status --short | grep -E 'osionos-publish-socket\.service$'; then
      echo "a rendered unit is in the tree: only the .in template belongs in the repo"
      return 1
    fi
  fi
}
