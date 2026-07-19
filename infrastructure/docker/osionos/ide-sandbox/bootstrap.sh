#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    bootstrap.sh                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/07/19 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/07/19 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# One-time PRIVILEGED setup of the IDE sandbox plane — run by an operator, NEVER
# on the per-request path (that keeps the runtime provisioner unable to touch
# /images or networks — devil condition 8). It seeds the sandbox + egress images
# INTO the isolated dind daemon and stands up the internal sandbox network with
# its in-dind egress proxy. Uses host `docker exec` into the dind container, so
# it talks to dind's OWN daemon, never the filtered runtime socket-proxy.
#
# Usage:  sh infrastructure/docker/osionos/ide-sandbox/bootstrap.sh
# Pre:    COMPOSE_PROFILES=ide docker compose up -d osionos-ide-dockerd \
#           osionos-ide-socket-proxy   (and the two images built on the host)

set -eu

DIND="track-binocle-osionos-ide-dockerd"
SANDBOX_IMAGE="${OSIONOS_IDE_SANDBOX_IMAGE:-osionos-ide-sandbox:latest}"
EGRESS_IMAGE="${OSIONOS_IDE_EGRESS_IMAGE:-osionos-ide-egress:latest}"
SANDBOX_NET="osio-ide-sandbox-net"
GIT_HOSTS="${OSIONOS_IDE_EGRESS_GIT_HOSTS:-}"

log() { printf '[ide-bootstrap] %s\n' "$1"; }

# 1. Wait for the isolated daemon to accept commands.
log "waiting for the dind daemon…"
i=0
until docker exec "$DIND" docker info >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { log "dind never became ready"; exit 1; }
  sleep 1
done

# 2. Seed the two images into dind (host build → dind load). This is the ONLY
#    image transfer; the runtime path never loads images.
log "seeding images into the isolated daemon…"
docker save "$SANDBOX_IMAGE" | docker exec -i "$DIND" docker load
docker save "$EGRESS_IMAGE" | docker exec -i "$DIND" docker load

# 3. The internal sandbox network — `internal` = sandboxes get NO off-box route;
#    their only reachable peer is the egress proxy on this same net (condition 3).
log "creating the internal sandbox network…"
docker exec "$DIND" docker network inspect "$SANDBOX_NET" >/dev/null 2>&1 \
  || docker exec "$DIND" docker network create --internal "$SANDBOX_NET"

# 4. The egress proxy INSIDE dind — dual-homed: sandbox-net (as `ide-egress`,
#    the sole egress path) + the default net (real egress). Hardened like a
#    sandbox. Connect-time IP re-validation defeats DNS-rebind (condition 5).
log "starting the in-dind egress proxy…"
docker exec "$DIND" docker rm -f ide-egress >/dev/null 2>&1 || true
docker exec "$DIND" docker run -d --name ide-egress \
  --network "$SANDBOX_NET" --network-alias ide-egress \
  --cap-drop ALL --security-opt no-new-privileges:true --read-only \
  --restart unless-stopped \
  -e "IDE_EGRESS_GIT_HOSTS=$GIT_HOSTS" \
  "$EGRESS_IMAGE"
# Give the proxy a second NIC on the default (egress) net so it can reach out.
docker exec "$DIND" docker network connect bridge ide-egress

log "done. sandboxes create on $SANDBOX_NET; egress via ide-egress:8080."
