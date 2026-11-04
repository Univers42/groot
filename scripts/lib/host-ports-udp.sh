# shellcheck shell=bash
# host-ports-udp.sh — LiveKit's media range. 50000-50060 sits inside Linux's ephemeral range
# (32768-60999), so anything on the host can hold one of those ports, and one busy port stops
# the whole container from starting (measured 2026-11-04, a socket on 50016 failed make all).
# The range stays where production has it unless it is busy: nothing is recorded then, so
# .env.ports and the running stack keep today's values. Sourced by scripts/host-ports.sh.
#
# Caveat: ss sees only what is bound now, so a program can take a port between this check and
# `docker compose up`, and that up fails (under-reports); make all again picks another range.
# Caveat: a moved range only reaches a browser that can use it. The browser on this machine can,
# and LiveKit's TCP fallback on 7881 covers one that cannot.

udp_listeners() {
  bash -c "${HOST_PORTS_UDP_LISTENERS:-ss -Hlun}" 2>/dev/null | awk 'NF >= 4 { n = split($4, a, ":"); print a[n] }' || true
}

# udp_range_busy FIRST BUSY — 0 when a port of the 61 from FIRST is in BUSY.
udp_range_busy() {
  awk -v a="$1" -v b="$(($1 + 60))" '$1 >= a && $1 <= b { found = 1 } END { exit !found }' <<<"$2"
}

# free_udp_range — prints the range to record: the one already recorded while it is free, because
# a moved range stays put and a new one recreates LiveKit and drops every call; else nothing when
# the default is free; else the first free range above it. Uses OWN_PORTS, so a running LiveKit
# does not walk away from itself.
free_udp_range() {
  local busy first recorded=${previous[LIVEKIT_UDP_PORTS]:-}
  busy=$(udp_listeners | grep -vxF -f <(printf '%s\n' "${OWN_PORTS:-none}") || true)
  if [ -n "$recorded" ] && ! udp_range_busy "${recorded%%-*}" "$busy"; then
    printf '%s\n' "$recorded"
    return 0
  fi
  for first in 50000 50100 50200 50300 50400; do
    if ! udp_range_busy "$first" "$busy"; then
      [ "$first" = 50000 ] || {
        printf 'host-ports: LiveKit media range 50000-50060 is busy; using %s-%s\n' "$first" "$((first + 60))" >&2
        printf '%s-%s\n' "$first" "$((first + 60))"
      }
      return 0
    fi
  done
  printf 'host-ports: no free LiveKit media range in 50000-50460; video rooms use the TCP fallback\n' >&2
}
