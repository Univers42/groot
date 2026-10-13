#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    ide-egress-nat.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/07/20 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/07/20 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Host rules that confine the isolated docker-ide daemon's address pool. That daemon runs
# --iptables=false, so nothing else filters its traffic; every rule here names the pool
# 10.202.0.0/16, so the main daemon's containers (172.x) and mini-baas are never matched.
#
# Three places, because one is not enough on this host (measured 2026-10-13):
#   - filter: own chain OSIO-IDE, reached from DOCKER-USER. The main dockerd re-inserts its
#     jumps at the top of FORWARD on every restart, so a rule inserted there does not stay
#     first; DOCKER-USER is the chain Docker evaluates first and never flushes. The pool may
#     leave by the uplink only, never toward RFC1918 / loopback / link-local / CGNAT (tailnet).
#   - raw PREROUTING: the host itself (bridge gateway, LAN and tailnet addresses) is INPUT,
#     which no FORWARD rule sees. raw runs before conntrack and NAT, so this also covers a
#     DNAT to a published host port.
#   - bridge family nft table: br_netfilter is not loaded, so frames between two boxes on the
#     shared sandbox bridge never reach iptables. On that bridge a box may talk to the egress
#     proxy's port and nothing else; ARP passes so the proxy stays resolvable.
# IPv6: net.ipv6.conf.all.forwarding=0 and the docker-ide networks are IPv4-only, so the pool
# has no IPv6 path and nothing is added for it.
#
# Usage (operator, sudo):  sh ide-egress-nat.sh up | down | check     (print: no root needed)
# Idempotent. install-egress-nat.sh copies this file alone to /usr/local/sbin and re-runs
# `up` on boot, so it cannot source a sibling file: the numbers below are duplicated.

set -eu

# Keep in step with bootstrap.sh
POOL="10.202.0.0/16"
SANDBOX_SUBNET="10.202.0.0/24"
# shellcheck disable=SC2034 # used by bootstrap.sh; kept here so the two lists diff cleanly
SANDBOX_GATEWAY="10.202.0.1"
EGRESS_IP="10.202.0.2"
EGRESS_PORT="8080"
SANDBOX_BRIDGE="osio-ide-sbx"
# shellcheck disable=SC2034 # used by bootstrap.sh
EGRESS_SUBNET="10.202.1.0/24"
# shellcheck disable=SC2034 # used by bootstrap.sh
EGRESS_BRIDGE="osio-ide-egr"

UPLINK="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
[ -n "${UPLINK}" ] || { echo "cannot detect uplink interface" >&2; exit 1; }

# The private + special ranges the pool must never reach.
BLOCK="169.254.0.0/16 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10"

# ensure_first TABLE CHAIN RULE...: insert the rule at the top unless it is already there.
ensure_first() {
  table="$1"; chain="$2"; shift 2
  iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -I "$chain" 1 "$@"
}
# del TABLE CHAIN RULE...: delete the rule if present.
del() {
  table="$1"; chain="$2"; shift 2
  iptables -t "$table" -D "$chain" "$@" 2>/dev/null || true
}

# The first two rules matter only if br_netfilter is ever loaded: bridged frames between a
# box and the egress proxy would then enter FORWARD and hit the 10.0.0.0/8 DROP.
filter_rules() {
  printf '*filter\n:OSIO-IDE - [0:0]\n'
  printf -- '-A OSIO-IDE -s %s -d %s/32 -p tcp --dport %s -j ACCEPT\n' "$SANDBOX_SUBNET" "$EGRESS_IP" "$EGRESS_PORT"
  printf -- '-A OSIO-IDE -s %s/32 -d %s -p tcp --sport %s -j ACCEPT\n' "$EGRESS_IP" "$SANDBOX_SUBNET" "$EGRESS_PORT"
  for cidr in $BLOCK; do
    printf -- '-A OSIO-IDE -s %s -d %s -j DROP\n' "$POOL" "$cidr"
  done
  printf -- '-A OSIO-IDE -s %s -o %s -j ACCEPT\n' "$POOL" "$UPLINK"
  printf -- '-A OSIO-IDE -d %s -i %s -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n' "$POOL" "$UPLINK"
  printf -- '-A OSIO-IDE -j DROP\nCOMMIT\n'
}

# `table` then `delete table` then the definition: nft applies the file as one transaction,
# so the table is replaced whole whether or not it existed.
bridge_rules() {
  cat <<EOF_BRIDGE
table bridge osio_ide
delete table bridge osio_ide
table bridge osio_ide {
  chain forward {
    type filter hook forward priority 0; policy accept;
    meta ibrname != "${SANDBOX_BRIDGE}" accept
    ether type arp accept
    ip daddr ${EGRESS_IP} tcp dport ${EGRESS_PORT} accept
    ip saddr ${EGRESS_IP} tcp sport ${EGRESS_PORT} accept
    drop
  }
}
EOF_BRIDGE
}

# What the previous version of this script put straight into FORWARD.
remove_legacy() {
  for cidr in $BLOCK; do del filter FORWARD -s "$POOL" -d "$cidr" -j DROP; done
  del filter FORWARD -s "$POOL" -o "$UPLINK" -j ACCEPT
  del filter FORWARD -d "$POOL" -i "$UPLINK" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

up() {
  command -v nft >/dev/null 2>&1 || { echo "nft is required (box-to-box isolation)" >&2; exit 1; }
  command -v iptables-restore >/dev/null 2>&1 || { echo "iptables-restore is required" >&2; exit 1; }
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  filter_rules | iptables-restore --noflush
  iptables -N DOCKER-USER 2>/dev/null || true
  ensure_first filter FORWARD -j DOCKER-USER
  ensure_first filter DOCKER-USER -s "$POOL" -j OSIO-IDE
  ensure_first filter DOCKER-USER -d "$POOL" -j OSIO-IDE
  ensure_first raw PREROUTING -s "$POOL" -m addrtype --dst-type LOCAL -j DROP
  iptables -t nat -C POSTROUTING -s "$POOL" ! -d "$POOL" -o "$UPLINK" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$POOL" ! -d "$POOL" -o "$UPLINK" -j MASQUERADE
  bridge_rules | nft -f -
  # Last, so the old rules keep filtering until the new ones are in place.
  remove_legacy
  echo "[ide-egress-nat] up: pool $POOL via $UPLINK (DOCKER-USER/OSIO-IDE, raw LOCAL drop, bridge $SANDBOX_BRIDGE isolated)"
}

# Never touches DOCKER-USER's other rules or the FORWARD -j DOCKER-USER jump.
down() {
  del filter DOCKER-USER -s "$POOL" -j OSIO-IDE
  del filter DOCKER-USER -d "$POOL" -j OSIO-IDE
  iptables -F OSIO-IDE 2>/dev/null || true
  iptables -X OSIO-IDE 2>/dev/null || true
  del raw PREROUTING -s "$POOL" -m addrtype --dst-type LOCAL -j DROP
  del nat POSTROUTING -s "$POOL" ! -d "$POOL" -o "$UPLINK" -j MASQUERADE
  nft delete table bridge osio_ide 2>/dev/null || true
  remove_legacy
  echo "[ide-egress-nat] down"
}

CHECK_FAILED=0
probe() {
  what="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$what"; else printf 'FAIL %s\n' "$what"; CHECK_FAILED=1; fi
}
bridge_isolated() {
  nft list table bridge osio_ide 2>/dev/null | grep -q "ibrname != \"$SANDBOX_BRIDGE\""
}

check() {
  probe "OSIO-IDE box -> egress proxy" iptables -C OSIO-IDE -s "$SANDBOX_SUBNET" -d "$EGRESS_IP/32" -p tcp --dport "$EGRESS_PORT" -j ACCEPT
  probe "OSIO-IDE egress proxy -> box" iptables -C OSIO-IDE -s "$EGRESS_IP/32" -d "$SANDBOX_SUBNET" -p tcp --sport "$EGRESS_PORT" -j ACCEPT
  for cidr in $BLOCK; do
    probe "OSIO-IDE drops pool -> $cidr" iptables -C OSIO-IDE -s "$POOL" -d "$cidr" -j DROP
  done
  probe "OSIO-IDE pool out $UPLINK" iptables -C OSIO-IDE -s "$POOL" -o "$UPLINK" -j ACCEPT
  probe "OSIO-IDE established back in" iptables -C OSIO-IDE -d "$POOL" -i "$UPLINK" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  probe "OSIO-IDE final DROP" iptables -C OSIO-IDE -j DROP
  probe "FORWARD -> DOCKER-USER" iptables -C FORWARD -j DOCKER-USER
  probe "DOCKER-USER -s pool -> OSIO-IDE" iptables -C DOCKER-USER -s "$POOL" -j OSIO-IDE
  probe "DOCKER-USER -d pool -> OSIO-IDE" iptables -C DOCKER-USER -d "$POOL" -j OSIO-IDE
  probe "raw drops pool -> host addresses" iptables -t raw -C PREROUTING -s "$POOL" -m addrtype --dst-type LOCAL -j DROP
  probe "nat MASQUERADE pool out $UPLINK" iptables -t nat -C POSTROUTING -s "$POOL" ! -d "$POOL" -o "$UPLINK" -j MASQUERADE
  probe "bridge $SANDBOX_BRIDGE isolated" bridge_isolated
  [ "$CHECK_FAILED" -eq 0 ] || exit 1
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  print) filter_rules; bridge_rules ;;
  check) check ;;
  *) echo "usage: $0 up|down|print|check" >&2; exit 2 ;;
esac
