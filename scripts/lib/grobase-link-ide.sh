#!/usr/bin/env bash
# ************************************************************************** #
#                                                                            #
#                                                        :::      ::::::::   #
#   grobase-link-ide.sh                                :+:      :+:    :+:   #
#                                                    +:+ +:+         +:+     #
#   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        #
#                                                +#+#+#+#+#+   +#+           #
#   Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#             #
#   Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr       #
#                                                                            #
# ************************************************************************** #

# grobase-link-ide.sh — the IDE plane relay behind `make link` in ssh mode, and in direct mode
# when GROBASE_IDE_SSH names an ssh alias (link_ide_direct).
# The VM runs the IDE plane as compose project osionos-ide-plane (another unit
# deploys it); this machine reaches its osionos-ide-server through one ssh
# forward to a unix socket, and the grobase-link-ide relay answers to that
# name only on osionos-ide-edge-net, never on grobase's network. Sourced by
# scripts/grobase-link.sh, which defines note, LINK_DIR, mux and forward
# before sourcing; define-only, sets no shell option. The pure parts (the
# endpoint filter, the forward-or-note decision, the socket check) are tested
# by scripts/tests/grobase-link-ide.bats with stubbed mux, forward and note.
#
# Ponytail: the forward points at the container IP, not the name; recreating
# the plane on the VM moves the address, and the IDE answers 502 until the
# next `make link` re-points it (the /healthz probe in verify shows it).

IDE_SOCK_DIR="$LINK_DIR/ide"
IDE_SOCK="$IDE_SOCK_DIR/ide-server-4100.sock"

# One of: ok <ip>, none, many <n>, unhealthy <status>, noip. Exactly one
# running osionos-ide-server container with a healthy status and an edge-net
# address forwards; anything else refuses with a reason, never an empty answer.
ide_plane_endpoint() {
  mux x 'sh -s' 2>/dev/null <<'EOF' | awk '
    NF == 0 { next }
    { n++; if (n == 1) { h = $1; ip = $2 } }
    END {
      if (n == 0) print "none";
      else if (n > 1) print "many " n;
      else if (h == "") print "unhealthy unknown";
      else if (h != "healthy") print "unhealthy " h;
      else if (ip == "" || ip == "-" || ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print "noip";
      else print "ok " ip
    }' || true
docker ps -q --filter label=com.docker.compose.project=osionos-ide-plane --filter label=com.docker.compose.service=osionos-ide-server | xargs -r docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' | awk '{ h=$1; ip="-"; for (i=2; i<=NF; i++) { p=index($i, "="); if (p > 0 && substr($i, 1, p-1) ~ /_osionos-ide-edge-net$/) { ip=substr($i, p+1); break } } if (ip == "") ip="-"; print h, ip }'
EOF
}

# Point the socket at the plane, or remove it with a note naming the reason.
# The IDE stays optional: every refusal still returns 0 so the link succeeds.
link_ide_plane() {
  local res ip status n
  mkdir -p "$IDE_SOCK_DIR" && chmod 700 "$IDE_SOCK_DIR"
  res=$(ide_plane_endpoint 2>/dev/null || true)
  [ -n "$res" ] || res="none"
  case "$res" in
  ok\ *)
    ip=${res#ok }
    forward "$IDE_SOCK" "$ip:4100"
    note "IDE plane relayed: osionos-ide-server -> $ip:4100"
    ;;
  many\ *)
    n=${res#many }
    rm -f "$IDE_SOCK"
    note "$n IDE planes running; refusing to pick one"
    ;;
  unhealthy\ *)
    status=${res#unhealthy }
    rm -f "$IDE_SOCK"
    note "IDE plane is not healthy ($status); the IDE stays unavailable"
    ;;
  noip)
    rm -f "$IDE_SOCK"
    note "IDE plane has no address on the edge network; the IDE stays unavailable"
    ;;
  *)
    rm -f "$IDE_SOCK"
    note "no IDE plane on the target; the IDE stays unavailable"
    ;;
  esac
  return 0
}

# Direct mode only: GROBASE_IDE_SSH=<alias> opens an ssh master used for the IDE plane
# socket and nothing else (no BaaS route goes over it). Fail-soft in every branch: an
# alias that could be read as an ssh option, a master that will not open, or a refused
# forward is a note, and the link already written stays. Each step runs in a subshell
# because open_master and forward die.
# Caveat: the alias check is syntactic; a well-formed alias that ssh cannot resolve is
# found only when the master fails to open.
link_ide_direct() {
  local alias=${1:-}
  [ -n "$alias" ] || return 0
  if ! [[ $alias =~ ^[A-Za-z0-9][A-Za-z0-9._@:-]*$ ]]; then
    note "GROBASE_IDE_SSH is not a plain ssh alias or user@host; the IDE plane stays unlinked"
    return 0
  fi
  if ! (open_master "$alias"); then
    note "no ssh master to $alias; the IDE plane stays unlinked (the BaaS link is unaffected)"
    return 0
  fi
  (link_ide_plane) || note "the IDE plane forward through $alias failed; the IDE stays unavailable"
  return 0
}

ide_linked() {
  [ -S "$IDE_SOCK" ]
}
