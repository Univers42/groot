#!/bin/sh
# ************************************************************************** #
#                                                                            #
#                                                        :::      ::::::::   #
#   deploy-plane.sh                                    :+:      :+:    :+:   #
#                                                    +:+ +:+         +:+     #
#   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        #
#                                                +#+#+#+#+#+   +#+           #
#   Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#             #
#   Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr       #
#                                                                            #
# ************************************************************************** #

# Deploys the IDE control plane (osionos-ide-socket-proxy + osionos-ide-server,
# profile `ide`) onto the VM's MAIN daemon, FROM this build machine over Docker's
# ssh transport — the same machine that built the images, so the VM never builds.
# It ships the bridge + socket-proxy images in (mirroring ship-images.sh's
# save|load discipline), proves they landed intact, then pins each VM container to
# the shipped image id (C1). It builds nothing, removes nothing, and touches no
# container outside project osionos-ide-plane. check-plane.sh then proves the
# placement (C1–C10). ship-images.sh seeds docker-ide instead; this script is
# about the plane's own daemon and runs after it.
#
# Usage:  IDE_SHIP_HOST=<vm> sh infrastructure/docker/osionos/ide-sandbox/deploy-plane.sh
# Pre:    the two images built on this machine's main daemon; the VM reachable by
#         the ssh alias; the env file carrying OSIONOS_IDE_TOKEN_SECRET and the
#         OSIONOS_IDE_SANDBOX_IMAGE pin ship-images.sh printed. Never run as root.

set -eu

HOST="${IDE_SHIP_HOST:-}"
ENV_FILE="${OSIONOS_IDE_ENV_FILE:-./.env.local}"
PROXY_IMAGE="${OSIONOS_IDE_SOCKET_PROXY_IMAGE:-osionos-ide-socket-proxy:latest}"
BRIDGE_IMAGE="${OSIONOS_BRIDGE_IMAGE:-track-binocle/osionos-bridge:local}"

log() { printf '[ide-deploy] %s\n' "$1" >&2; }

# An image's .Id is not portable: the classic store reports the config digest, the
# containerd store (the VM, Docker 29.9) the manifest digest, so the same image has two
# ids. Its config plus its layer list is the same on both and is what is compared.
# Ponytail: build history and timestamps are left out, so two builds with identical
# config and layers count as one image; a docker that renders .Config differently
# reads as a mismatch, which only costs a re-ship.
FINGERPRINT='{{json .Config}} {{json .RootFS.Layers}}'

# vm CMD — run CMD on the VM's MAIN daemon over ssh. The remote shell reads it
# from stdin and re-splits it, so CMD carries its own quoting; ship_one vets the
# image refs first.
# Ponytail: 60 s per inspect; a VM under heavy load can answer later, and the
# deploy then stops (fails closed) though the image landed — re-run it.
vm() { printf 'docker %s\n' "$1" | timeout 60 ssh "$HOST" sh -s; }

# ship_one IMG — save IMG locally, stream it to the VM's main daemon, prove the
# RootFS layers landed intact, and print the id the VM reports. Every failure
# exits 1 naming IMG: a half-shipped image must never read as a success.
ship_one() {
  img="$1"
  case "$img" in
    '' | *[!A-Za-z0-9._/:@-]*) log "refusing image reference '$img': only [A-Za-z0-9._/:@-] can cross ssh unquoted"; exit 1 ;;
  esac
  local_fp="$(docker image inspect -f "$FINGERPRINT" "$img" 2>/dev/null)" || {
    log "$img is not on the local (build) daemon — build it first: docker build -t $img <context>"
    exit 1
  }
  remote_fp="$(vm "image inspect -f '$FINGERPRINT' $img" 2>/dev/null)" || remote_fp=''
  if [ "$remote_fp" = "$local_fp" ]; then
    log "$img: the VM already holds the same config and layers — not shipped again"
    vm "image inspect -f '{{.Id}}' $img"
    return
  fi
  # Ponytail: 1800 s assumes a fast link — a slow one fails closed at the cap.
  # docker load prints "Loaded image: …" on stdout, which the pipe would swallow;
  # redirect it to stderr so ship_one's stdout stays the clean id channel.
  timeout 1800 docker save "$img" | timeout 1800 ssh "$HOST" "docker load" >&2 || {
    log "the VM load of $img failed — the remote error is above"
    exit 1
  }
  remote_fp="$(vm "image inspect -f '$FINGERPRINT' $img")"
  [ "$remote_fp" = "$local_fp" ] || {
    log "$img: the config or RootFS layers the VM reports differ from the local ones — rebuild and re-run"
    exit 1
  }
  vm "image inspect -f '{{.Id}}' $img"
}

[ -n "$HOST" ] || {
  log "IDE_SHIP_HOST is not set — export the ssh alias of the VM (the operator provides it; there is no default)"
  exit 1
}
[ -r "$ENV_FILE" ] || {
  log "env file '$ENV_FILE' is not readable — set OSIONOS_IDE_ENV_FILE to the operator's IDE env"
  exit 1
}

# The token secret is read only to confirm the env file carries one; its value is
# never printed. It reaches the VM as container environment through the compose
# --env-file below, never as a file this script writes (C2 lives in check-plane).
token="$(sed -n 's/^OSIONOS_IDE_TOKEN_SECRET=//p' "$ENV_FILE")"
[ -n "$token" ] || {
  log "$ENV_FILE carries no OSIONOS_IDE_TOKEN_SECRET — the ide-server refuses to boot without it"
  exit 1
}
unset token

# ship-images.sh pins the sandbox image to the sha256 id docker-ide reported; the
# plane must run exactly that shipped image, so the env file has to carry the pin.
pin="$(sed -n 's/^OSIONOS_IDE_SANDBOX_IMAGE=//p' "$ENV_FILE")"
printf '%s\n' "$pin" | grep -Eq '^sha256:[0-9a-f]{64}$' || {
  log "$ENV_FILE: OSIONOS_IDE_SANDBOX_IMAGE is not a sha256:<64 hex> pin — run ship-images.sh and copy the id it prints"
  exit 1
}
unset pin

# The socket proxy joins the group that owns /run/docker-ide.sock (compose group_add);
# docker-ide.socket sets that group on the VM, so it is read there, never assumed. Root
# (0) or no answer means the socket unit is not installed as install-docker-ide.sh does it.
gid="$(timeout 30 ssh "$HOST" 'stat -c %g /run/docker-ide.sock')" || gid=''
case "$gid" in
  '' | 0 | *[!0-9]*)
    log "no non-root numeric group owns /run/docker-ide.sock on $HOST — run install-docker-ide.sh there first"
    exit 1
    ;;
esac

proxy_id="$(ship_one "$PROXY_IMAGE")"
bridge_id="$(ship_one "$BRIDGE_IMAGE")"

# Bring the profile up on the VM's MAIN daemon over the ssh transport, never
# building or pulling (the VM never builds): the two image variables are pinned to
# the shipped ids in the shell environment, which overrides the env file for
# interpolation only. --wait blocks until the ide-server healthcheck turns green.
# Ponytail: 600 s bounds up+healthcheck; a cold VM needing longer fails closed
# here (nothing is torn down — re-run to resume) instead of hanging forever.
OSIONOS_IDE_SOCKET_PROXY_IMAGE="$proxy_id" \
OSIONOS_BRIDGE_IMAGE="$bridge_id" \
OSIONOS_IDE_DOCKER_GID="$gid" \
DOCKER_HOST="ssh://$HOST" timeout 600 docker compose \
  -p osionos-ide-plane --env-file "$ENV_FILE" -f docker-compose.yml --profile ide \
  up -d --no-build --pull never --wait osionos-ide-socket-proxy osionos-ide-server

printf 'deployed: socket-proxy %s ide-server %s\n' "$proxy_id" "$bridge_id"
