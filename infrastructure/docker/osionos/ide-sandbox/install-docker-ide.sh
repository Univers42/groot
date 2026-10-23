#!/bin/sh
# ************************************************************************** #
#                                                                            #
#                                                        :::      ::::::::    #
#   install-docker-ide.sh                              :+:      :+:    :+:   #
#                                                    +:+ +:+         +:+     #
#   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        #
#                                                +#+#+#+#+#+   +#+           #
#   Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#             #
#   Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr       #
#                                                                            #
# ************************************************************************** #
#
# Install (idempotent) the docker-ide daemon and prove it: the osionos IDE
# sandboxes run inside ONE capped systemd slice, on their own containerd
# namespaces, with their own daemon.json. Run: sudo sh install-docker-ide.sh
#
# The production stack on the main daemon must not notice docker-ide starting
# or restarting: the script snapshots the main daemon's running container ids
# first (mktemp, removed by a trap on EXIT) and verifies them byte-identical at
# the end. It never removes or stops anything and never touches /etc/docker.

set -eu

UNIT_DIR=/etc/systemd/system
CONF_DIR=/etc/docker-ide
SOCK_PATH=/run/docker-ide.sock
SOCK_URL=unix://$SOCK_PATH
DATA_ROOT=/var/lib/docker-ide

ok=0
fail=0

ide() { docker -H "$SOCK_URL" "$@"; }

pass()  { printf 'ok  %s\n' "$1"; ok=$((ok + 1)); }
fail_() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

main() {
  refuse_unless_root
  refuse_unless_prjquota
  refuse_unless_main_on_iptables
  srcdir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
  before=$(mktemp)
  trap 'rm -f "$before"' EXIT
  docker ps -q --no-trunc | sort >"$before"
  install_units
  bring_up_daemon
  verify "$before"
  printf 'RESULT: %d ok, %d failed\n' "$ok" "$fail"
  [ "$fail" -eq 0 ] || exit 1
}

refuse_unless_root() {
  [ "$(id -u)" -eq 0 ] || {
    echo "refusing: not root (run: sudo sh install-docker-ide.sh)" >&2
    exit 1
  }
}

refuse_unless_prjquota() {
  opts=$(findmnt -no OPTIONS --mountpoint "$DATA_ROOT") || {
    echo "refusing: $DATA_ROOT is not a mountpoint" >&2
    exit 1
  }
  case ",$opts," in
    *,prjquota,*) ;;
    *) echo "refusing: $DATA_ROOT is not mounted with prjquota (options: $opts)" >&2; exit 1 ;;
  esac
}

# A dockerd started with --iptables=false deletes the `docker-bridges` nftables tables on start
# (measured on baas, Docker 29.9.0: "Deleting nftables IPv6 rules"). Those tables are the main
# daemon's rules when it runs the nftables firewall backend, so docker-ide would strip them.
refuse_unless_main_on_iptables() {
  backend=$(docker info --format '{{.FirewallBackend.Driver}}' 2>/dev/null || true)
  [ "$backend" = iptables ] || {
    echo "refusing: the main daemon's firewall backend is '${backend:-unknown}', not iptables;" \
      "docker-ide would delete its nftables tables on start" >&2
    exit 1
  }
}

install_units() {
  install -o root -g root -m 0644 "$srcdir/docker-ide.service" "$UNIT_DIR/docker-ide.service"
  # A host that installed the old set has no socket unit, and without it dockerd
  # goes back to creating (and re-creating on restart) the socket itself.
  install -o root -g root -m 0644 "$srcdir/docker-ide.socket" "$UNIT_DIR/docker-ide.socket"
  install -o root -g root -m 0644 "$srcdir/osionos-ide.slice" "$UNIT_DIR/osionos-ide.slice"
  install -o root -g root -m 0755 "$srcdir/restore-docker0.sh" /usr/local/sbin/osionos-ide-restore-docker0
  install -d -m 0755 "$CONF_DIR"
  install -o root -g root -m 0644 "$srcdir/docker-ide.daemon.json" "$CONF_DIR/daemon.json"
}

# The order is written for a host where the OLD unit is still running and dockerd
# itself owns $SOCK_PATH: the daemon must let go of the path before systemd can
# take the socket over, and the socket must exist before the daemon that
# inherits it starts.
bring_up_daemon() {
  systemctl daemon-reload
  # Releases the old socket file (a no-op when the service is already stopped,
  # which is what a fresh host looks like after install_units above).
  systemctl stop docker-ide.service
  # From here on systemd owns the socket, so every later restart reuses one inode.
  systemctl enable --now docker-ide.socket
  systemctl enable docker-ide.service
  systemctl restart docker-ide.service
  wait_for_daemon "start"
  # The restart re-reads the new unit — slice, containerd namespaces, own
  # config file — so the final state is proven, not just the first start.
  systemctl restart docker-ide.service
  wait_for_daemon "second restart"
}

wait_for_daemon() {
  i=0
  # Ponytail: 60 tries 1 s apart is an estimate — a cold containerd on a loaded
  # host can need more; the wait then ends and the script stops with a message
  # rather than hanging forever.
  while [ "$i" -lt 60 ]; do
    if ide info >/dev/null 2>&1; then return 0; fi
    i=$((i + 1))
    sleep 1
  done
  echo "refusing: docker-ide did not answer on $SOCK_URL within 60 s of $1" >&2
  exit 1
}

verify() {
  verify_daemon_plane "$1"
  verify_socket_unit
  verify_socket_outlives_restart
}

# What the RUNNING daemon reports. A value it cannot give (unreachable daemon,
# failing `ide info`) comes back empty, and empty is a FAIL — never a pass.
verify_daemon_plane() {
  if docker ps -q --no-trunc | sort | cmp -s - "$1"; then
    pass "main daemon running containers byte-identical"
  else
    fail_ "main daemon running containers changed"
  fi

  if systemctl show -p ControlGroup docker-ide | grep -q osionos-ide.slice; then
    pass "docker-ide ControlGroup is osionos-ide.slice"
  else
    fail_ "docker-ide ControlGroup is not osionos-ide.slice"
  fi

  rootdir=$(ide info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  case "$rootdir" in
    "$DATA_ROOT"*) pass "docker-ide DockerRootDir is under $DATA_ROOT" ;;
    *) fail_ "docker-ide DockerRootDir is not under $DATA_ROOT" ;;
  esac

  driver=$(ide info --format '{{.CgroupDriver}}' 2>/dev/null || true)
  if [ "$driver" = systemd ]; then
    pass "docker-ide CgroupDriver is systemd"
  else
    fail_ "docker-ide CgroupDriver is not systemd"
  fi

  verify_containerd_ns
}

# Read from the daemons, not `ctr namespaces ls`: containerd creates a namespace only when the
# first container starts in it, and userns-remap suffixes the name (osionos-ide-100000.100000).
verify_containerd_ns() {
  ns_fmt='{{.Containerd.Namespaces.Containers}}'
  ide_ns=$(ide info --format "$ns_fmt" 2>/dev/null || true)
  main_ns=$(docker info --format "$ns_fmt" 2>/dev/null || true)
  case "$ide_ns" in
    osionos-ide*)
      if [ "$ide_ns" != "$main_ns" ]; then
        pass "docker-ide containerd namespace $ide_ns is not the main daemon's ($main_ns)"
      else
        fail_ "docker-ide shares the main daemon's containerd namespace"
      fi
      ;;
    *) fail_ "docker-ide containerd namespace is '${ide_ns:-unknown}', not osionos-ide*" ;;
  esac
}

sock_inode() { stat -c %i "$SOCK_PATH" 2>/dev/null || true; }

# Why these three: the proxy bind-mounts this path, so a directory where a socket
# should be, or a mode other than the socket unit's, is what "someone made this
# file by hand" looks like — and the old unit made it by hand on every restart.
verify_socket_unit() {
  state=$(systemctl is-active docker-ide.socket 2>/dev/null || true)
  if [ "$state" = active ]; then
    pass "docker-ide.socket is active"
  else
    fail_ "docker-ide.socket is '${state:-unknown}', not active"
  fi

  if [ -S "$SOCK_PATH" ]; then
    pass "$SOCK_PATH is a socket"
  else
    fail_ "$SOCK_PATH is not a socket"
    return
  fi

  # One stat for mode, owner and group: any of the three off is the same failure.
  attrs=$(stat -c '%a %U %G' "$SOCK_PATH" 2>/dev/null || true)
  if [ "$attrs" = "660 root docker" ]; then
    pass "$SOCK_PATH is 660 root:docker"
  else
    fail_ "$SOCK_PATH is '${attrs:-unknown}', not 660 root:docker"
  fi
}

# The proxy bind-mounts this one inode, so a daemon restart that gives the socket
# a new inode leaves the proxy talking to a file nothing listens on.
verify_socket_outlives_restart() {
  inode_before=$(sock_inode)
  systemctl restart docker-ide.service
  wait_for_daemon "restart for the inode check"
  inode_after=$(sock_inode)
  if [ -n "$inode_before" ] && [ "$inode_before" = "$inode_after" ]; then
    pass "$SOCK_PATH keeps inode $inode_before across a daemon restart"
  else
    fail_ "$SOCK_PATH inode changed across a restart (${inode_before:-none} -> ${inode_after:-none})"
  fi

  if ide version >/dev/null 2>&1; then
    pass "ide version answers after the restart"
  else
    fail_ "ide version does not answer after the restart"
  fi
}

main "$@"
