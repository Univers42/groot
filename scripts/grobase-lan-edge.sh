#!/usr/bin/env bash
# The data center's WAF on this host's LAN address, port 8443 ONLY (grobase-lan-edge.service),
# so a wifi/LAN device without Tailscale reaches grobase. ssh, Redis and Mailpit stay off the
# LAN (devil ruling 2026-10-11: the VM's sshd allows passwords). Clients verify TLS against the
# VM's CA under a name its cert carries: map "<this LAN IP> grobase.track-binocle.test" in the
# device's hosts file (SAN *.track-binocle.test; the LAN IP itself is not in the cert).
#
# The target is the VM's https forward as QEMU actually bound it (VM_PORTS_FILE, "https=<port>"),
# not an assumed 8443: after the 2026-10-12 reboot it sat on 8445 and every LAN client hit a
# dead port.
# Ponytail: the address and the target are read once at start; after a DHCP change or a VM
# restart on another port this keeps forwarding to the old pair until restarted, which
# grobase-link-heal.timer does within two minutes (no TLS answer -> restart).
set -euo pipefail

lan_if="${LAN_IF:?LAN_IF: the host interface on the LAN, e.g. enp7s0}"
ip=$(ip -4 -o addr show dev "$lan_if" | awk '{ split($4, a, "/"); print a[1]; exit }')
[ -n "$ip" ] || {
	echo "grobase-lan-edge: no IPv4 on $lan_if" >&2
	exit 1
}

target=""
if [ -n "${VM_PORTS_FILE:-}" ] && [ -r "$VM_PORTS_FILE" ]; then
	target=$(awk -F= '$1 == "https" { print $2; exit }' "$VM_PORTS_FILE")
fi
target="${target:-8443}"

echo "grobase-lan-edge: $ip:8443 -> 127.0.0.1:$target"
exec socat "TCP-LISTEN:8443,bind=$ip,fork,reuseaddr" "TCP:127.0.0.1:$target"
