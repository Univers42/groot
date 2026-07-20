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

# Host egress rules for the isolated docker-ide daemon (which runs
# --iptables=false, so it touches NONE of the main daemon's DOCKER chains).
# Scoped ENTIRELY to docker-ide's address pool 10.202.0.0/16 — every rule
# matches `-s 10.202.0.0/16`, so the main daemon's containers (172.x) and
# mini-baas are never affected.
#
#   MASQUERADE the pool out the uplink  (the in-daemon egress proxy reaches
#   registries/git); DROP the pool -> RFC1918 / loopback / cloud-metadata FIRST
#   (defense-in-depth behind the proxy's own connect-time IP validation).
#
# Usage (operator, sudo):  sh ide-egress-nat.sh up   |   sh ide-egress-nat.sh down
# Idempotent. Re-run `up` after a reboot (or wire into docker-ide.service).

set -eu

POOL="10.202.0.0/16"
UPLINK="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
[ -n "${UPLINK}" ] || { echo "cannot detect uplink interface" >&2; exit 1; }

# The private + special ranges the sandbox egress must never reach.
BLOCK="169.254.0.0/16 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10"

add() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
ins() { iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
del() { iptables -D "$@" 2>/dev/null || true; }

up() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  # DROP pool -> private/metadata (inserted, so they precede the ACCEPT).
  for cidr in $BLOCK; do
    ins FORWARD -s "$POOL" -d "$cidr" -j DROP
  done
  # Allow the pool out the uplink + established return.
  add FORWARD -s "$POOL" -o "$UPLINK" -j ACCEPT
  add FORWARD -d "$POOL" -i "$UPLINK" -m state --state RELATED,ESTABLISHED -j ACCEPT
  add POSTROUTING -t nat -s "$POOL" ! -d "$POOL" -o "$UPLINK" -j MASQUERADE
  echo "[ide-egress-nat] up: pool $POOL via $UPLINK (private ranges dropped)"
}

down() {
  for cidr in $BLOCK; do del FORWARD -s "$POOL" -d "$cidr" -j DROP; done
  del FORWARD -s "$POOL" -o "$UPLINK" -j ACCEPT
  del FORWARD -d "$POOL" -i "$UPLINK" -m state --state RELATED,ESTABLISHED -j ACCEPT
  del POSTROUTING -t nat -s "$POOL" ! -d "$POOL" -o "$UPLINK" -j MASQUERADE
  echo "[ide-egress-nat] down"
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
