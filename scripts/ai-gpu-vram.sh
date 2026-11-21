#!/bin/sh
# gpu-vram.sh <container> — print "container_mib card_used_mib card_total_mib".
#
# The container figure is the container's own VRAM: drm-memory-vram of its
# processes' amdgpu fdinfo, one count per drm-client-id (FC4). The card figures
# are amdgpu's sysfs counters. It re-runs itself through `sudo -n` because a
# container's root-owned /proc/<pid>/fdinfo is unreadable to the user.
#
# Caveat: needs root (or passwordless sudo); a figure of 0 means "not readable"
# or "no amdgpu client", not "uses no VRAM". Reads only the container's own pid
# tree, so a child it spawns after the read is missed (under-reporting).
set -eu
[ "$(id -u)" -eq 0 ] || exec sudo -n sh "$(realpath "$0")" "$@"
c=${1:?container name}
dev=${GPU_SYSFS:-/sys/class/drm/card1/device}
pid=$(docker inspect -f '{{.State.Pid}}' "$c")
pids=$(pgrep -P "$pid" || true)
kib=$(for p in $pid $pids; do
	for f in /proc/"$p"/fdinfo/*; do
		grep -q '^drm-driver:.*amdgpu' "$f" 2>/dev/null || continue
		echo "$(sed -n 's/^drm-client-id:[[:space:]]*//p' "$f") $(sed -n 's/^drm-memory-vram:[[:space:]]*\([0-9]*\) KiB/\1/p' "$f")"
	done
done | sort -u -k1,1 | awk '{s+=$2} END{print s+0}')
echo "$((kib / 1024)) $(($(cat "$dev/mem_info_vram_used") / 1048576)) $(($(cat "$dev/mem_info_vram_total") / 1048576))"
