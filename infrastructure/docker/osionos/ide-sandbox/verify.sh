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
# in the PRODUCTION shape (each box its own uid 2000N with gid 10001, volumes given to that uid by
# the ownership init and mounted NoCopy, ADR 0011; /workspace on named volume,
# CapDrop ALL, no-new-privileges, tmpfs /tmp 64m exec, per-user home volume at /home/coder,
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
# Two different owners: their uids are what the socket proxy's ledger would have handed out first.
UID_A=20000
UID_B=20001
INIT_VOLUMES="osio-ide-vol-ide-probe-init osio-ide-home-ide-probe-init osio-ide-nocopy-probe"
RUNNER_PROBE=ide-runner-sigusr1-probe
NAT_CHECK=/usr/local/sbin/osionos-ide-egress-nat
PLANE_PROJECT=osionos-ide-plane
pass=0; fail=0; skipped=0
# 44 + 4 persistent-home probes (a)-(d) + 3 identity probes (e)-(g) + 1 /tmp probe + 4 per-user-uid
# probes (ADR 0011); the green line is
# `RESULT: 55 passed, 0 failed, 1 skipped (expected 56)` where the one skip is the runner image,
# absent on a VM without the code runner.
EXPECTED=56
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
  $IDE volume rm "osio-ide-vol-$BOX_A" "osio-ide-vol-$BOX_B" "osio-ide-home-$BOX_A" "osio-ide-home-$BOX_B" $INIT_VOLUMES >/dev/null 2>&1
  docker rm -f "$RUNNER_PROBE" >/dev/null 2>&1
}
trap cleanup EXIT

# One throwaway box in the production shape (buildContainerSpec,
# apps/osionos/app/scripts/ide-sandbox-spec.mjs, and buildInitSpec in ide-volume-init.mjs).
# Ponytail: these flags are copied by hand from buildContainerSpec —
# the proxy parity test (scripts/tests/ide-proxy-parity.mjs) is what
# catches drift in the bridge, this copy can still lag it.
start_box() {
  $IDE rm -f "$1" >/dev/null 2>&1
  $IDE volume rm "osio-ide-vol-$1" "osio-ide-home-$1" >/dev/null 2>&1
  init_volumes "osio-ide-vol-$1" "osio-ide-home-$1" "$(box_uid "$1")" && run_box "$1"
}

box_uid() { if [ "$1" = "$BOX_B" ]; then echo "$UID_B"; else echo "$UID_A"; fi; }

# The ownership init exactly as buildInitSpec shapes it: the sandbox image at the real targets, the
# entrypoint overridden, three capabilities, no network. Copy-up happens here, not under the box.
init_volumes() {
  $IDE run --rm --network none --user 0:0 --entrypoint /usr/local/sbin/osio-volume-init \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_READ_SEARCH --cap-add FOWNER \
    --security-opt no-new-privileges:true --read-only --pids-limit 16 --memory 128m --memory-swap 128m \
    -e OSIO_UID="$3" -v "$1":/workspace -v "$2":/home/coder "$SANDBOX_IMAGE" >/dev/null 2>&1
}

# The box alone, volumes kept: the home must outlive the container.
run_box() {
  $IDE run -d --name "$1" \
    --network "$SANDBOX_NET" \
    --user "$(box_uid "$1"):10001" --workdir /workspace \
    --cap-drop ALL --security-opt no-new-privileges:true --read-only \
    --mount "type=volume,src=osio-ide-vol-$1,dst=/workspace,volume-nocopy" \
    --mount "type=volume,src=osio-ide-home-$1,dst=/home/coder,volume-nocopy" \
    --tmpfs /tmp:size=64m,mode=1777,exec \
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
    -e HOME=/home/coder \
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
if [ "$(sx 'id -u; id -g' | tr '\n' ' ')" = "$UID_A 10001 " ]; then ok "box runs as its own uid $UID_A with gid 10001 (spec user)"; else bad "box runs as its own uid $UID_A with gid 10001 (spec user)"; fi

echo "== Init =="
# 50 orphans reparented to PID 1, then a second for it to reap them. With `sleep infinity` as
# PID 1 they stayed zombies, and hellish's build filled pids.max with 469 (2026-10-14).
sx "i=0; while [ \$i -lt 50 ]; do (sleep 0.1 &); i=\$((i+1)); done; sleep 1" >/dev/null 2>&1
if [ "$(sx "ps -eo stat= | grep -c '^Z'")" = "0" ]; then ok "PID 1 reaps orphaned processes"; else bad "PID 1 reaps orphaned processes"; fi
# The box user signals everything they own, PID 1 included; with tini as PID 1 that stopped
# the box. Box B is done with its probes by now (neighbour section above).
$IDE exec "$BOX_B" sh -c 'pkill -x sleep; kill 1; kill -9 -1' >/dev/null 2>&1
sleep 2
if [ "$($IDE inspect -f '{{.State.Running}}' "$BOX_B" 2>/dev/null)" = "true" ]; then ok "box survives its user killing everything, PID 1 included"; else bad "box survives its user killing everything, PID 1 included"; fi

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

echo "== Persistent home (devil verdict ide-user-shell, H8) =="
# The home is a named volume per user at the constant /home/coder; /etc stays read-only.
# (a) the ownership init gave it to the box's uid, mode 700. (b) the volumes are per box here as per user in production.
# (c) the file outlives the container. (d) the one writable-looking tree outside it is not.
if sx "test \"\$(stat -c %u:%g:%a /home/coder)\" = $UID_A:10001:700 && echo a >/home/coder/probe-a && rm /home/coder/probe-a"; then ok "home is owned by the box uid, mode 700, and writable"; else bad "home is owned by the box uid, mode 700, and writable"; fi
sx 'echo marker >/home/coder/probe-marker' >/dev/null
if $IDE exec "$BOX_B" sh -c 'echo b >/home/coder/probe-b && test ! -e /home/coder/probe-marker' >/dev/null 2>&1; then ok "box B cannot read box A's home (distinct volumes)"; else bad "box B cannot read box A's home (distinct volumes)"; fi
$IDE rm -f "$BOX_A" >/dev/null 2>&1
run_box "$BOX_A" || printf 'warning: %s failed to restart — probes fail closed\n' "$BOX_A" >&2
if [ "$(sx 'cat /home/coder/probe-marker')" = "marker" ]; then ok "a file in the home survives box remove and recreate"; else bad "a file in the home survives box remove and recreate"; fi
deny "touch /etc/probe-x" "/etc is read-only (touch /etc/x denied)"

# /tmp is exec, nosuid and nodev (ADR 0010): the mount flags AND a copied binary that runs, because
# a flag read alone would pass on a daemon that merges the options differently.
tmp_flags=$(sx 'grep " /tmp " /proc/self/mounts' | awk '{print $4}')
case ",$tmp_flags," in
  *,nosuid,*) has_nosuid=1 ;; *) has_nosuid=0 ;;
esac
case ",$tmp_flags," in
  *,nodev,*) has_nodev=1 ;; *) has_nodev=0 ;;
esac
case ",$tmp_flags," in
  *,noexec,*) has_noexec=1 ;; *) has_noexec=0 ;;
esac
if [ "$has_nosuid" = 1 ] && [ "$has_nodev" = 1 ] && [ "$has_noexec" = 0 ] && sx 'cp /bin/true /tmp/probe-true && /tmp/probe-true && rm /tmp/probe-true'; then ok "/tmp is exec, nosuid and nodev, and a copied binary runs"; else bad "/tmp is exec, nosuid and nodev, and a copied binary runs"; fi

echo "== Per-user uid (ADR 0011) =="
# Different users get different host uids, so the kernel, not a path, keeps their files apart.
# (h) a box of another uid cannot enter this home even if its volume were mounted by mistake, with a
# control that the owner can. (i) the two boxes' processes have different host uids, offset by their
# uids in the remap range. (j) NoCopy keeps a fresh volume's root as Docker made it, where a copy-up
# would hand it to the image's 10001. (k) the init, with only its three capabilities, gives a 0700
# tree another uid left behind to the new uid: the case CHOWN alone cannot walk.
foreign_home() {
  $IDE run --rm --network none --user "$1:10001" --cap-drop ALL --read-only --entrypoint sh \
    --mount "type=volume,src=osio-ide-home-$BOX_A,dst=/home/coder,volume-nocopy" \
    "$SANDBOX_IMAGE" -c 'ls /home/coder' >/dev/null 2>&1
}
if foreign_home "$UID_A" && ! foreign_home "$UID_B"; then ok "another uid cannot list box A's home; its owner can"; else bad "another uid cannot list box A's home; its owner can"; fi
pid_a=$($IDE inspect -f '{{.State.Pid}}' "$BOX_A" 2>/dev/null)
pid_b=$($IDE inspect -f '{{.State.Pid}}' "$BOX_B" 2>/dev/null)
host_a=$(stat -c %u "/proc/${pid_a:-0}" 2>/dev/null)
host_b=$(stat -c %u "/proc/${pid_b:-0}" 2>/dev/null)
if [ -n "$uidmap" ] && [ "$host_a" = $((uidmap + UID_A)) ] && [ "$host_b" = $((uidmap + UID_B)) ]; then ok "box A and box B run as different host uids ($host_a, $host_b)"; else bad "box A and box B run as different host uids (${host_a:-?}, ${host_b:-?})"; fi
nocopy_root() { $IDE run --rm --network none --user 0:0 --entrypoint stat --mount "type=volume,src=osio-ide-nocopy-probe,dst=/home/coder$1" "$SANDBOX_IMAGE" -c %u /home/coder 2>/dev/null; }
$IDE volume rm osio-ide-nocopy-probe >/dev/null 2>&1
nocopy_owner=$(nocopy_root ,volume-nocopy)
$IDE volume rm osio-ide-nocopy-probe >/dev/null 2>&1
copyup_owner=$(nocopy_root "")
if [ "$nocopy_owner" = 0 ] && [ "$copyup_owner" = 10001 ]; then ok "volume-nocopy leaves a fresh volume root alone (copy-up would give it to 10001)"; else bad "volume-nocopy leaves a fresh volume root alone (nocopy ${nocopy_owner:-?}, copy-up ${copyup_owner:-?})"; fi
$IDE volume rm osio-ide-nocopy-probe osio-ide-vol-ide-probe-init osio-ide-home-ide-probe-init >/dev/null 2>&1
$IDE run --rm --network none --user 0:0 --entrypoint sh --cap-drop ALL --cap-add CHOWN \
  -v osio-ide-vol-ide-probe-init:/workspace -v osio-ide-home-ide-probe-init:/home/coder "$SANDBOX_IMAGE" \
  -c 'mkdir -p /home/coder/old/deep && echo x >/home/coder/old/deep/f && chown -R 30000:10001 /home/coder/old && chmod 700 /home/coder/old /home/coder/old/deep' >/dev/null 2>&1
init_volumes osio-ide-vol-ide-probe-init osio-ide-home-ide-probe-init "$UID_A"
tree_owner=$($IDE run --rm --network none --user "$UID_A:10001" --cap-drop ALL --read-only --entrypoint stat \
  --mount "type=volume,src=osio-ide-home-ide-probe-init,dst=/home/coder,volume-nocopy" "$SANDBOX_IMAGE" -c %u:%g /home/coder/old/deep/f 2>/dev/null)
if [ "$tree_owner" = "$UID_A:10001" ]; then ok "the init gives a 0700 tree another uid left to the new uid with three capabilities"; else bad "the init gives a 0700 tree another uid left to the new uid with three capabilities (${tree_owner:-unreadable})"; fi

echo "== Box identity (ADR 0009, P6) =="
# /etc/passwd links to /tmp/.osio/passwd, which box-init writes before the Cmd starts. A `docker
# exec` that lands in the first milliseconds can precede that write, so (e) and (g) ask again for
# up to 5 s. (e) the numeric user resolves to coder and HOME is the create Env's. (f) a hostile
# account file changes neither uid nor HOME: runc takes both from the numeric User and the create
# Env. (g) a file that breaks every exec (a 100 KB line) is cured by a restart, which gives /tmp
# a fresh tmpfs.
sx_retry() {
  for _ in 1 2 3 4 5; do
    if out=$(sx "$1") && [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    sleep 1
  done
  return 1
}
if [ "$(sx_retry 'whoami; echo $HOME' | tr '\n' ' ')" = "coder /home/coder " ]; then ok "whoami is coder and HOME is /home/coder right after start"; else bad "whoami is coder and HOME is /home/coder right after start"; fi
sx "printf 'root:x:$UID_A:10001::/root:/bin/sh\n' >/tmp/.osio/passwd" >/dev/null
if [ "$(sx 'id -u; echo $HOME' | tr '\n' ' ')" = "$UID_A /home/coder " ]; then ok "a hostile passwd file changes neither uid nor HOME"; else bad "a hostile passwd file changes neither uid nor HOME"; fi
sx 'head -c 100000 /dev/zero | tr "\0" a >/tmp/.osio/passwd' >/dev/null
$IDE restart -t 2 "$BOX_A" >/dev/null 2>&1
if [ "$(sx_retry 'whoami' | tr -d '\n')" = "coder" ]; then ok "a passwd file that breaks every exec is cured by a box restart"; else bad "a passwd file that breaks every exec is cured by a box restart"; fi

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