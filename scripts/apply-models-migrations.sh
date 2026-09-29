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
#      auth-gateway-users-reconcile-migration.sql was on this list and does NOT
#      belong to it: it is additive uuid-native DDL (five ADD COLUMN IF NOT
#      EXISTS on public.users, two unique indexes, one trigger) and applies with
#      exit 0 on a from-scratch database. See ORDERING below.
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
# ORDERING
#   Everything else applies in plain alphabetical glob order EXCEPT the six
#   files below, which must run first and in this exact sequence — each is a
#   real cross-file dependency (a table/function another file's DDL requires
#   at run time, not merely IF NOT EXISTS-shaped), so alphabetical order alone
#   is not idempotent w.r.t. dependency order. Confirmed by applying the full
#   set to a from-scratch database (a fully-converged dev machine hides this —
#   every table already exists, so the true first-run order never gets
#   exercised there):
#     auth-gateway-users-reconcile-migration.sql adds public.users.username
#         (needed by osionos-people-directory-migration.sql, whose view selects
#         u.username / u.name). Nothing else in models/ or in grobase's own
#         scripts/migrations/postgresql/ ever adds that column, so while this
#         file was skipped the people-directory view could NEVER be created on
#         a fresh database — it only worked on this machine because the file
#         had been hand-applied here long ago. First, because it needs only
#         public.users + public.user_profiles, both from grobase migration
#         001_initial_schema.sql (applied by the pg-migrate init container).
#     osionos-bridge-migration.sql      creates osionos_pages, osionos_bridge_identities
#         (needed by osionos-admin-migration.sql, osionos-page-search-migration.sql)
#     osionos-chat-migration.sql        creates osionos_channels, osionos_messages,
#         osionos_channel_members (needed by osionos-engagement-migration.sql)
#     osionos-social-migration.sql      adds osionos_bridge_identities.username
#         (needed by osionos-people-directory-migration.sql; its own header
#         declares the bridge + chat dependency, hence this position)
#     osionos-engagement-migration.sql  creates osionos_notifications
#         (needed by osionos-comments-migration.sql)
#     osionos-page-search-migration.sql defines public.osionos_page_blocks()
#         (needed by osionos-page-links-migration.sql)
#   Ponytail: `pending()` below only detects a file's OWN missing CREATE TABLE
#   targets, never what it references — it cannot see this bug class, so a
#   regression here will NOT show as a `--check` gap on a converged database.
#   The only real detector is a full apply on a from-scratch database.
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

ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/models-mig.XXXXXX")"
trap 'rm -f "${ERR_FILE}"' EXIT

# Dependency order (see "ORDERING" above) — each must run before the plain
# alphabetical pass reaches its dependent. Space-separated: no filename here
# contains a space or glob character.
ORDERED_FIRST="auth-gateway-users-reconcile-migration.sql osionos-bridge-migration.sql osionos-chat-migration.sql osionos-social-migration.sql osionos-engagement-migration.sql osionos-page-search-migration.sql"

note() { printf '[models] %s\n' "$*" >&2; }

skipped() {
	case "$1" in
	gdpr-migration.sql | user.sql | auth-security-migration.sql)
		return 0
		;;
	rls-hardening-migration.sql | seeds.sql)
		return 0
		;;
	osionos-folder-surface-migration.sql | osionos-wiki-surface-migration.sql)
		return 0
		;;
	esac
	return 1
}

is_ordered() {
	case " ${ORDERED_FIRST} " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

psql_in() {
	docker exec -i "${PG_CTN}" psql -U postgres -d "${PG_DB}" -v ON_ERROR_STOP=1
}

# The first ERROR line in a captured stderr file, or its last non-empty line
# when psql failed without printing one (e.g. a dropped connection), or the
# literal exit code when stderr is empty. NOTICEs print before a fatal ERROR
# in the same stream, so `head -1` (the previous behavior) reported the
# harmless NOTICE and hid the real failure — this greps for ERROR instead.
first_error() {
	line="$(grep -m1 'ERROR:' "$1" 2>/dev/null || true)"
	[ -n "${line}" ] && {
		printf '%s\n' "${line}"; return
	}
	line="$(awk 'NF{l=$0} END{print l}' "$1" 2>/dev/null || true)"
	[ -n "${line}" ] && {
		printf '%s\n' "${line}"; return
	}
	printf 'psql exited %s with no stderr output\n' "$2"
}

# A file is "pending" when any table it CREATEs is absent. Column/index gaps
# hide behind existing tables, so --check is a floor, not a full diff; apply
# mode runs every file regardless (IF NOT EXISTS makes that free). It also
# cannot see a cross-file dependency gap (see "ORDERING" above) — it only
# inspects what a file creates, never what it references.
pending() {
	awk 'BEGIN{IGNORECASE=1}
		match($0, /create table (if not exists )?(public\.)?[a-z_]+/) {
			t = substr($0, RSTART, RLENGTH)
			sub(/.* /, "", t); sub(/public\./, "", t); print t
		}' "$1" | sort -u | while IFS= read -r t; do
		[ -n "${t}" ] || continue
		hit="$(docker exec "${PG_CTN}" psql -U postgres -d "${PG_DB}" -tAc \
			"SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='${t}' LIMIT 1" 2>/dev/null)"
		[ "${hit}" = "1" ] || {
			echo "${t}"; return 0
		}
	done
}

apply_one() {
	f="$1"
	base="$(basename "${f}")"
	miss="$(pending "${f}")"
	if psql_in <"${f}" >/dev/null 2>"${ERR_FILE}"; then
		if [ -n "${miss}" ]; then
			note "applied: ${base}"
			applied=$((applied + 1))
		fi
	else
		rc=$?
		note "FAILED: ${base} — $(first_error "${ERR_FILE}" "${rc}")"
		failed=$((failed + 1))
	fi
	return 0
}

main() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"; exit 1
	}
	docker ps --format '{{.Names}}' | grep -qx "${PG_CTN}" || {
		note "${PG_CTN} not running — skipping"; exit 0
	}
	[ -d "${MODELS_DIR}" ] || {
		note "no ${MODELS_DIR} — skipping"; exit 0
	}

	if [ "${CHECK_ONLY}" -eq 1 ]; then
		gaps=0
		for f in "${MODELS_DIR}"/*.sql; do
			[ -f "${f}" ] || continue
			base="$(basename "${f}")"
			skipped "${base}" && continue
			miss="$(pending "${f}")"
			if [ -n "${miss}" ]; then
				note "pending: ${base} (missing table: ${miss})"
				gaps=$((gaps + 1))
			fi
		done
		if [ "${gaps}" -gt 0 ]; then
			note "${gaps} migration(s) pending — run: make models-migrate"
			exit 1
		fi
		note "converged — no pending models migrations"
		exit 0
	fi

	applied=0 failed=0

	for base in ${ORDERED_FIRST}; do
		f="${MODELS_DIR}/${base}"
		if [ ! -f "${f}" ]; then
			note "FAILED: ${base} listed in ORDERED_FIRST but not found in ${MODELS_DIR}"
			failed=$((failed + 1))
			continue
		fi
		apply_one "${f}"
	done

	for f in "${MODELS_DIR}"/*.sql; do
		[ -f "${f}" ] || continue
		base="$(basename "${f}")"
		skipped "${base}" && continue
		is_ordered "${base}" && continue
		apply_one "${f}"
	done

	note "done — ${applied} newly applied, ${failed} failed, rest converged"
	[ "${failed}" -eq 0 ] || exit 1
}

main "$@"
