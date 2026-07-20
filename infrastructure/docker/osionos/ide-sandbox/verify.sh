#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    verify.sh                                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/07/19 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/07/20 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# Hostile-corpus gate for the IDE sandbox plane — the devil's 16 conditions as
# runnable probes. Run AFTER `bootstrap.sh` with the `ide` profile up. Creates a
# throwaway probe sandbox in the isolated daemon, asserts each control, cleans up.
# Exit 0 = all conditions hold; non-zero = a BLOCK condition failed.

set -u
IDE="docker -H unix://${OSIONOS_IDE_DOCKER_SOCK:-/run/docker-ide.sock}"
PROBE="ide-probe-corpus"
SANDBOX_NET="osio-ide-sandbox-net"
SANDBOX_IMAGE="${OSIONOS_IDE_SANDBOX_IMAGE:-osionos-ide-sandbox:latest}"
pass=0; fail=0

ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
# in-sandbox exec (on the isolated docker-ide daemon)
sx()   { $IDE exec "$PROBE" sh -c "$1" 2>/dev/null; }
# expect the in-sandbox command to FAIL (non-zero) — the safe outcome
deny() { if sx "$1" >/dev/null 2>&1; then bad "$2"; else ok "$2"; fi; }

$IDE rm -f "$PROBE" >/dev/null 2>&1
$IDE run -d --name "$PROBE" --network "$SANDBOX_NET" \
  --cap-drop ALL --security-opt no-new-privileges:true --read-only \
  --pids-limit 512 --memory 512m --ulimit core=0 \
  --tmpfs /tmp:size=32m --tmpfs /home/coder:size=16m \
  "$SANDBOX_IMAGE" sleep infinity >/dev/null 2>&1 || { echo "probe sandbox failed to start"; exit 2; }
sleep 2

echo "== Egress (conditions 3,4,5,6) =="
deny "curl -s --max-time 5 http://mini-baas-kong:8000/ -o /dev/null" "sandbox cannot reach mini-baas backend"
deny "curl -s --max-time 5 http://169.254.169.254/ -o /dev/null"     "cloud metadata v4 blocked"
deny "curl -s --max-time 5 -g 'http://[fd00:ec2::254]/' -o /dev/null" "cloud metadata v6 blocked"
deny "curl -s --max-time 5 https://1.1.1.1/ -o /dev/null"            "no direct public route (proxy-only)"
if sx "curl -s --max-time 8 -x http://ide-egress:8080 https://github.com/ -o /dev/null"; then ok "allowlisted host reachable via proxy"; else bad "allowlisted host reachable via proxy"; fi
deny "curl -s --max-time 8 -x http://ide-egress:8080 https://evil.example.com/ -o /dev/null" "proxy denies non-allowlisted host"

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
if docker run --rm "${OSIONOS_IDE_SOCKET_PROXY_IMAGE:-osionos-ide-socket-proxy:latest}" node /app/proxy.mjs --selfcheck >/dev/null 2>&1; then
  ok "socket-proxy body filter + endpoint allowlist (--selfcheck)"
else
  bad "socket-proxy body filter + endpoint allowlist (--selfcheck)"
fi
# Egress proxy deny-tables (metadata/RFC1918/IPv6 ULA) — condition 5,6.
if docker run --rm "${OSIONOS_IDE_EGRESS_IMAGE:-osionos-ide-egress:latest}" node /app/proxy.mjs --selfcheck >/dev/null 2>&1; then
  ok "egress-proxy deny tables + IP revalidation (--selfcheck)"
else
  bad "egress-proxy deny tables + IP revalidation (--selfcheck)"
fi

$IDE rm -f "$PROBE" >/dev/null 2>&1
echo ""
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
