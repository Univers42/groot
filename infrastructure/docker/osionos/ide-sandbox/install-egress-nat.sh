#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    install-egress-nat.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/09/16 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/09/16 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Make the IDE sandbox egress firewall survive reboots, and make docker-ide refuse to start
# without it. Run once: sudo sh install-egress-nat.sh      (print: show the drop-in, no root)
#
# ide-egress-nat.sh was installed "separately" and nothing reloaded it, so the first reboot
# silently removed the rules. docker-ide runs with --iptables=false, so these rules are the
# only filter on its 10.202.0.0/16 pool: without them a box can reach the VM's own services.
#
# The rules load from a ROOT-OWNED copy of the script. The unit must never execute the file
# inside the repository: that file is writable by the developer, and a root service running
# it would turn "can edit the repo" into "is root".
#
# FAIL CLOSED: `ExecStartPre=` with no leading dash. If `up` fails, dockerd never starts and
# no box runs unfiltered. The earlier `ExecStartPost=-` failed open (a failed `up` left the
# daemon serving) and `ExecStopPost=-` ... `down` removed the rules on every stop. Measured on
# systemd 249 (devil ruling SEC3, 2026-10-19):
#   - ExecStopPost runs after a failed start, and also after dockerd dies abruptly. Boxes
#     live in osionos-ide.slice under the system containerd, not in this unit's cgroup, so
#     they outlive dockerd and `down` would strip the firewall from under them.
#   - Restart=on-failure with RestartSec=3 retries a failed start forever: at most 4 starts
#     fit in 10 s, so the default 5-in-10 s start limit is never reached. With Pre the loop
#     is a ~50 ms script every 3 s; with Post it was a dockerd start/stop on the prod VM.
#   - docker-ide.socket keeps its inode across that loop, so the socket proxy's bind-mount
#     stays valid and recovery needs no recreate.
# `up` needs nothing dockerd creates: it matches addresses, and the bridge by name as a
# runtime string (`meta ibrname`), so it may run before the bridge exists (bootstrap.sh).
# `down` is not wired to stop: it stays a manual step for uninstall only.
#
# Does NOT cover rules removed while the daemon runs (`iptables -F`, `nft flush ruleset`, a
# firewall reload): only `ide-egress-nat.sh check` and verify.sh find those.
set -eu

UNIT_DIR=/etc/systemd/system/docker-ide.service.d
TARGET=/usr/local/sbin/osionos-ide-egress-nat

# Drop-in text; a function so `print` and the install write the same bytes.
dropin() {
	printf '[Service]\nExecStartPre=%s up\n' "$TARGET"
}

main() {
	if [ "${1:-}" = print ]; then dropin; return 0; fi
	[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
	src="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/ide-egress-nat.sh"
	[ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
	install -o root -g root -m 0755 "$src" "$TARGET"
	install -d -o root -g root -m 0755 "$UNIT_DIR"
	dropin >"$UNIT_DIR/egress-nat.conf"
	chmod 0644 "$UNIT_DIR/egress-nat.conf"
	systemctl daemon-reload
	"$TARGET" up
	echo "installed: $TARGET (root-owned) + $UNIT_DIR/egress-nat.conf; rules loaded now and before every docker-ide start"
}

main "$@"
