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
SOCK_URL=unix:///run/docker-ide.sock
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
  install -o root -g root -m 0644 "$srcdir/osionos-ide.slice" "$UNIT_DIR/osionos-ide.slice"
  install -d -m 0755 "$CONF_DIR"
  install -o root -g root -m 0644 "$srcdir/docker-ide.daemon.json" "$CONF_DIR/daemon.json"
}

bring_up_daemon() {
  systemctl daemon-reload
  systemctl enable --now docker-ide
  wait_for_daemon "enable --now"
  # The restart re-reads the new unit — slice, containerd namespaces, own
  # config file — so the final state is proven, not just the first start.
  systemctl restart docker-ide
  wait_for_daemon "restart"
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

  # Read from the daemons, not `ctr namespaces ls`: containerd creates a namespace only when the
  # first container starts in it, and userns-remap suffixes the name (osionos-ide-100000.100000).
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

main "$@"
