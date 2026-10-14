#!/bin/sh
# ************************************************************************** #
#                                                                            #
#                                                        :::      ::::::::   #
#   check-plane.sh                                     :+:      :+:    :+:   #
#                                                    +:+ +:+         +:+     #
#   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        #
#                                                +#+#+#+#+#+   +#+           #
#   Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#             #
#   Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr       #
#                                                                            #
# ************************************************************************** #
# Read-only placement proof of the IDE plane on the VM's main daemon, from the build
# machine: one ok|FAIL line per condition (C1,C2,C4,C6,C7,C8,C10,C21), then a RESULT tally.
# Never writes the VM, never prints a secret; an undecidable check fails with a reason.
set -eu
HOST="${IDE_SHIP_HOST:-}"
ENV_FILE="${OSIONOS_IDE_ENV_FILE:-}"
PROXY_IMAGE="${OSIONOS_IDE_SOCKET_PROXY_IMAGE:-osionos-ide-socket-proxy:latest}"
BRIDGE_IMAGE="${OSIONOS_BRIDGE_IMAGE:-track-binocle/osionos-bridge:local}"
PROJECT=osionos-ide-plane
CTRL_NET="${PROJECT}_osionos-ide-control-net"
EDGE_NET="${PROJECT}_osionos-ide-edge-net"
okn=0 failed=0
[ -n "$HOST" ] || { printf 'FAIL IDE_SHIP_HOST is not set - nothing to check\n'; exit 1; }
# d: a VM main-daemon call over ssh; remote: a command on the VM host. Ponytail: 60 s
# per probe - a loaded VM answers late and reads unreachable, failing safe not false.
d() { DOCKER_HOST="ssh://$HOST" timeout 60 docker "$@"; }
remote() { timeout 60 ssh "$HOST" "$1"; }
ok() { printf 'ok %s\n' "$1"; okn=$((okn + 1)); }
bad() { printf 'FAIL %s\n' "$1"; failed=$((failed + 1)); }

# one IDS - ONE_ID=IDS only for exactly one line, else ONE_REASON=the count (never
# guess which container was meant; an unpickable one makes the check fail closed).
one() {
  ONE_ID='' ONE_REASON=''
  case "$1" in
    '') ONE_REASON='count=0' ;;
    *[[:space:]]*) ONE_REASON='count>1' ;;
    *) ONE_ID="$1" ;;
  esac
}
find_plane() {
  pids="$(d ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=osionos-ide-socket-proxy")"
  sids="$(d ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=osionos-ide-server")"
  one "$pids"; proxy_cid="$ONE_ID"; proxy_reason="$ONE_REASON"
  one "$sids"; server_cid="$ONE_ID"; server_reason="$ONE_REASON"
}
# subnet_ok CIDR - 0 when the IPv4 subnet is RFC1918 (10/8, 172.16/12, 192.168/16) and
# NOT 10.202.0.0/16 (the docker-ide pool); 1 otherwise. Ponytail: reads only the first two
# dotted octets and fails closed otherwise - no prefix-length check, a host subnet passes.
subnet_ok() {
  case "$1" in */*) ;; *) return 1 ;; esac
  ip="${1%%/*}"
  case "$ip" in '' | *[!0-9.]*) return 1 ;; esac
  o1="${ip%%.*}"; rest="${ip#*.}"; o2="${rest%%.*}"
  case "$o1" in
    10) [ "$o2" = 202 ] && return 1; return 0 ;;
    172) [ "$o2" -ge 16 ] && [ "$o2" -le 31 ] && return 0; return 1 ;;
    192) [ "$o2" = 168 ] && return 0; return 1 ;;
    *) return 1 ;;
  esac
}
# host_probe IP PORT - 0 when the VM host itself can open TCP to IP:PORT (the C6
# positive control): nc -z -w 3 if present, else bash's /dev/tcp.
host_probe() {
  if remote 'command -v nc >/dev/null 2>&1'; then
    remote "nc -z -w 3 $1 $2"
  else
    remote "timeout 3 bash -c ': </dev/tcp/$1/$2'"
  fi
}
# probe CID REASON PORT LABEL - 0 when a mini-baas box cannot dial CID:PORT and the VM
# host can; else append the reason to c6_detail and return 1.
probe() {
  if [ -z "$1" ]; then c6_detail="$c6_detail $4:cannot-decide($2);"; return 1; fi
  ip="$(d inspect -f "{{ (index .NetworkSettings.Networks \"$CTRL_NET\").IPAddress }}" "$1")"
  if [ -z "$ip" ]; then c6_detail="$c6_detail $4:no-$CTRL_NET-address;"; return 1; fi
  # nc -z exits 1 on no connection; docker's own failures (image, network) are 125-127
  # and must never read as "unreachable".
  rc=0; d run --rm --pull never --network mini-baas_mini-baas busybox:1.36 nc -z -w 3 "$ip" "$3" || rc=$?
  case "$rc" in
    0) c6_detail="$c6_detail $4:box-reaches($ip:$3);"; return 1 ;;
    1) ;;
    *) c6_detail="$c6_detail $4:cannot-decide(box run rc=$rc);"; return 1 ;;
  esac
  if ! host_probe "$ip" "$3"; then c6_detail="$c6_detail control($ip:$3);"; return 1; fi
  return 0
}
# C1 - each plane container runs the image shipped from here, by config + layers, not .Id
# (containerd ids it by manifest). Ponytail: history/timestamps uncompared, see deploy-plane.sh.
FINGERPRINT='{{json .Config}} {{json .RootFS.Layers}}'
c1() {
  case "$proxy_cid:$server_cid" in :* | *:)
    bad "C1 image-equality:cannot-decide(proxy ${proxy_reason:-ok} server ${server_reason:-ok})"; return ;;
  esac
  run_p="$(d inspect -f '{{.Image}}' "$proxy_cid")"
  run_s="$(d inspect -f '{{.Image}}' "$server_cid")"
  if [ "$(d image inspect -f "$FINGERPRINT" "$run_p")" = "$(docker image inspect -f "$FINGERPRINT" "$PROXY_IMAGE")" ] &&
    [ "$(d image inspect -f "$FINGERPRINT" "$run_s")" = "$(docker image inspect -f "$FINGERPRINT" "$BRIDGE_IMAGE")" ]; then
    ok "C1 each plane container runs the image shipped (same config and layers: socket-proxy, ide-server)"
  else
    bad "C1 image-equality:the VM runs proxy $run_p / ide-server $run_s, not $PROXY_IMAGE / $BRIDGE_IMAGE from here"
  fi
}
# C2 - the token secret reaches no file under the VM home; it crosses only on stdin, grep
# prints file names, .cache excluded. $HOME expands on the VM (kept literal here).
c2() {
  [ -r "$ENV_FILE" ] ||
    { bad "C2 token-secret-in-no-home-file:cannot-decide(OSIONOS_IDE_ENV_FILE unset or unreadable)"; return; }
  secret="$(sed -n 's/^OSIONOS_IDE_TOKEN_SECRET=//p' "$ENV_FILE")"
  [ -n "$secret" ] ||
    { bad "C2 token-secret-in-no-home-file:cannot-decide(no OSIONOS_IDE_TOKEN_SECRET in $ENV_FILE)"; return; }
  # grep exits 1 for "no match" only; 2 (an unreadable path) may still have listed files,
  # so the output is kept whatever the status, and no match plus an error is undecided.
  rc=0
  files="$(printf '%s' "$secret" | timeout 60 ssh "$HOST" "grep -rlsF --exclude-dir=.cache -f - \"\$HOME\"")" || rc=$?
  unset secret
  if [ -n "$files" ]; then
    bad "C2 token-secret-in-no-home-file:FOUND($(printf '%s' "$files" | tr '\n' ','))"
  elif [ "$rc" -eq 1 ]; then
    ok "C2 token-secret-in-no-home-file"
  else
    bad "C2 token-secret-in-no-home-file:cannot-decide(grep rc=$rc)"
  fi
}
# C4 - the socket-proxy container has a non-zero Memory and PidsLimit.
c4() {
  if [ -z "$proxy_cid" ]; then bad "C4 socket-proxy-caps:cannot-decide(${proxy_reason:-ok})"; return; fi
  mem="$(d inspect -f '{{.HostConfig.Memory}}' "$proxy_cid")"
  pids="$(d inspect -f '{{.HostConfig.PidsLimit}}' "$proxy_cid")"
  if [ -n "$mem" ] && [ "$mem" != 0 ] && [ -n "$pids" ] && [ "$pids" != 0 ]; then
    ok "C4 socket-proxy HostConfig Memory and PidsLimit are both non-zero"
  else
    bad "C4 socket-proxy-caps:Memory=$mem PidsLimit=$pids (a zero or unset cap)"
  fi
}
# C6 - a mini-baas box cannot open TCP to ide-server:4100 or proxy:2375, but the VM
# host can (positive control, so a broken probe never reads as a pass).
c6() {
  c6_detail=''
  p1=0; probe "$proxy_cid" "${proxy_reason:-ok}" 2375 proxy || p1=1
  p2=0; probe "$server_cid" "${server_reason:-ok}" 4100 ide-server || p2=1
  if [ "$p1" -eq 0 ] && [ "$p2" -eq 0 ]; then
    ok "C6 a mini-baas box cannot dial ide-server:4100 or proxy:2375; the VM host can"
  else
    bad "C6 grobase-net-isolation:$c6_detail"
  fi
}
# C7 - no container on network=host, and the docker group's only member is the operator
# (the ssh login user). Ponytail: reads the SECONDARY member list (field 4); an operator
# whose PRIMARY group is docker reads empty here and would be a false FAIL.
c7() {
  hostnet="$(d ps -q --filter network=host)"
  operator="$(remote 'id -un')"
  members="$(remote 'getent group docker' | cut -d: -f4)"
  mem_sorted="$(printf '%s' "$members" | tr ',' '\n' | sed '/^$/d' | sort -u)"
  if [ -n "$hostnet" ]; then
    bad "C7 no-host-net-container:FOUND($(printf '%s' "$hostnet" | tr '\n' ','))"
  elif [ -z "$operator" ] || [ "$mem_sorted" != "$operator" ]; then
    bad "C7 docker-group-only-operator:members[$(printf '%s' "$members" | tr ',' ' ')] vs operator[$operator]"
  else
    ok "C7 no host-network container; the docker group's only member is the operator"
  fi
}
# C8 - both plane network subnets are private and outside 10.202.0.0/16.
c8() {
  csub="$(d network inspect "$CTRL_NET" -f '{{(index .IPAM.Config 0).Subnet}}')"
  esub="$(d network inspect "$EDGE_NET" -f '{{(index .IPAM.Config 0).Subnet}}')"
  if subnet_ok "$csub" && subnet_ok "$esub"; then
    ok "C8 both plane subnets are private and outside 10.202.0.0/16 (control=$csub edge=$esub)"
  else
    bad "C8 plane-subnet-range:control=$csub edge=$esub (want a private range other than 10.202/16)"
  fi
}
# c10_one ROLE CID REASON - append a host binding on CID to the global det. A host
# binding is always a JSON array; an exposed-only port is null, which is allowed.
c10_one() {
  if [ -z "$2" ]; then det="$det $1:cannot-decide($3)"; return; fi
  pb="$(d inspect -f '{{json .HostConfig.PortBindings}}' "$2")"
  np="$(d inspect -f '{{json .NetworkSettings.Ports}}' "$2")"
  case "$pb" in *'['*) det="$det $1:PortBindings=$pb" ;; esac
  case "$np" in *'['*) det="$det $1:Ports=$np" ;; esac
}
# C10 - neither plane container publishes a host port.
c10() {
  det=''
  c10_one proxy "$proxy_cid" "${proxy_reason:-ok}"
  c10_one server "$server_cid" "${server_reason:-ok}"
  if [ -z "$det" ]; then
    ok "C10 no host port binding on either plane container"
  else
    bad "C10 host-port-binding:$det"
  fi
}

# C21 - public exposure declined 2026-10-14 (link-only): the VM's tailscale serve/funnel
# config names no IDE port or plane address, and only the two plane containers sit on the
# plane networks. Ponytail: a substring match on the serve JSON - a target spelt any other
# way (a DNS name with no port) is missed; an unrelated "...:4100" fails safe.
c21() {
  ts="$(remote 'tailscale serve status --json && tailscale funnel status --json')" || ts=''
  if [ -z "$ts" ] || [ -z "$proxy_cid" ] || [ -z "$server_cid" ]; then
    bad "C21 cannot-decide(tailscale status or a plane container missing)"; return
  fi
  det=''
  for a in :4100 :8446 :2375 $(d inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}: {{end}}' "$proxy_cid" "$server_cid"); do
    case "$ts" in *"$a"*) det="$det serve->$a" ;; esac
  done
  plane=" $(d inspect -f '{{.Name}}' "$proxy_cid" "$server_cid" | tr -d / | tr '\n' ' ')"
  for m in $(d network inspect "$CTRL_NET" "$EDGE_NET" -f '{{range .Containers}}{{.Name}} {{end}}'); do
    case "$plane" in *" $m "*) ;; *) det="$det extra-on-plane-net:$m" ;; esac
  done
  if [ -z "$det" ]; then ok "C21 no tailscale serve/funnel target and no extra container reach the IDE plane"; else bad "C21 exposed:$det"; fi
}

find_plane
c1; c2; c4; c6; c7; c8; c10; c21
printf 'RESULT: %d ok, %d failed\n' "$okn" "$failed"
[ "$failed" -eq 0 ]
