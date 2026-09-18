#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    var-guard.sh                                                              #
#                                                                              #
#    Keep /var from filling: when usage crosses the trigger threshold, free    #
#    space in SAFE tiers — Docker build cache first, then dangling images,     #
#    then unused images — and STOP at the first tier that gets usage back      #
#    under target. Never touches volumes, named data, or running containers.   #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   Docker on this VM (33+ containers, Playwright test images, BuildKit) fills
#   /var/lib/docker in bursts: two image builds in one session took /var from
#   70% to 100% and failed mid-build ("no space left on device") — twice in
#   one day, each time reclaimable cache, never real data. This guard runs the
#   same safe reclaim automatically before a build can hit the wall.
#
# WHAT IT WILL NEVER DO
#   - `docker system prune --volumes` or any volume removal (databases live
#     there: postgres/mysql/mongo/mssql data, pnpm stores).
#   - Remove images newer than MIN_IMAGE_AGE or in use by ANY container.
#   - Touch journald, apt, or anything needing root (docker group suffices).
#
# Usage:  sh scripts/var-guard.sh [--force]
#           --force  reclaim tiers regardless of current usage (manual runs).
# Cron:   */10 * * * *  sh <repo>/scripts/var-guard.sh >> ~/.local/state/var-guard.log 2>&1

set -eu

TRIGGER_PCT="${VAR_GUARD_TRIGGER:-95}"
TARGET_PCT="${VAR_GUARD_TARGET:-85}"
MIN_IMAGE_AGE="${VAR_GUARD_IMAGE_AGE:-2h}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

usage_pct() { df -P /var | awk 'NR==2 {gsub(/%/,"",$5); print $5}'; }
stamp() { date '+%Y-%m-%dT%H:%M:%S'; }
note() { printf '%s [var-guard] %s\n' "$(stamp)" "$*"; }

# Run one reclaim tier, log the delta, and report whether target is reached.
tier() {
	label="$1"; shift
	before="$(usage_pct)"
	"$@" >/dev/null 2>&1 || note "tier '${label}' errored (continuing)"
	after="$(usage_pct)"
	note "tier '${label}': ${before}% -> ${after}%"
	[ "${after}" -le "${TARGET_PCT}" ]
}

main() {
	command -v docker >/dev/null 2>&1 || { note "docker unavailable — nothing to do"; exit 0; }
	pct="$(usage_pct)"
	if [ "${FORCE}" -eq 0 ] && [ "${pct}" -lt "${TRIGGER_PCT}" ]; then
		exit 0
	fi
	note "/var at ${pct}% (trigger ${TRIGGER_PCT}%) — reclaiming toward ${TARGET_PCT}%"

	tier "buildkit cache"    docker builder prune -a -f && exit 0
	tier "dangling images"   docker image prune -f && exit 0
	tier "stopped containers" docker container prune -f --filter "until=24h" && exit 0
	tier "unused images >${MIN_IMAGE_AGE}" docker image prune -a -f --filter "until=${MIN_IMAGE_AGE}" && exit 0

	note "still $(usage_pct)% after every safe tier — manual attention needed (volumes are NOT touched by design)"
	exit 0
}

main "$@"
