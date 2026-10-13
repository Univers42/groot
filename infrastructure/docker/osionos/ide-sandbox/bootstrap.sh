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
# Pre:    docker-ide.service running; the two images either shipped into docker-ide
#         ahead of time (ship-images.sh — OSIONOS_IDE_SANDBOX_IMAGE /
#         OSIONOS_IDE_EGRESS_IMAGE then hold the pinned sha256: ids it printed) or
#         built on the MAIN daemon (README, Activation step 1).
#         ide-egress-nat.sh up may run before or after this script (its iptables rules
#         match addresses), but its bridge table filters only once osio-ide-sbx exists:
#         on a fresh host run this script first, then `up`.

set -eu

IDE_SOCK="${OSIONOS_IDE_DOCKER_SOCK:-/run/docker-ide.sock}"
IDE="docker -H unix://${IDE_SOCK}"
SANDBOX_IMAGE="${OSIONOS_IDE_SANDBOX_IMAGE:-osionos-ide-sandbox:latest}"
EGRESS_IMAGE="${OSIONOS_IDE_EGRESS_IMAGE:-osionos-ide-egress:latest}"
SANDBOX_NET="osio-ide-sandbox-net"
EGRESS_NET="osio-ide-egress-net"
GIT_HOSTS="${OSIONOS_IDE_EGRESS_GIT_HOSTS:-github.com}"

# Keep in step with ide-egress-nat.sh
# shellcheck disable=SC2034 # used by ide-egress-nat.sh; kept here so the two lists diff cleanly
POOL="10.202.0.0/16"
SANDBOX_SUBNET="10.202.0.0/24"
SANDBOX_GATEWAY="10.202.0.1"
EGRESS_IP="10.202.0.2"
EGRESS_PORT="8080"
SANDBOX_BRIDGE="osio-ide-sbx"
EGRESS_SUBNET="10.202.1.0/24"
EGRESS_BRIDGE="osio-ide-egr"

log() { printf '[ide-bootstrap] %s\n' "$1"; }

# ensure_network NAME SUBNET BRIDGE [create flags...]: the host rules name the bridge and
# the subnet, so a network created by an older bootstrap (docker-chosen bridge and subnet)
# would run unfiltered. It is never removed here: boxes may be attached to it.
ensure_network() {
  name="$1"; subnet="$2"; bridge="$3"; shift 3
  if $IDE network inspect "$name" >/dev/null 2>&1; then
    have_bridge="$($IDE network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$name")"
    have_subnet="$($IDE network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$name")"
    if [ "$have_bridge" != "$bridge" ] || [ "$have_subnet" != "$subnet" ]; then
      log "$name exists with another bridge/subnet; remove it while no sandbox runs, then re-run"
      exit 1
    fi
    return 0
  fi
  $IDE network create "$@" --subnet "$subnet" -o "com.docker.network.bridge.name=$bridge" "$name"
}

# 1. Reachable?
$IDE info >/dev/null 2>&1 || { log "docker-ide daemon not reachable at ${IDE_SOCK} — is docker-ide.service up?"; exit 1; }

# 2. Seed the two images into docker-ide. Two ways in: the operator ships them
#    from the build machine with ship-images.sh (the variables then hold the
#    pinned ids docker-ide reported), or — backward compatible — they are built
#    on the MAIN daemon and piped in here. The ONLY image transfer; the runtime
#    path never loads images. A pinned id that docker-ide lacks cannot be
#    `docker save`d from the main daemon (an id only docker-ide knows): refuse
#    and name ship-images.sh.
missing_from_ide=0
loaded_from_main=0
for img in "$SANDBOX_IMAGE" "$EGRESS_IMAGE"; do
  $IDE image inspect "$img" >/dev/null 2>&1 && continue
  missing_from_ide=1
  case "$img" in
    sha256:*)
      log "$img is a pinned id that docker-ide lacks — ship it first: IDE_SHIP_HOST=${IDE_SHIP_HOST:-<this vm>} sh infrastructure/docker/osionos/ide-sandbox/ship-images.sh"
      exit 1
      ;;
  esac
done
if [ "$missing_from_ide" = 0 ]; then
  log "images already in docker-ide (shipped); not loading from the main daemon"
else
  for img in "$SANDBOX_IMAGE" "$EGRESS_IMAGE"; do
    docker image inspect "$img" >/dev/null 2>&1 || {
      log "$img is not on the main daemon — build it first: docker build -t $img <context> (README, Activation step 1)"
      exit 1
    }
  done
  log "seeding images into docker-ide…"
  docker save "$SANDBOX_IMAGE" | $IDE load
  docker save "$EGRESS_IMAGE" | $IDE load
  loaded_from_main=1
fi

# 3. Networks — sandbox-net is `--internal` (sandboxes get NO off-box route,
#    only the egress proxy on the same net); egress-net is egress-capable (the
#    NAT script MASQUERADEs the 10.202 pool it draws from).
log "creating networks…"
ensure_network "$SANDBOX_NET" "$SANDBOX_SUBNET" "$SANDBOX_BRIDGE" --internal --gateway "$SANDBOX_GATEWAY"
ensure_network "$EGRESS_NET" "$EGRESS_SUBNET" "$EGRESS_BRIDGE"

# 4. The egress proxy — dual-homed: sandbox-net (as `ide-egress`, the sole egress
#    path) + egress-net (real egress via the host NAT). Hardened like a sandbox. Its fixed
#    address is the one the host bridge table lets every box reach.
# Ponytail: public resolvers because the host's are tailnet/LAN addresses the egress rules
#    drop; a site that blocks them needs its own resolver here.
log "starting the egress proxy…"
$IDE rm -f ide-egress >/dev/null 2>&1 || true
$IDE run -d --name ide-egress \
  --network "$SANDBOX_NET" --network-alias ide-egress --ip "$EGRESS_IP" \
  --dns 1.1.1.1 --dns 9.9.9.9 \
  --cap-drop ALL --security-opt no-new-privileges:true --read-only \
  --restart unless-stopped \
  -e "IDE_EGRESS_GIT_HOSTS=$GIT_HOSTS" \
  "$EGRESS_IMAGE"
$IDE network connect "$EGRESS_NET" ide-egress

# 5. Only docker-ide runs the sandbox image, so the main daemon's copy (~2.8 GB, the
#    largest image on the machine) goes once docker-ide confirms it has it; the build
#    cache keeps a rebuild quick. Cleanup only: a refusal is reported, never fatal.
#    `sudo OSIONOS_IDE_KEEP_MAIN_COPY=1 sh bootstrap.sh` keeps it. The egress image
#    stays: verify.sh runs its selfcheck on the main daemon. Only when step 2
#    loaded the images from the main daemon — a shipped image was never there.
if [ "$loaded_from_main" = 1 ] && [ "${OSIONOS_IDE_KEEP_MAIN_COPY:-0}" != 1 ]; then
  if $IDE image inspect "$SANDBOX_IMAGE" >/dev/null 2>&1 && docker image rm "$SANDBOX_IMAGE" >/dev/null; then
    log "removed the main daemon's copy of $SANDBOX_IMAGE (docker-ide has it)"
  else
    log "kept the main daemon's copy of $SANDBOX_IMAGE — remove it later with: docker image rm $SANDBOX_IMAGE"
  fi
fi

log "done. sandboxes create on $SANDBOX_NET; egress via ide-egress:$EGRESS_PORT."
