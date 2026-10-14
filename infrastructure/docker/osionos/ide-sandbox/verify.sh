#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    verify.sh                                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/07/19 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/07/20 00:00:00 by dlesieur         ###   ########.fr       #
#                                                                              #
# **************************************************************************** #

# Hostile-corpus gate for the IDE sandbox plane — the devil's 16
# conditions as runnable probes. Run AFTER `bootstrap.sh` with the `ide`
# profile up. Probes run inside TWO throwaway boxes (ide-probe-a/b)
# in the PRODUCTION shape (uid 10001, /workspace on named volume,
# CapDrop ALL, no-new-privileges, tmpfs /tmp 64m + /home/coder 64m,
# pids 512, memory 1 GiB swap equal, 1 CPU). Positive controls run first
# so a broken probe tool never reads as a pass; every probe prints exactly
# one PASS/FAIL/SKIP line, and the RESULT line checks the total against EXPECTED.
# Ponytail: flags are copied by hand from buildContainerSpec — the proxy
# parity test (scripts/tests/ide-proxy-parity.mjs) catches drift in the
# bridge, this copy can still lag it.

set -u
IDE="docker -H unix://${OSIONOS_IDE_DOCKER_SOCK:-/run/docker-ide.sock}"
MAIN="docker -H unix:///var/run/docker.sock"
SANDBOX_NET="osio-ide-sandbox-net"
SANDBOX_IMAGE="${OSIONOS_IDE_SANDBOX_IMAGE:-osionos-ide-sandbox:latest}"
BOX_A=ide-probe-a
BOX_B=ide-probe-b
RUNNER_PROBE=ide-runner-sigusr1-probe
NAT_CHECK=/usr/local/sbin/osionos-ide-egress-nat
PLANE_PROJECT=osionos-ide-plane
pass=0; fail=0; skipped=0
EXPECTED=43
# The VM's default gateway (user-mode QEMU: 10.0.2.2 is the physical host's loopback, where 4242
# is the VM's own forwarded ssh). Elsewhere set a port that listens on that gateway.
GATEWAY_PORT="${OSIONOS_IDE_VERIFY_GATEWAY_PORT:-4242}"

ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
# A probe whose subject is not deployed on this host. Counted toward EXPECTED and printed in the
# RESULT line, so a skip is never read as a pass.
skip() { printf '  \033[0;33mSKIP\033[0m %s\n' "$1"; skipped=$((skipped+1)); }
# in-box exec (on the isolated docker-ide daemon, box A)
sx()   { $IDE exec "$BOX_A" sh -c "$1" 2>/dev/null; }
# expect the in-box command to FAIL (non-zero) — the safe outcome
deny() { if sx "$1" >/dev/null 2>&1; then bad "$2"; else ok "$2"; fi; }
# TCP connect from box A: /dev/tcp dials raw TCP, so a non-HTTP port is
# still testable — an HTTP client fails on a non-HTTP port even when the
# connect succeeds (never use curl for reachability). The image carries
# bash (Dockerfile L20) and timeout (coreutils, essential in the L11 base).
# Ponytail: a slow-but-reachable path reads as denied here — 4s errs
# toward false denies on a loaded host, never toward a false pass.
reach() { sx "timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2'" >/dev/null 2>&1; }
# From the host itself (a positive control for each target).
host_reach() { timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }
# A refused connect and a dropped one look alike from the box, so each target is first shown
# to accept connections from the host; otherwise "unreachable" would prove nothing.
no_reach() {
  if ! host_reach "$1" "$2"; then bad "control: $1:$2 accepts no connection from the host either — probe a listening port"
  elif reach "$1" "$2"; then bad "box reaches $1:$2"
  else ok "box cannot reach $1:$2"; fi
}

# A box must not reach a control-plane service on the main daemon (selected by compose labels);
# every address the container has is controlled from the host first, like no_reach. One line.
plane_no_reach() {
  service=$1; port=$2
  if ! ids=$($MAIN ps -q --filter "label=com.docker.compose.project=$PLANE_PROJECT" \
      --filter "label=com.docker.compose.service=$service" 2>/dev/null); then
    bad "$service: the main daemon did not answer"; return
  fi
  count=$(printf '%s\n' "$ids" | grep -c .)
  if [ "$count" -eq 0 ]; then skip "$service:$port: IDE plane not deployed on this host"; return; fi
  if [ "$count" -gt 1 ]; then bad "$service: $count plane containers; expected one"; return; fi
  ips=$($MAIN inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$ids" 2>/dev/null \
    | tr ' ' '\n' | grep .)
  if [ -z "$ips" ]; then bad "$service has no IPv4 address on any network"; return; fi
  verdict=$(printf '%s\n' "$ips" | while read -r ip; do
    if ! host_reach "$ip" "$port"; then printf 'uncontrolled %s\n' "$ip"; break; fi
    if reach "$ip" "$port"; then printf 'reached %s\n' "$ip"; break; fi
  done)
  case "$verdict" in
    reached*) bad "box reaches $service ${verdict#reached }:$port" ;;
    uncontrolled*) bad "control: $service ${verdict#uncontrolled }:$port accepts no connection from the host either" ;;
    *) ok "box cannot reach $service ($(printf '%s\n' "$ips" | tr '\n' ' ' | sed 's/ $//')):$port" ;;
  esac
}

# Cleanup on ANY exit (early ones included): both probe boxes, both
# their volumes, and the runner probe container.
cleanup() {
  $IDE rm -f "$BOX_A" "$BOX_B" >/dev/null 2>&1
  $IDE volume rm "osio-ide-vol-$BOX_A" "osio-ide-vol-$BOX_B" >/dev/null 2>&1
  docker rm -f "$RUNNER_PROBE" >/dev/null 2>&1
}
trap cleanup EXIT

# One throwaway box in the production shape (buildContainerSpec,
# apps/osionos/app/scripts/ide-sandbox-spec.mjs:56-97).
# Ponytail: these flags are copied by hand from buildContainerSpec —
# the proxy parity test (scripts/tests/ide-proxy-parity.mjs) is what
# catches drift in the bridge, this copy can still lag it.
start_box() {
  $IDE rm -f "$1" >/dev/null 2>&1
  $IDE volume rm "osio-ide-vol-$1" >/dev/null 2>&1
  $IDE run -d --name "$1" \
    --network "$SANDBOX_NET" \
    --user 10001:10001 --workdir /workspace \
    --cap-drop ALL --security-opt no-new-privileges:true --read-only \
    -v "osio-ide-vol-$1":/workspace \
    --tmpfs /tmp:size=64m,mode=1777 \
    --tmpfs /home/coder:size=64m,mode=0700,uid=10001,gid=10001 \
    --pids-limit 512 --memory 1g --memory-swap 1g --cpus 1 \
    --ulimit core=0:0 --ulimit nproc=512:512 --ulimit nofile=4096:4096 \
    --restart no \
    -e HTTP_PROXY=http://ide-egress:8080 \
    -e HTTPS_PROXY=http://ide-egress:8080 \
    -e http_proxy=http://ide-egress:8080 \
    -e https_proxy=http://ide-egress:8080 \
    -e NO_PROXY=localhost,127.0.0.1 \
    -e no_proxy=localhost,127.0.0.1 \
    -e GIT_TERMINAL_PROMPT=0 \
    "$SANDBOX_IMAGE" sleep infinity >/dev/null 2>&1
}

start_box "$BOX_A" || printf 'warning: %s failed to start — probes fail closed\n' "$BOX_A" >&2
start_box "$BOX_B" || printf 'warning: %s failed to start — probes fail closed\n' "$BOX_B" >&2
# Ponytail: a box still mounting its volumes reads as not-yet-up —
# 2s errs toward probes failing closed (controls first), never
# toward a false pass.
sleep 2

echo "== Probe controls =="
# Positive controls FIRST: if the probe tool itself is broken (box
# down, no egress proxy), every deny below would pass vacuously —
# so the controls gate the run's meaning, not just the box's health.
ctrl=0
if reach 10.202.0.2 8080; then
  ok "control: egress proxy answers at 10.202.0.2:8080"
else
  bad "control: egress proxy answers at 10.202.0.2:8080"
  ctrl=1
fi
if [ "$(sx 'ulimit -n')" = "4096" ]; then
  ok "control: box nofile limit is 4096"
else
  bad "control: box nofile limit is 4096"
  ctrl=1
fi
# One summary line either way, so the pinned count holds.
if [ "$ctrl" -eq 0 ]; then
  ok "probe controls hold"
else
  bad "probe controls — the deny results below would prove nothing"
fi

echo "== Egress (conditions 3,4,5,6) =="
# DIRECT reachability, proxy env bypassed (--noproxy): the internal sandbox-net
# gives NO off-box route, so every direct dial MUST fail. (If the proxy env is
# honored a proxy-DENIED http response reads as curl-success, masking the block —
# so we test the raw network path here and the proxy's own refusal below.)
deny "curl -s --noproxy '*' --max-time 5 http://mini-baas-kong:8000/ -o /dev/null" "no direct route to backend"
deny "curl -s --noproxy '*' --max-time 5 http://169.254.169.254/ -o /dev/null" "cloud metadata v4 blocked (direct)"
deny "curl -s --noproxy '*' --max-time 5 -g 'http://[fd00:ec2::254]/' -o /dev/null" "cloud metadata v6 blocked (direct)"
deny "curl -s --noproxy '*' --max-time 5 https://1.1.1.1/ -o /dev/null" "no direct public route (proxy-only)"
# The egress proxy is the SOLE path out: allowlisted host reachable, others not,
# and metadata REFUSED even when explicitly dialed through it (conditions 5,6).
if sx "curl -s --max-time 12 -x http://ide-egress:8080 https://github.com/ -o /dev/null"; then ok "allowlisted host reachable via proxy"; else bad "allowlisted host reachable via proxy"; fi
deny "curl -s --max-time 8 -x http://ide-egress:8080 https://evil.example.com/ -o /dev/null" "proxy denies non-allowlisted host"
mcode=$(sx "curl -s --max-time 6 -x http://ide-egress:8080 -o /dev/null -w '%{http_code}' http://169.254.169.254/")
case "${mcode:-000}" in 2*) bad "proxy refuses metadata via CONNECT (got $mcode)";; *) ok "proxy refuses metadata via proxy (${mcode:-timeout})";; esac

echo "== Host reachability =="
# The sandbox net's only off-net path is the egress proxy: the bridge
# gateway and every host global address must be unreachable from a box.
no_reach 10.202.0.1 4242
no_reach 10.202.0.1 8443
no_reach 10.202.0.1 8880
# The default gateway is off-host (on the VM: the physical host), reached through FORWARD, not INPUT.
GATEWAY=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
if [ -n "$GATEWAY" ]; then no_reach "$GATEWAY" "$GATEWAY_PORT"; else bad "default gateway: none on the host"; fi
# Every host global IPv4, computed on the HOST (not in the box). One
# verdict line naming the addresses keeps the pinned line count stable
# on any host; the first reachable address is named when the deny fails.
HOST_IPS=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
if [ -z "$HOST_IPS" ]; then
  # No address to probe: the check cannot decide — refuse, never pass.
  bad "no route to host global addresses on 4242 (none listed)"
else
  # Each address must accept 4242 from the host itself (control), and never from the box.
  verdict=$(printf '%s\n' "$HOST_IPS" | while read -r hip; do
    if ! host_reach "$hip" 4242; then printf 'uncontrolled %s\n' "$hip"; break; fi
    if reach "$hip" 4242; then printf 'reached %s\n' "$hip"; break; fi
  done)
  named=$(printf '%s\n' "$HOST_IPS" | tr '\n' ' ')
  case "$verdict" in
    reached*) bad "box reaches host global ${verdict#reached }:4242" ;;
    uncontrolled*) bad "control: ${verdict#uncontrolled }:4242 accepts no connection from the host either" ;;
    *) ok "box cannot reach host global addresses on 4242 ($named)" ;;
  esac
fi

echo "== Control plane reachability =="
# The IDE control plane (osionos-ide-server:4100, osionos-ide-socket-proxy:2375)
# runs on the MAIN daemon in the osionos-ide-plane compose project. A box on the
# isolated docker-ide daemon must not reach either service.
plane_no_reach osionos-ide-server 4100
plane_no_reach osionos-ide-socket-proxy 2375

echo "== Neighbour box =="
# Box B listens on 9999 (python3 in image), detached 30s.
# Ponytail: slower listener reads as unreachable; 2s errs toward control fail.
$IDE exec -d "$BOX_B" timeout 30 bash -c 'python3 -m http.server 9999' >/dev/null 2>&1
sleep 2
BIP=$($IDE inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$BOX_B" 2>/dev/null)
if [ -n "$BIP" ] && reach "$BIP" 9999; then bad "no route to neighbour box $BIP:9999"
elif [ -z "$BIP" ]; then bad "no route to neighbour box on 9999 (box B has no address)"
else ok "no route to neighbour box $BIP:9999"; fi
# Listener control: from inside box B to itself must succeed.
if $IDE exec "$BOX_B" sh -c "timeout 4 bash -c 'exec 3<>/dev/tcp/127.0.0.1/9999'" >/dev/null 2>&1; then ok "control: neighbour listener on 127.0.0.1:9999 inside box B"
else bad "control: neighbour listener on 127.0.0.1:9999 inside box B"; fi

echo "== Egress IP literals (conditions 5,6) =="
# Literals through proxy must not 2xx; proxy re-resolves addresses.
# Ponytail: slow refusal reads as timeout — longer runs, not false 2xx.
for url in "http://10.0.0.1/" "http://127.1/" "http://2130706433/" \
           "http://0x7f.0.0.1/" "http://[::1]/" "https://100.100.100.100/"; do
  mcode=$(sx "curl -s --max-time 8 -g -x http://ide-egress:8080 -o /dev/null -w '%{http_code}' $url")
  case "${mcode:-000}" in 2*) bad "egress proxy refuses IP literal $url (got $mcode)";; *) ok "egress proxy refuses IP literal $url (${mcode:-timeout})";; esac
done

echo "== User namespace =="
# docker-ide runs --userns-remap=default: the box's own uid_map must
# carry a NON-zero host-side id (field 2) — 0 means the box shares the
# daemon's namespace and root in the box is the daemon's root.
uidmap=$(sx "awk 'NR==1{print \$2}' /proc/self/uid_map")
if [ -n "$uidmap" ] && [ "$uidmap" != "0" ]; then
  ok "userns remap active (uid_map host id $uidmap)"
else
  bad "userns remap active (uid_map host id ${uidmap:-unreadable})"
fi

echo "== Identity =="
if [ "$(sx 'id -u')" = "10001" ]; then ok "box runs as uid 10001 (spec user)"; else bad "box runs as uid 10001 (spec user)"; fi

echo "== Init =="
# 50 orphans reparented to PID 1, then a second for it to reap them. With `sleep infinity` as
# PID 1 they stayed zombies, and hellish's build filled pids.max with 469 (2026-10-14).
sx 'i=0; while [ $i -lt 50 ]; do (sleep 0.1 &); i=$((i+1)); done; sleep 1' >/dev/null 2>&1
if [ "$(sx "ps -eo stat= | grep -c '^Z'")" = "0" ]; then ok "PID 1 reaps orphaned processes"; else bad "PID 1 reaps orphaned processes"; fi

echo "== Memory caps =="
# Box cgroup: 1 GiB with swap equal; slice: 6 GiB (six boxes, osionos-ide.slice); box scope inside slice.
if [ "$(sx 'cat /sys/fs/cgroup/memory.max')" = "1073741824" ]; then ok "box memory.max is 1 GiB"; else bad "box memory.max is 1 GiB"; fi
SLICE_CG=$(systemctl show -p ControlGroup --value osionos-ide.slice)
if [ -n "$SLICE_CG" ] && [ "$(cat /sys/fs/cgroup/"$SLICE_CG"/memory.max 2>/dev/null)" = "6442450944" ]; then ok "slice memory.max is 6 GiB"; else bad "slice memory.max is 6 GiB"; fi
BOX_ID=$($IDE inspect -f '{{.Id}}' "$BOX_A" 2>/dev/null)
if [ -n "$BOX_ID" ] && [ -n "$SLICE_CG" ] && [ -n "$(find /sys/fs/cgroup/"$SLICE_CG" -maxdepth 2 -name "docker-$BOX_ID.scope" 2>/dev/null | head -1)" ]; then ok "box scope inside slice"; else bad "box scope inside slice"; fi

echo "== Daemon =="
# docker-ide in osionos-ide.slice; main daemon must not list probe.
if systemctl show -p ControlGroup --value docker-ide | grep -q 'osionos-ide.slice'; then ok "docker-ide in slice"; else bad "docker-ide in slice"; fi
if [ -z "$(docker ps -aq --filter name=ide-probe-a)" ]; then ok "main daemon no probe"; else bad "main daemon no probe"; fi

echo "== Host rules =="
# The scoped egress NAT rules are a condition, never a SKIP: a
# missing checker is a FAIL.
if [ -x "$NAT_CHECK" ] && "$NAT_CHECK" check >/dev/null 2>&1; then ok "host egress NAT rules in place (egress-nat check)"; else bad "host egress NAT rules in place (egress-nat check)"; fi

echo "== Sandbox isolation (conditions 3,4) =="
deny "test -S /var/run/docker.sock" "no docker socket in sandbox"
deny "command -v docker"            "no docker binary in sandbox"
deny "unshare -Ur id"               "unprivileged userns blocked (seccomp)"
deny "cat /proc/1/root/etc/shadow"  "no host fs escape"

echo "== Resource caps (conditions 14,15,16) =="
if [ "$(sx 'ulimit -c')" = "0" ]; then ok "core dumps disabled (RLIMIT_CORE=0)"; else bad "core dumps disabled (RLIMIT_CORE=0)"; fi
deny "fallocate -l 2000M /tmp/big" "tmpfs write bounded by quota"

echo "== Socket-proxy body filter (conditions 8,9) =="
# The create-body vetting (Privileged/Binds/host-modes/CapAdd reject + endpoint
# allowlist + name pinning) is exhaustively asserted by the proxy's own
# --selfcheck; run it here as the condition-8/9 proof rather than a fragile
# wget across the internal control-net (the proxy is not host-reachable).
# `--network none`: the selfcheck runs pure assertions, needs no network — and
# avoids depending on the main daemon's default bridge.
# Shipped images (ship-images.sh) exist only in docker-ide, built ones on the main daemon:
# run the selfcheck on whichever daemon holds the image.
selfcheck() {
  if $IDE image inspect "$1" >/dev/null 2>&1; then run_on="$IDE"
  elif docker image inspect "$1" >/dev/null 2>&1; then run_on=docker
  else skip "$2: image $1 is on neither daemon"; return; fi
  if $run_on run --rm --network none "$1" node /app/proxy.mjs --selfcheck >/dev/null 2>&1; then ok "$2"; else bad "$2"; fi
}
selfcheck "${OSIONOS_IDE_SOCKET_PROXY_IMAGE:-osionos-ide-socket-proxy:latest}" "socket-proxy body filter + endpoint allowlist (--selfcheck)"
# Egress proxy deny-tables (metadata/RFC1918/IPv6 ULA) — condition 5,6.
selfcheck "${OSIONOS_IDE_EGRESS_IMAGE:-osionos-ide-egress:latest}" "egress-proxy deny tables + IP revalidation (--selfcheck)"

echo "== Code runner (shared uid) =="
# The runner executes every user's code in ONE container, as the SAME uid as its own
# server (cap_drop ALL leaves no way to switch uid per run). Node treats SIGUSR1 as
# "start the inspector", and user code may signal a same-uid process: measured, one
# `kill -USR1 1` from uid 10001 made the server log "Debugger listening", i.e. any
# user's program could attach to the broker of everyone's runs. The server must be
# started with --disable-sigusr1. Probed on a THROWAWAY copy, never the live runner.
RUNNER_IMAGE="${OSIONOS_RUNNER_IMAGE:-track-binocle/osionos-runner:local}"
if docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1; then
  rp="$RUNNER_PROBE"
  docker rm -f "$rp" >/dev/null 2>&1
  docker run -d --name "$rp" --network none --cap-drop ALL --read-only \
    --tmpfs /tmp --tmpfs /work "$RUNNER_IMAGE" >/dev/null 2>&1
  sleep 2
  docker exec -u 10001 "$rp" sh -c 'kill -USR1 1' >/dev/null 2>&1
  sleep 1
  if docker logs "$rp" 2>&1 | grep -qi 'debugger listening'; then
    bad "runner server ignores SIGUSR1 from user code (no inspector)"
  else
    ok "runner server ignores SIGUSR1 from user code (no inspector)"
  fi
  docker rm -f "$rp" >/dev/null 2>&1
else
  skip "runner image $RUNNER_IMAGE not present — the code runner is not deployed on this host"
fi

echo ""
# Pinned count (see EXPECTED above): exit 1 when a check failed OR
# when the line count misses EXPECTED — a probe that silently did
# not run is a failure, not a pass.
printf 'RESULT: %d passed, %d failed, %d skipped (expected %d)\n' "$pass" "$fail" "$skipped" "$EXPECTED"
if [ "$fail" -gt 0 ] || [ $((pass + fail + skipped)) -ne "$EXPECTED" ]; then
  exit 1
fi