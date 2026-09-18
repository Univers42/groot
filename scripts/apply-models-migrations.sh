#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    apply-models-migrations.sh                                                #
#                                                                              #
#    Apply every models/*.sql migration that targets the grobase postgres      #
#    public schema. Idempotent — every file is IF NOT EXISTS-shaped, so a      #
#    converged database is a fast no-op.                                       #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   models/ held 20+ hand-applied migrations with NO runner. On this machine
#   eleven of them had never been applied, and the failures they caused were
#   maximally misleading:
#     - osionos_pages.cover_position missing → every page PATCH carrying
#       coverPosition failed 502 (PGRST204) → the page-sync outbox marked it
#       "failed" and, by design, STOPPED THE WHOLE BATCH → no page, workspace
#       or content edit persisted at all, and a reload wiped everything back
#       to the server's empty copies.
#     - osionos_page_links / _favorites / _tasks / _comments … missing → 404s
#       across backlinks, favorites, tasks, comments.
#   Nothing in the repo reapplies these on a fresh database, so the breakage
#   returns on every new machine. This script closes that hole; `make all`
#   runs it via the models-migrate target.
#
# WHAT IT DELIBERATELY SKIPS
#   1. Files whose DDL references the auth-gateway's INTEGER users.id — they
#      target the auth gateway's own database, and applying them here fails on
#      a uuid/integer foreign-key clash (measured, not assumed):
#        gdpr-migration.sql  user.sql  auth-security-migration.sql
#        auth-gateway-users-reconcile-migration.sql
#   2. Files expecting a users table shaped with username/avatar_url columns
#      this database's public.users does not have (same foreign-DB family):
#        rls-hardening-migration.sql  seeds.sql
#   3. SUPERSEDED surface-constraint steps. folder-surface and wiki-surface
#      each DROP + re-ADD osionos_pages_surface_check with a list NARROWER
#      than live data ('app' rows exist), so replaying them either fails or
#      — worse, in alphabetical order after code-surface — drops the
#      constraint and leaves the table unconstrained. code-surface is the
#      authoritative latest (its header documents the chain) and is the only
#      surface migration this runner applies:
#        osionos-folder-surface-migration.sql  osionos-wiki-surface-migration.sql
#
# Usage:  sh scripts/apply-models-migrations.sh [--check]
#           --check  report unapplied DDL and exit non-zero; change nothing.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${MODELS_DIR:-${REPO_ROOT}/models}"
PG_CTN="${PG_CONTAINER:-mini-baas-postgres}"
PG_DB="${PG_DB:-postgres}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

note() { printf '[models] %s\n' "$*" >&2; }

skipped() {
	case "$1" in
	gdpr-migration.sql|user.sql|auth-security-migration.sql|auth-gateway-users-reconcile-migration.sql)
		return 0 ;;
	rls-hardening-migration.sql|seeds.sql)
		return 0 ;;
	osionos-folder-surface-migration.sql|osionos-wiki-surface-migration.sql)
		return 0 ;;
	esac
	return 1
}

psql_in() {
	docker exec -i "${PG_CTN}" psql -U postgres -d "${PG_DB}" -v ON_ERROR_STOP=1
}

# A file is "pending" when any table it CREATEs is absent. Column/index gaps
# hide behind existing tables, so --check is a floor, not a full diff; apply
# mode runs every file regardless (IF NOT EXISTS makes that free).
pending() {
	awk 'BEGIN{IGNORECASE=1}
		match($0, /create table (if not exists )?(public\.)?[a-z_]+/) {
			t = substr($0, RSTART, RLENGTH)
			sub(/.* /, "", t); sub(/public\./, "", t); print t
		}' "$1" | sort -u | while IFS= read -r t; do
		[ -n "${t}" ] || continue
		hit="$(docker exec "${PG_CTN}" psql -U postgres -d "${PG_DB}" -tAc \
			"SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='${t}' LIMIT 1" 2>/dev/null)"
		[ "${hit}" = "1" ] || { echo "${t}"; return 0; }
	done
}

main() {
	command -v docker >/dev/null 2>&1 || { note "docker is required"; exit 1; }
	docker ps --format '{{.Names}}' | grep -qx "${PG_CTN}" || { note "${PG_CTN} not running — skipping"; exit 0; }
	[ -d "${MODELS_DIR}" ] || { note "no ${MODELS_DIR} — skipping"; exit 0; }

	gaps=0 applied=0 failed=0
	for f in "${MODELS_DIR}"/*.sql; do
		[ -f "${f}" ] || continue
		base="$(basename "${f}")"
		if skipped "${base}"; then continue; fi
		miss="$(pending "${f}")"
		if [ "${CHECK_ONLY}" -eq 1 ]; then
			if [ -n "${miss}" ]; then
				note "pending: ${base} (missing table: ${miss})"
				gaps=$((gaps + 1))
			fi
			continue
		fi
		if psql_in < "${f}" >/dev/null 2>/tmp/models-mig.err; then
			[ -n "${miss}" ] && { note "applied: ${base}"; applied=$((applied + 1)); }
		else
			note "FAILED: ${base} — $(head -1 /tmp/models-mig.err)"
			failed=$((failed + 1))
		fi
	done
	rm -f /tmp/models-mig.err

	if [ "${CHECK_ONLY}" -eq 1 ]; then
		if [ "${gaps}" -gt 0 ]; then
			note "${gaps} migration(s) pending — run: make models-migrate"
			exit 1
		fi
		note "converged — no pending models migrations"
		exit 0
	fi
	note "done — ${applied} newly applied, ${failed} failed, rest converged"
	[ "${failed}" -eq 0 ] || exit 1
}

main "$@"
