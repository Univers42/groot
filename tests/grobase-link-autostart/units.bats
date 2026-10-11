#!/usr/bin/env bats
# make link-autostart renders the systemd user units for this clone, and the LAN edge forwards to
# the port QEMU actually bound (ports.env), not an assumed 8443. systemctl, make, loginctl, ip and
# socat are stubs on PATH: nothing here touches the host's units or network.
#   bats tests/grobase-link-autostart

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  STUBS=$BATS_TEST_TMPDIR/bin
  mkdir -p "$STUBS"
  for cmd in systemctl make loginctl; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n[ "$1" != show-user ] || echo yes\n' \
      "$cmd" "$BATS_TEST_TMPDIR" >"$STUBS/$cmd"
  done
  printf '#!/bin/sh\necho "2: enp7s0    inet 192.168.1.132/24 brd 192.168.1.255 scope global"\n' >"$STUBS/ip"
  printf '#!/bin/sh\necho "socat $*"\n' >"$STUBS/socat"
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH" XDG_CONFIG_HOME=$BATS_TEST_TMPDIR/config
  UNITS=$XDG_CONFIG_HOME/systemd/user
}

@test "install renders every unit for this clone, with no placeholder left" {
  LAN_IF=enp7s0 VM_PORTS_FILE=/vm/ports.env run bash "$REPO/scripts/grobase-link-autostart.sh" install
  [ "$status" -eq 0 ]
  for unit in grobase-link.service grobase-link-heal.service grobase-link-heal.timer grobase-lan-edge.service; do
    [ -f "$UNITS/$unit" ]
    ! grep -q '@[A-Z_]*@' "$UNITS/$unit"
  done
  grep -qx "WorkingDirectory=$REPO" "$UNITS/grobase-link.service"
  grep -qx "Environment=LAN_IF=enp7s0" "$UNITS/grobase-lan-edge.service"
  grep -qx "Environment=VM_PORTS_FILE=/vm/ports.env" "$UNITS/grobase-lan-edge.service"
}

@test "without LAN_IF the LAN edge is not installed" {
  run bash "$REPO/scripts/grobase-link-autostart.sh" install
  [ "$status" -eq 0 ]
  [ -f "$UNITS/grobase-link.service" ]
  [ ! -e "$UNITS/grobase-lan-edge.service" ]
  ! grep -q "lan-edge" "$BATS_TEST_TMPDIR/calls"
}

@test "a differing installed unit is backed up before it is replaced" {
  mkdir -p "$UNITS"
  echo "hand-edited" >"$UNITS/grobase-link.service"
  run bash "$REPO/scripts/grobase-link-autostart.sh" install
  [ "$status" -eq 0 ]
  grep -qx "hand-edited" "$UNITS"/grobase-link.service.bak-*
}

@test "the LAN edge forwards to the https port in ports.env" {
  printf 'ssh=4242\nhttps=8445\n' >"$BATS_TEST_TMPDIR/ports.env"
  LAN_IF=enp7s0 VM_PORTS_FILE=$BATS_TEST_TMPDIR/ports.env run bash "$REPO/scripts/grobase-lan-edge.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"socat TCP-LISTEN:8443,bind=192.168.1.132,fork,reuseaddr TCP:127.0.0.1:8445"* ]]
}

@test "the LAN edge falls back to 8443 with no ports file" {
  LAN_IF=enp7s0 VM_PORTS_FILE=$BATS_TEST_TMPDIR/absent run bash "$REPO/scripts/grobase-lan-edge.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TCP:127.0.0.1:8443"* ]]
}
