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
# Make the IDE sandbox egress NAT survive reboots. Run once: sudo sh install-egress-nat.sh
#
# ide-egress-nat.sh was installed "separately" and nothing reloaded it, so the first reboot
# silently removed the rules. docker-ide runs with --iptables=false, so without them the
# egress proxy has no route out at all: measured after a reboot, a container on
# osio-ide-egress-net could reach neither 1.1.1.1 nor anything private. Safe, but the
# allowlisted git host was unreachable and the corpus gate could not pass.
#
# The rules now load with the daemon, from a ROOT-OWNED copy of the script. The unit must
# never execute the file inside the repository: that file is writable by the developer, and
# a root service running it would turn "can edit the repo" into "is root".
#
# `ExecStartPost=-` (leading dash): a NAT failure must not take the isolated daemon down with
# it; the corpus gate (verify.sh) is what proves the rules are really in place.
set -eu

UNIT_DIR=/etc/systemd/system/docker-ide.service.d
TARGET=/usr/local/sbin/osionos-ide-egress-nat

main() {
	[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
	src="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/ide-egress-nat.sh"
	[ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
	install -o root -g root -m 0755 "$src" "$TARGET"
	install -d -o root -g root -m 0755 "$UNIT_DIR"
	cat >"$UNIT_DIR/egress-nat.conf" <<-EOF
	[Service]
	ExecStartPost=-$TARGET up
	ExecStopPost=-$TARGET down
	EOF
	chmod 0644 "$UNIT_DIR/egress-nat.conf"
	systemctl daemon-reload
	"$TARGET" up
	echo "installed: $TARGET (root-owned) + $UNIT_DIR/egress-nat.conf; rules loaded now and on every docker-ide start"
}

main "$@"
