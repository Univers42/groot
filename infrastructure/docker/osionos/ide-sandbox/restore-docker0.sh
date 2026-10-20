#!/bin/sh
# Put the MAIN daemon's docker0 back after docker-ide started (its ExecStartPost).
#
# A dockerd started with --bridge=none deletes any interface named docker0 on start, and the
# two daemons share the host's network namespace: on baas (2026-10-20) docker0 went at
# 12:29:54, one second before docker-ide was active. The main daemon never recreates it, so a
# container on its default bridge kept running, reported healthy by its in-container check,
# while its published port reset every connection; any later `docker run` on the default
# network failed to attach. The address and subnet come from the main daemon's own record of
# that network, and the host-side veths left without a master are its containers' (every other
# veth hangs off a br-* of either daemon).
#
# Caveat: "a veth with no master" is the heuristic for "was on docker0". A veth some other tool
# created without a bridge would be attached too; on a docker-only host there is none.
set -eu

ip link show docker0 >/dev/null 2>&1 && exit 0
# The main daemon is not up yet (docker-ide started first at boot): it creates docker0 itself.
net=$(docker -H unix:///run/docker.sock network inspect bridge \
  -f '{{range .IPAM.Config}}{{.Gateway}} {{.Subnet}}{{end}}' 2>/dev/null) || exit 0
gateway=${net% *}
prefix=${net##*/}
[ -n "$gateway" ] && [ "$prefix" != "$net" ] || exit 0

ip link add docker0 type bridge
ip addr add "$gateway/$prefix" dev docker0
ip link set docker0 up
for veth in $(ip -o link show type veth | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }'); do
  ip -o link show "$veth" | grep -q ' master ' || ip link set "$veth" master docker0
done
echo "docker0 restored ($gateway/$prefix) for the main daemon"
