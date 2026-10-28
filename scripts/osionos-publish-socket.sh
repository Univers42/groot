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

read_host_key() { # validate HOST_KEY_FILE (exit 2: unset, unreadable, not exactly one valid key) and print "<type> <key>"
	local keytype='' keydata='' _
	[[ -n "${HOST_KEY_FILE:-}" ]] || {
		echo "[publish-socket] HOST_KEY_FILE is unset: the VM's ssh host public key line has to be pinned by the operator, over a trusted step" >&2
		exit 2
	}
	[[ -r "$HOST_KEY_FILE" ]] || {
		echo "[publish-socket] HOST_KEY_FILE=$HOST_KEY_FILE is not a readable file" >&2
		exit 2
	}
	if [[ "$(grep -c '[^[:space:]]' "$HOST_KEY_FILE")" -ne 1 ]]; then
		echo "[publish-socket] HOST_KEY_FILE must hold exactly one host key line" >&2
		exit 2
	fi
	read -r keytype keydata _ < <(grep '[^[:space:]]' "$HOST_KEY_FILE") || true
	case $keytype in
	ssh-ed25519 | ecdsa-sha2-nistp256 | ssh-rsa) ;;
	*)
		echo "[publish-socket] HOST_KEY_FILE's first field must be ssh-ed25519, ecdsa-sha2-nistp256 or ssh-rsa (got '${keytype:-nothing}')" >&2
		exit 2
		;;
	esac
	[[ -n "$keydata" ]] || {
		echo "[publish-socket] HOST_KEY_FILE has a key type but no key" >&2
		exit 2
	}
	ssh-keygen -l -f "$HOST_KEY_FILE" >/dev/null 2>&1 || {
		echo "[publish-socket] HOST_KEY_FILE is not a valid public key (ssh-keygen -l refused it)" >&2
		exit 2
	}
	printf '%s %s\n' "$keytype" "$keydata"
}

# Everything rendered into ExecStart is one unquoted word: a space would split it, `%` is a systemd
# specifier, `&` and `|` are sed metacharacters, a leading `-` would be an ssh option. Refusing them
# is simpler than escaping for three parsers at once.
require_plain() { # exit 2 unless every value is a plain absolute path / user name
	local value
	for value in "$identity" "$known_hosts" "$sockdir"; do
		[[ $value =~ ^/[A-Za-z0-9._/@+-]+$ ]] || {
			echo "[publish-socket] '$value' has a character the unit cannot carry (allowed: A-Z a-z 0-9 . _ / @ + -)" >&2
			exit 2
		}
	done
	[[ $ssh_user =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || {
		echo "[publish-socket] PUBLISH_SSH_USER '$ssh_user' is not a plain user name" >&2
		exit 2
	}
}

render_unit() { # substitute this machine's paths into the template (require_plain ran first)
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
	require_plain
	# bytes, not characters: a multibyte XDG_STATE_HOME is longer than ${#sock} says
	if [[ "$(printf %s "$sock" | wc -c)" -gt 100 ]]; then
		echo "[publish-socket] $sock is longer than 100 bytes: a unix socket path has to fit 108" >&2
		exit 1
	fi
	mkdir -p "$sockdir"
	chmod 700 "$state" "$sockdir"
	printf 'b2b-publish %s\n' "$pinned" >"$known_hosts"
	chmod 600 "$known_hosts"
	[[ -f "$identity" ]] || {
		echo "[publish-socket] no identity file at $identity (PUBLISH_SSH_IDENTITY=<file>)" >&2
		exit 1
	}
	render_unit
	systemctl --user daemon-reload
	systemctl --user enable --now "$unit"
	echo "[publish-socket] on: OSIONOS_PUBLISH_SOCKET_DIR=$sockdir (the bridge forwards through $sock)"
}

remove_unit() {
	# only an absent unit is skipped: any other disable/stop failure must not report "off"
	if [[ -e "$unitdir/$unit" ]]; then
		systemctl --user disable --now "$unit" >/dev/null
	fi
	rm -f "$unitdir/$unit"
	systemctl --user daemon-reload
	rm -f "$sock"
	echo "[publish-socket] off; the unit is gone, the pinned key stays ($known_hosts)"
}

print_status() {
	local active
	active=$(systemctl --user is-active "$unit" 2>/dev/null) || true
	echo "[publish-socket] unit: ${active:-unknown}"
	if [[ -e "$sock" ]]; then
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
