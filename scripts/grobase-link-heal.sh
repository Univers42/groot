#!/usr/bin/env bash
# grobase-link-heal.service, every two minutes: re-open what a reboot, a data center restart or
# a network drop closed, so nobody has to type `make link` again (2026-10-12: after a host
# reboot the relay crash-looped on "no routes" until someone did).
#   - the link: `make link-status` fails -> restart grobase-link.service (link-down + link)
#   - the LAN edge, when its unit is enabled: no TLS answer on <LAN IP>:8443 -> restart it, so
#     it re-reads the LAN address (DHCP) and the VM's https forward
# Never in local mode, and never after `make link-autostart-off` (the timer is gone then).
# Ponytail: "answers" is liveness, not health -- Kong answering 401 counts as up; grobase being
# broken behind Kong is `make link-verify`'s job. A data center that stays down costs one failed
# `make link` in the journal per run until it is back.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ "$(bash scripts/grobase-link.sh mode 2>/dev/null)" = local ]; then
	exit 0
fi

if ! make --no-print-directory link-status >/dev/null 2>&1; then
	echo "grobase-link-heal: link down, re-opening it"
	systemctl --user --no-block restart grobase-link.service
fi

if systemctl --user -q is-enabled grobase-lan-edge.service 2>/dev/null; then
	lan_if=$(systemctl --user show grobase-lan-edge.service -p Environment --value | tr ' ' '\n' | awk -F= '$1 == "LAN_IF" { print $2 }')
	ip=$(ip -4 -o addr show dev "${lan_if:-none}" 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')
	code=000
	[ -z "$ip" ] || code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://$ip:8443/auth/v1/health" 2>/dev/null) || code=000
	if [ "$code" = 000 ]; then
		echo "grobase-link-heal: LAN edge gives no answer on ${ip:-<no address on ${lan_if:-?}>}:8443, restarting it"
		systemctl --user --no-block restart grobase-lan-edge.service
	fi
fi

if systemctl --user -q is-enabled grobase-lan-ssh.service 2>/dev/null; then
	lan_if=$(systemctl --user show grobase-lan-ssh.service -p Environment --value | tr ' ' '\n' | awk -F= '$1 == "LAN_IF" { print $2 }')
	ip=$(ip -4 -o addr show dev "${lan_if:-none}" 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')
	# shellcheck disable=SC2016 # $1 and $l belong to the inner bash -c
	banner=$([ -z "$ip" ] || timeout 8 bash -c 'exec 3<>"/dev/tcp/$1/4242" && IFS= read -r -t 6 l <&3 && printf %s "$l"' _ "$ip" 2>/dev/null) || banner=""
	case "$banner" in
	SSH-*) ;;
	*)
		echo "grobase-link-heal: LAN ssh gives no banner on ${ip:-<no address on ${lan_if:-?}>}:4242, restarting it"
		systemctl --user --no-block restart grobase-lan-ssh.service
		;;
	esac
fi
exit 0
