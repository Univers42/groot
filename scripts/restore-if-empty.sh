#!/usr/bin/env sh
# restore-if-empty.sh — load the all-engine data snapshot when the stack is genuinely
# fresh: every RUNNING primary engine (postgres osionos, mysql ops, mongo activity) is
# CONFIRMED empty. FAIL-SAFE: an engine with data aborts the restore — it never wipes a
# populated stack. grobase `up` is DETACHED (no --wait), so on a fresh machine the engines
# are still booting when we arrive; we WAIT for docker health first, otherwise a transient
# "not ready" is misread as "uncertain" and the restore is WRONGLY skipped (the bug that
# left a fresh machine with no data). A populated engine is healthy at once, so the no-wipe
# path is never delayed. Wired into `make all` (and `make bootstrap`).
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RESTORE="$REPO/apps/grobase/data-snapshots/restore-databases.sh"

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
note()    { printf '[restore-if-empty] %s\n' "$1" >&2; }
numeric() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# wait_healthy <container>: block until docker reports the engine healthy, or give up after
# ~180s. An engine with no healthcheck returns at once (nothing to wait on).
wait_healthy() {
	c="$1"
	running "$c" || return 0
	i=0
	while [ "$i" -lt 90 ]; do
		st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo none)
		case "$st" in healthy | none) return 0 ;; esac
		i=$((i + 1))
		sleep 2
	done
	note "$c still not healthy after 180s — probe may read it as uncertain"
}

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
	pw=$(docker exec mini-baas-postgres printenv POSTGRES_PASSWORD 2>/dev/null)
	c=$(docker exec -e PGPASSWORD="$pw" mini-baas-postgres psql -U postgres -d postgres -tAc \
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

# Engines are still booting after a detached `up` — wait for health before probing/restoring.
for e in mini-baas-postgres mini-baas-mysql mini-baas-mongo mini-baas-mssql mini-baas-minio; do
	wait_healthy "$e"
done

# DEBUG (temporary): surface why postgres reads as unreadable in CI.
note "DEBUG pg health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' mini-baas-postgres 2>/dev/null)"
note "DEBUG pg_isready=[$(docker exec mini-baas-postgres pg_isready -U postgres -d postgres 2>&1 | head -1)]"
note "DEBUG pg SELECT1=[$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc 'SELECT 1' 2>&1 | head -2 | tr '\n' ' ')]"

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
