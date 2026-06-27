#!/usr/bin/env sh
# restore-if-empty.sh — load the all-engine data snapshot ONLY when the stack is
# genuinely fresh: every RUNNING primary engine (postgres osionos, mysql ops, mongo
# activity) is CONFIRMED empty. FAIL-SAFE: any engine with data, or any uncertainty
# (unreachable / query error), aborts the restore — it never wipes a populated stack.
# Engines that aren't running are ignored (restore-databases.sh only touches running
# ones, and the backend guard already ensured the core stack is up). Wired into
# `make all` (and `make bootstrap`).
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RESTORE="$REPO/apps/grobase/data-snapshots/restore-databases.sh"

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
note()    { printf '[restore-if-empty] %s\n' "$1" >&2; }
numeric() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

EMPTY=1
REASON=""

# gate <engine> <count|?>: a data-bearing or unreadable engine means "not fresh".
gate() {
	[ "$EMPTY" = 1 ] || return 0
	case "$2" in
		0) : ;;
		'?') EMPTY=0; REASON="$1 unreadable" ;;
		*) if numeric "$2" && [ "$2" -gt 0 ]; then EMPTY=0; REASON="$1 has data ($2)"; fi ;;
	esac
}

pg_probe() {
	running mini-baas-postgres || return 0
	docker exec mini-baas-postgres pg_isready -U postgres -q 2>/dev/null || { gate postgres '?'; return 0; }
	c=$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc \
		"SELECT CASE WHEN to_regclass('public.osionos_pages') IS NULL THEN 0 ELSE (SELECT count(*) FROM osionos_pages) END" \
		2>/dev/null | tr -d '[:space:]')
	numeric "$c" || c='?'
	gate postgres "$c"
}

mysql_probe() {
	running mini-baas-mysql || return 0
	pw=$(docker exec mini-baas-mysql printenv MYSQL_ROOT_PASSWORD 2>/dev/null)
	[ -n "$pw" ] || { gate mysql '?'; return 0; }
	c=$(docker exec mini-baas-mysql mysql -uroot -p"$pw" -N -e \
		"SELECT count(*) FROM information_schema.tables WHERE table_schema='ops'" 2>/dev/null | tr -d '[:space:]')
	numeric "$c" || c='?'
	gate mysql "$c"
}

mongo_probe() {
	running mini-baas-mongo || return 0
	mu=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_USERNAME 2>/dev/null)
	mp=$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_PASSWORD 2>/dev/null)
	{ [ -n "$mu" ] && [ -n "$mp" ]; } || { gate mongo '?'; return 0; }
	c=$(docker exec mini-baas-mongo mongosh --quiet -u "$mu" -p "$mp" --authenticationDatabase admin \
		--eval 'db.getSiblingDB("activity").events.countDocuments()' 2>/dev/null | tr -d '[:space:]')
	numeric "$c" || c='?'
	gate mongo "$c"
}

pg_probe
mysql_probe
mongo_probe

if [ "$EMPTY" = 1 ]; then
	note "all running primary engines empty → restoring the full snapshot (all engines)…"
	CONFIRM=1 "$RESTORE"
	docker restart mini-baas-minio mini-baas-realtime >/dev/null 2>&1 || true
	note "restore complete."
else
	note "data present ($REASON) — skipping restore (no wipe)."
fi
