#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    bootstrap.sh                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/07/19 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/07/20 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# One-time PRIVILEGED setup of the IDE sandbox plane on the ISOLATED docker-ide
# daemon — run by an operator (sudo: /run/docker-ide.sock is root-owned), NEVER
# on the per-request path (that keeps the runtime provisioner unable to touch
# /images — devil condition 8). It seeds the sandbox + egress images INTO
# docker-ide and stands up the internal sandbox network + its egress proxy.
#
# Talks to docker-ide's OWN socket directly (not the filtered runtime proxy).
#
# Usage:  sudo sh infrastructure/docker/osionos/ide-sandbox/bootstrap.sh
# Pre:    docker-ide.service running; the two images built on the MAIN daemon;
#         ide-egress-nat.sh up  (for the egress proxy's outbound NAT).

set -eu

IDE_SOCK="${OSIONOS_IDE_DOCKER_SOCK:-/run/docker-ide.sock}"
IDE="docker -H unix://${IDE_SOCK}"
SANDBOX_IMAGE="${OSIONOS_IDE_SANDBOX_IMAGE:-osionos-ide-sandbox:latest}"
EGRESS_IMAGE="${OSIONOS_IDE_EGRESS_IMAGE:-osionos-ide-egress:latest}"
SANDBOX_NET="osio-ide-sandbox-net"
EGRESS_NET="osio-ide-egress-net"
GIT_HOSTS="${OSIONOS_IDE_EGRESS_GIT_HOSTS:-github.com}"

log() { printf '[ide-bootstrap] %s\n' "$1"; }

# 1. Reachable?
$IDE info >/dev/null 2>&1 || { log "docker-ide daemon not reachable at ${IDE_SOCK} — is docker-ide.service up?"; exit 1; }

# 2. Seed the two images: build on the MAIN daemon, pipe into docker-ide. The
#    ONLY image transfer; the runtime path never loads images.
log "seeding images into docker-ide…"
docker save "$SANDBOX_IMAGE" | $IDE load
docker save "$EGRESS_IMAGE" | $IDE load

# 3. Networks — sandbox-net is `--internal` (sandboxes get NO off-box route,
#    only the egress proxy on the same net); egress-net is egress-capable (the
#    NAT script MASQUERADEs the 10.202 pool it draws from).
log "creating networks…"
$IDE network inspect "$SANDBOX_NET" >/dev/null 2>&1 || $IDE network create --internal "$SANDBOX_NET"
$IDE network inspect "$EGRESS_NET"  >/dev/null 2>&1 || $IDE network create "$EGRESS_NET"

# 4. The egress proxy — dual-homed: sandbox-net (as `ide-egress`, the sole egress
#    path) + egress-net (real egress via the host NAT). Hardened like a sandbox.
log "starting the egress proxy…"
$IDE rm -f ide-egress >/dev/null 2>&1 || true
$IDE run -d --name ide-egress \
  --network "$SANDBOX_NET" --network-alias ide-egress \
  --cap-drop ALL --security-opt no-new-privileges:true --read-only \
  --restart unless-stopped \
  -e "IDE_EGRESS_GIT_HOSTS=$GIT_HOSTS" \
  "$EGRESS_IMAGE"
$IDE network connect "$EGRESS_NET" ide-egress

log "done. sandboxes create on $SANDBOX_NET; egress via ide-egress:8080."
