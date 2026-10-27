#!/usr/bin/env bash
# make publish-socket / publish-socket-off: install (or remove) the opt-in host unit that
# forwards this host's unix socket to the data center VM's Kong, so the osionos bridge's
# co-edit publishes reach the realtime gateway without crossing Tailscale (measured
# 2026-10-27: the tailnet hop ~10 ms p50, this local ssh -L forward 0.43 ms p50).
#
#   install   HOST_KEY_FILE=<file with ONE ssh host public key line of the VM, obtained by
#             the operator over a trusted step> pins it as this unit's only trust (no
#             ssh-keyscan, no accept-new) and enables the unit. PUBLISH_SSH_IDENTITY
#             (default ~/.ssh/id_ed25519) is the client key, PUBLISH_SSH_USER (default
#             $(id -un)) the ssh user. Prints the socket dir, the value
#             OSIONOS_PUBLISH_SOCKET_DIR takes.
#   remove    disable and delete the unit; the pinned key stays for the next install
#   status    the unit's state and whether the socket exists; never key material
# Exit: 0 done, 1 a step failed, 2 usage.
set -euo pipefail

groot=$(cd "$(dirname "$0")/.." && pwd)
src="$groot/infrastructure/systemd/user"
unit=osionos-publish-socket.service
state="${XDG_STATE_HOME:-$HOME/.local/state}/osionos-publish" # S6: persistent, never /run/user
sockdir="$state/sock"
sock="$sockdir/kong.sock"
known_hosts="$state/known_hosts"
unitdir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
identity=${PUBLISH_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}
ssh_user=${PUBLISH_SSH_USER:-$(id -un)}

read_host_key() { # validate HOST_KEY_FILE (exit 2: unset, unreadable, wrong first field) and print "<type> <key>"
	local keytype='' keydata='' _
	[ -n "${HOST_KEY_FILE:-}" ] || {
		echo "[publish-socket] HOST_KEY_FILE is unset: the VM's ssh host public key line has to be pinned by the operator, over a trusted step" >&2
		exit 2
	}
	[ -r "$HOST_KEY_FILE" ] || {
		echo "[publish-socket] HOST_KEY_FILE=$HOST_KEY_FILE is not a readable file" >&2
		exit 2
	}
	read -r keytype keydata _ <"$HOST_KEY_FILE" || true
	case $keytype in
	ssh-ed25519 | ecdsa-sha2-nistp256 | ssh-rsa) ;;
	*)
		echo "[publish-socket] HOST_KEY_FILE's first field must be ssh-ed25519, ecdsa-sha2-nistp256 or ssh-rsa (got '${keytype:-nothing}')" >&2
		exit 2
		;;
	esac
	[ -n "$keydata" ] || {
		echo "[publish-socket] HOST_KEY_FILE has a key type but no key" >&2
		exit 2
	}
	printf '%s %s\n' "$keytype" "$keydata"
}

render_unit() { # substitute this machine's paths into the template (| never appears in them)
	mkdir -p "$unitdir"
	sed -e "s|@IDENTITY@|$identity|g" \
		-e "s|@KNOWN_HOSTS@|$known_hosts|g" \
		-e "s|@SOCKET_DIR@|$sockdir|g" \
		-e "s|@SSH_USER@|$ssh_user|g" \
		"$src/$unit.in" >"$unitdir/$unit"
}

install_unit() {
	local pinned
	pinned=$(read_host_key)
	if [ "${#sock}" -gt 100 ]; then
		echo "[publish-socket] $sock is longer than 100 bytes: a unix socket path has to fit 108" >&2
		exit 1
	fi
	mkdir -p "$sockdir"
	chmod 700 "$state" "$sockdir"
	printf 'b2b-publish %s\n' "$pinned" >"$known_hosts"
	chmod 600 "$known_hosts"
	[ -f "$identity" ] || {
		echo "[publish-socket] no identity file at $identity (PUBLISH_SSH_IDENTITY=<file>)" >&2
		exit 1
	}
	render_unit
	systemctl --user daemon-reload
	systemctl --user enable --now "$unit"
	echo "[publish-socket] on: OSIONOS_PUBLISH_SOCKET_DIR=$sockdir (the bridge forwards through $sock)"
}

remove_unit() {
	systemctl --user disable --now "$unit" >/dev/null 2>&1 || true # "not loaded" is fine here
	rm -f "$unitdir/$unit"
	systemctl --user daemon-reload
	rm -f "$sock"
	echo "[publish-socket] off; the unit is gone, the pinned key stays ($known_hosts)"
}

print_status() {
	local active
	active=$(systemctl --user is-active "$unit" 2>/dev/null) || true
	echo "[publish-socket] unit: ${active:-unknown}"
	if [ -e "$sock" ]; then
		echo "[publish-socket] socket: $sock exists"
	else
		echo "[publish-socket] socket: $sock missing"
	fi
}

case "${1:-}" in
install) install_unit ;;
remove) remove_unit ;;
status) print_status ;;
-h | --help) sed -n '2,15p' "$0" ;;
*)
	sed -n '2,15p' "$0" >&2
	exit 2
	;;
esac
