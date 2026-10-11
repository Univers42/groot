#!/usr/bin/env bash
# make link-autostart / link-autostart-off: install (or remove) the systemd user units that bring
# the link back on their own after a reboot, a data center restart or a network drop
# (infrastructure/systemd/user/*.in). The units only run at boot with linger on.
#
#   install   render the units with this clone's path, enable grobase-link.service and
#             grobase-link-heal.timer, and hand the link over to the unit (link-down + start)
#             LAN_IF=<iface> also installs grobase-lan-edge.service (WAF on the LAN, 8443 only)
#   remove    disable and delete them; the link itself stays as it is
# Exit: 0 done, 1 a step failed, 2 usage.
set -euo pipefail

groot=$(cd "$(dirname "$0")/.." && pwd)
src="$groot/infrastructure/systemd/user"
unitdir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
ports_file="${VM_PORTS_FILE:-${VM_PATH:-/mnt/storage/virtual_machines}/${VM_NAME:-baas}/ports.env}"

render() { # render <unit>: back up a differing installed copy, then write the rendered one
	local unit="$1" out="$unitdir/$1" tmp
	tmp=$(mktemp)
	sed -e "s|@GROOT@|$groot|g" -e "s|@LAN_IF@|${LAN_IF:-}|g" -e "s|@VM_PORTS_FILE@|$ports_file|g" "$src/$unit.in" >"$tmp"
	if [ -e "$out" ] && ! cmp -s "$tmp" "$out"; then
		cp -a "$out" "$out.bak-$(date +%Y%m%d%H%M%S)"
		echo "[autostart] backed up the installed $unit"
	fi
	mv "$tmp" "$out"
	echo "[autostart] installed $out"
}

install_units() {
	mkdir -p "$unitdir"
	render grobase-link.service
	render grobase-link-heal.service
	render grobase-link-heal.timer
	[ -z "${LAN_IF:-}" ] || render grobase-lan-edge.service
	systemctl --user daemon-reload
	systemctl --user enable grobase-link.service grobase-link-heal.timer
	if [ -n "${LAN_IF:-}" ]; then
		systemctl --user enable grobase-lan-edge.service
		systemctl --user restart grobase-lan-edge.service
	fi
	if ! systemctl --user -q is-active grobase-link.service; then
		echo "[autostart] handing the link to grobase-link.service (link-down, then the unit opens it)"
		make -C "$groot" --no-print-directory link-down
		systemctl --user start grobase-link.service
	fi
	systemctl --user start grobase-link-heal.timer
	[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] ||
		echo "[autostart] linger is off: the units start at login, not at boot (loginctl enable-linger $(id -un))" >&2
}

remove_units() {
	local unit
	for unit in grobase-link-heal.timer grobase-link-heal.service grobase-lan-edge.service grobase-link.service; do
		systemctl --user disable "$unit" >/dev/null 2>&1 || true
		[ "$unit" = grobase-link.service ] || systemctl --user stop "$unit" >/dev/null 2>&1 || true
		rm -f "$unitdir/$unit"
	done
	systemctl --user daemon-reload
	echo "[autostart] removed; the link stays as it is (make link-down closes it)"
}

case "${1:-}" in
install) install_units ;;
remove) remove_units ;;
-h | --help) sed -n '2,10p' "$0" ;;
*)
	sed -n '2,10p' "$0" >&2
	exit 2
	;;
esac
