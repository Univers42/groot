#!/usr/bin/env bats
# install-egress-nat.sh writes the systemd drop-in that loads the IDE egress firewall.
# It must run `up` as ExecStartPre with no dash (fail closed: no firewall, no daemon) and
# must not wire `down` to stop (boxes outlive a crashed dockerd). `print` shows the exact
# drop-in without root, so these tests read the text the installer would write.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  INSTALLER="$REPO/infrastructure/docker/osionos/ide-sandbox/install-egress-nat.sh"
}

@test "print shows the drop-in and needs no root" {
  run sh "$INSTALLER" print
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "[Service]" ]
}

@test "the drop-in is exactly one ExecStartPre running up, no dash" {
  run sh "$INSTALLER" print
  [ "$status" -eq 0 ]
  [ "$output" = "[Service]
ExecStartPre=/usr/local/sbin/osionos-ide-egress-nat up" ]
}

@test "exactly one ExecStartPre line for up" {
  run sh "$INSTALLER" print
  [ "$(printf '%s\n' "$output" | grep -c '^ExecStartPre=/usr/local/sbin/osionos-ide-egress-nat up$')" -eq 1 ]
}

@test "no ExecStartPost and no ExecStopPost line" {
  run sh "$INSTALLER" print
  [ "$(printf '%s\n' "$output" | grep -c '^ExecStartPost=')" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^ExecStopPost=')" -eq 0 ]
}

@test "no failure-ignoring dash after any equals sign" {
  run sh "$INSTALLER" print
  [ "$(printf '%s\n' "$output" | grep -c '=-')" -eq 0 ]
}

@test "the install path still requires root" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run sh "$INSTALLER"
  [ "$status" -eq 1 ]
  [ "$output" = "run with sudo" ]
}
