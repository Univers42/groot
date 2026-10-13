#!/bin/sh
# ************************************************************************** #
#                                                                            #
#                                                        :::      ::::::::   #
#   ship-images.sh                                     :+:      :+:    :+:   #
#                                                    +:+ +:+         +:+     #
#   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        #
#                                                +#+#+#+#+#+   +#+           #
#   Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#             #
#   Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr       #
#                                                                            #
# ************************************************************************** #

# Streams the sandbox + egress images from the BUILD machine's main daemon into
# the VM's docker-ide daemon (docker save | ssh … load), checks the content
# landed intact, and prints the ids docker-ide reports — the pins the operator
# copies into the env files. The operator builds the images first (README,
# Activation step 1); this script builds nothing, edits no file on either side,
# and never touches the remote MAIN daemon — only its docker-ide socket, via ssh.
#
# Usage:  IDE_SHIP_HOST=<vm> sh infrastructure/docker/osionos/ide-sandbox/ship-images.sh
# Pre:    the two images built on the local (main) daemon; the ssh alias of the
#         VM given by the operator (no default); the VM user in the `docker`
#         group (docker-ide.service runs --group=docker).
#         OSIONOS_IDE_SANDBOX_IMAGE / OSIONOS_IDE_EGRESS_IMAGE may override the
#         image names (defaults as in bootstrap.sh).

set -eu

SHIP_HOST="${IDE_SHIP_HOST:-}"
SANDBOX_IMAGE="${OSIONOS_IDE_SANDBOX_IMAGE:-osionos-ide-sandbox:latest}"
EGRESS_IMAGE="${OSIONOS_IDE_EGRESS_IMAGE:-osionos-ide-egress:latest}"

# Refusals go to stderr: ship_one's stdout is captured for the id, so a log line
# there would vanish (and the operator must see why the ship stopped).
log() { printf '[ide-ship] %s\n' "$1" >&2; }

# ide CMD — run CMD against the VM's docker-ide. The remote shell reads it from stdin
# and re-splits it, so CMD carries its own quoting; ship_one vets image refs first.
# Ponytail: 60 s per inspect; a VM under heavy load can answer later, and the ship
# then stops (fails closed) though the image landed — re-run it.
ide() { printf 'docker -H unix:///run/docker-ide.sock %s\n' "$1" | timeout 60 ssh "$SHIP_HOST" sh -s; }

# ship_one IMG — save IMG, stream it into docker-ide over ssh, verify the layers
# landed intact, and print the id docker-ide reports. Every failure exits
# non-zero naming IMG: a half-shipped image must never read as a success.
ship_one() {
  img="$1"
  case "$img" in
    '' | *[!A-Za-z0-9._/:@-]*) log "refusing image reference '$img': only [A-Za-z0-9._/:@-] can cross ssh unquoted"; exit 1 ;;
  esac
  docker image inspect "$img" >/dev/null 2>&1 || {
    log "$img is not on the local daemon — build it first: docker build -t $img <context> (README, Activation step 1)"
    exit 1
  }
  # Ponytail: 1800 s assumes a fast link — a slow one needs a larger bound (the
  #          load then fails closed at the cap instead of completing).
  # docker load prints "Loaded image: …" on stdout, which is the id channel here.
  timeout 1800 docker save "$img" | timeout 1800 ssh "$SHIP_HOST" "docker -H unix:///run/docker-ide.sock load" >&2 || {
    log "the docker-ide load of $img failed — the remote error is above"
    exit 1
  }
  local_layers="$(docker image inspect -f '{{json .RootFS.Layers}}' "$img")"
  remote_layers="$(ide "image inspect -f '{{json .RootFS.Layers}}' $img")"
  [ "$local_layers" = "$remote_layers" ] || {
    log "$img: the RootFS layers docker-ide reports differ from the local ones — rebuild it and re-ship"
    exit 1
  }
  ide "image inspect -f '{{.Id}}' $img"
}

[ -n "$SHIP_HOST" ] || {
  log "IDE_SHIP_HOST is not set — export the ssh alias of the VM running docker-ide (the operator provides it; there is no default)"
  exit 1
}

# Only one content can match these ids: bootstrap.sh, the bridge and the socket
# proxy all read the same variables (exact match).
sandbox_id="$(ship_one "$SANDBOX_IMAGE")"
egress_id="$(ship_one "$EGRESS_IMAGE")"

printf 'OSIONOS_IDE_SANDBOX_IMAGE=%s\n' "$sandbox_id"
printf 'OSIONOS_IDE_EGRESS_IMAGE=%s\n' "$egress_id"
