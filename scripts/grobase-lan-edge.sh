#!/usr/bin/env bash
# One of the VM's forwards on this host's LAN address, so a wifi/LAN device without Tailscale
# reaches it:
#   grobase-lan-edge.sh [https]   the WAF, LAN :8443   (grobase-lan-edge.service)
#   grobase-lan-edge.sh ssh       the VM's sshd, LAN :4242   (grobase-lan-ssh.service, opt-in)
# Redis and Mailpit stay off the LAN. ssh was kept off too (devil ruling 2026-10-11: the VM's
# sshd allows passwords); on 2026-10-12 the owner chose password ssh from the LAN, so it is a
# separate unit that only `make link-autostart LAN_SSH=1` installs. Its cost: anyone on the same
# LAN can try passwords against the VM's accounts.
# WAF clients verify TLS against the VM's CA under a name its cert carries: map
# "<this LAN IP> grobase.track-binocle.test" in the device's hosts file (SAN *.track-binocle.test;
# the LAN IP itself is not in the cert), or pin the leaf with the grobase CLI.
#
# The target is the forward as QEMU actually bound it (VM_PORTS_FILE, "https=<port>" /
# "ssh=<port>"), not an assumed port: after the 2026-10-12 reboot https sat on 8445 and every
# LAN client hit a dead port.
# Ponytail: the address and the target are read once at start; after a DHCP change or a VM
# restart on another port this keeps forwarding to the old pair until restarted, which
# grobase-link-heal.timer does within two minutes (no answer -> restart).
set -euo pipefail

name="${1:-https}"
case "$name" in
https) listen=8443 ;;
ssh) listen=4242 ;;
*)
	echo "grobase-lan-edge: unknown forward '$name' (https or ssh)" >&2
	exit 2
	;;
esac

lan_if="${LAN_IF:?LAN_IF: the host interface on the LAN, e.g. enp7s0}"
ip=$(ip -4 -o addr show dev "$lan_if" | awk '{ split($4, a, "/"); print a[1]; exit }')
[ -n "$ip" ] || {
	echo "grobase-lan-edge: no IPv4 on $lan_if" >&2
	exit 1
}

target=""
if [ -n "${VM_PORTS_FILE:-}" ] && [ -r "$VM_PORTS_FILE" ]; then
	target=$(awk -F= -v k="$name" '$1 == k { print $2; exit }' "$VM_PORTS_FILE")
fi
target="${target:-$listen}"

echo "grobase-lan-edge: $name $ip:$listen -> 127.0.0.1:$target"
exec socat "TCP-LISTEN:$listen,bind=$ip,fork,reuseaddr" "TCP:127.0.0.1:$target"
