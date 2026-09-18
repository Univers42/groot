#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    perf-snapshot.sh                                                          #
#                                                                              #
#    One reproducible performance snapshot of the guest + the running stack.   #
#    Before/after comparisons MUST use this script, not hand-typed commands,   #
#    so the two halves are measured identically.                               #
#                                                                              #
# **************************************************************************** #
#
# This VM's profile is lopsided and normal instincts mislead: CPU is native
# (KVM -cpu host, AES-NI), disk is emulated AHCI with ~2.25 ms fsync, and
# networking is QEMU slirp at ~1.45 MB/s. The correct trade here is always to
# SPEND CPU TO AVOID I/O. The metrics below are chosen to show that axis:
# fsync latency and PSI io for the slow half, fork rate and swap for the
# self-inflicted half.
#
# Usage:  sh scripts/perf-snapshot.sh [label]
# Read-only: measures, never tunes. Safe to run at any time.

set -eu

LABEL="${1:-snapshot}"
SAMPLES="${SAMPLES:-20}"
FORK_WINDOW="${FORK_WINDOW:-10}"
PORTS="${PORTS:-3001 4322 8787 8444 4000}"

hr() { printf '%s\n' '---------------------------------------------------------------'; }

# p50/p95 of N HTTPS requests to one port. Latency is what the USER feels; the
# box being idle proves nothing on its own.
port_latency() {
	port="$1"
	i=0
	while [ "$i" -lt "$SAMPLES" ]; do
		curl -sk -o /dev/null -w '%{time_total}\n' --max-time 10 \
			"https://localhost:${port}/" 2>/dev/null || echo 9.999
		i=$((i + 1))
	done | sort -n | awk -v p="${port}" '
		{ v[NR] = $1 }
		END {
			if (NR == 0) { printf "  %-6s no samples\n", p; exit }
			p50 = v[int(NR * 0.50) + (NR % 2 == 0 ? 0 : 1)]
			p95 = v[int(NR * 0.95)]; if (p95 == "") p95 = v[NR]
			printf "  %-6s p50=%.4fs  p95=%.4fs  min=%.4fs  max=%.4fs\n", p, p50, p95, v[1], v[NR]
		}'
}

# Fork rate quantifies the healthcheck storm: every container healthcheck is a
# process exec, forever. A high steady-state rate on an IDLE box is the signal.
fork_rate() {
	before="$(awk '/^processes/ {print $2}' /proc/stat)"
	sleep "${FORK_WINDOW}"
	after="$(awk '/^processes/ {print $2}' /proc/stat)"
	awk -v a="${before}" -v b="${after}" -v w="${FORK_WINDOW}" \
		'BEGIN { printf "  %.1f forks/sec over %ds (%d total)\n", (b - a) / w, w, b - a }'
}

# fsync latency — the tax every commit, npm install and container log write pays.
fsync_latency() {
	tmp="$(mktemp -d)"
	trap 'rm -rf "${tmp}"' EXIT
	out="$(cd "${tmp}" && dd if=/dev/zero of=.lat bs=4k count=200 oflag=dsync 2>&1)"
	printf '%s' "${out}" | awk '
		/copied|s,/ {
			for (i = 1; i <= NF; i++) if ($i == "s," || $i == "s") { t = $(i-1); break }
		}
		END { if (t > 0) printf "  %.3f s / 200 = %.2f ms per fsync\n", t, (t * 1000) / 200
		      else print "  (could not parse dd output)" }'
	rm -rf "${tmp}"
	trap - EXIT
}

main() {
	printf '=== perf snapshot: %s ===\n' "${LABEL}"
	printf 'date: %s\n' "$(date -Is)"
	hr

	printf 'fsync latency\n'
	fsync_latency

	printf 'pressure (PSI)\n'
	printf '  cpu : %s\n' "$(head -1 /proc/pressure/cpu)"
	printf '  io  : %s\n' "$(head -1 /proc/pressure/io)"
	printf '  mem : %s\n' "$(head -1 /proc/pressure/memory)"

	printf 'memory\n'
	free -m | awk '/^Mem:/ {printf "  ram   total=%sM used=%sM free=%sM avail=%sM\n", $2, $3, $4, $7}
	                /^Swap:/ {printf "  swap  total=%sM used=%sM free=%sM\n", $2, $3, $4}'
	printf '  swappiness=%s\n' "$(cat /proc/sys/vm/swappiness)"

	printf 'load + fork rate\n'
	printf '  loadavg %s\n' "$(awk '{print $1, $2, $3}' /proc/loadavg)"
	fork_rate

	printf 'disk\n'
	df -h /var | awk 'NR==2 {printf "  /var  %s used of %s (%s)\n", $3, $2, $5}'
	printf '  rotational=%s scheduler=%s read_ahead_kb=%s nr_requests=%s\n' \
		"$(cat /sys/block/sda/queue/rotational 2>/dev/null || echo '?')" \
		"$(sed 's/.*\[\(.*\)\].*/\1/' /sys/block/sda/queue/scheduler 2>/dev/null || echo '?')" \
		"$(cat /sys/block/sda/queue/read_ahead_kb 2>/dev/null || echo '?')" \
		"$(cat /sys/block/sda/queue/nr_requests 2>/dev/null || echo '?')"

	printf 'containers\n'
	printf '  running=%s\n' "$(docker ps -q 2>/dev/null | wc -l)"

	printf 'app latency (%s samples each)\n' "${SAMPLES}"
	for p in ${PORTS}; do port_latency "${p}"; done

	hr
}

main "$@"
