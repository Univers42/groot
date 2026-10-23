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
#        gdpr-migration.sql  user.sql
#      auth-security-migration.sql WAS on this list and does NOT belong to it
#      any more: it reads the type of public.users.id from the catalog, so it
#      applies to this database's uuid users as well as to the integer users of
#      the databases that run user.sql. See ORDERING below.
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
#     osionos-page-links-migration.sql  creates osionos_page_links (needed by
#         osionos-ai-graph-migration.sql, whose edge read RETURNS SETOF it and
#         sorts before it)
#   The auth-security-migration.sql file is deliberately NOT one of those seven: it runs
#   in the plain alphabetical pass, after ORDERED_FIRST has reconciled public.users, and needs two things this database already has when the runner starts: public.users
#   (its auth_audit_events.user_id column takes whatever type public.users.id has, read
#   from the catalog) and the three roles anon, authenticated and service_role (its
#   grants). It creates its own table and function, so no other file in models/ depends
#   on it.
#   Ponytail: `pending()` below only detects a file's OWN missing CREATE TABLE
#   targets, never what it references — it cannot see this bug class, so a
#   regression here will NOT show as a `--check` gap on a converged database.
#   The only real detector is a full apply on a from-scratch database.
#
#   osionos-user-events-migration.sql (the ai_events log and its capture
#       triggers) is in the alphabetical pass and is NAMED so it sorts after the
#       engagement tables it captures from: osionos-chat-migration.sql
#       (osionos_feed_likes, osionos_feed_comments), osionos-comments-
#       migration.sql (osionos_page_comments), osionos-favorites-migration.sql
#       (osionos_page_favorites) and osionos-feed-engagement-migration.sql
#       (osionos_feed_reactions, osionos_feed_shares). It also reads
#       osionos_connections, which osionos-social-migration.sql creates — that
#       one is in ORDERED_FIRST, so it is applied before the alphabetical pass
#       whatever its name says. A trigger on a table that does not exist yet is
#       a hard error, so this order is a correctness fact, not a style choice:
#       it is the same trick osionos-membership-cutoff-migration.sql uses to
#       sort after auth-session-cutoffs.sql.
#       The file is NOT called osionos-ai-events-migration.sql: that name sorts
#       BEFORE the tables it needs, and the alphabetical pass is the only slot
#       both runners share (this one and the ledger runner
#       scripts/apply-models.sh, whose glob is the same). scripts/verify/
#       ai-events.sh reads this runner's own order and fails if the file does
#       not sort after the tables it captures from.
#
#   osionos-ugc-moderation-migration.sql (the soft moderation state, the
#       append-only moderation audit and the moderation queue) is in the
#       alphabetical pass and is NAMED so it sorts after the tables it reads
#       and triggers on: osionos-chat-migration.sql (osionos_feed_comments),
#       osionos-comments-migration.sql (osionos_page_comments) and
#       osionos-feed-engagement-migration.sql (osionos_feed_comments.parent_id
#       and its updated_at column). It also JOINs osionos_pages, which
#       osionos-bridge-migration.sql creates, and osionos_workspaces.visibility,
#       which osionos-social-migration.sql adds — both are in ORDERED_FIRST, so
#       they are applied before the alphabetical pass whatever their name says.
#       A trigger on a table that does not exist yet is a hard error, so this
#       order is a correctness fact, not a style choice: it is the same trick
#       osionos-user-events-migration.sql uses. The file is NOT called
#       osionos-ai-moderation-migration.sql: that name sorts BEFORE the tables
#       it needs, and the alphabetical pass is the only slot both runners
#       share. scripts/verify/moderation-state.sh reads this runner's own order
#       and fails if the file does not sort after them.
#
#   osionos-rec-factors-migration.sql (the recommender's model registry, its
#       zero-padded factor vectors, the guarded promotion and the erasure) is
#       in the alphabetical pass and sorts BEFORE
#       osionos-user-events-migration.sql ("r" < "u"). That order is fine
#       ONLY because the new file references NOTHING in the events file: it
#       creates its own three tables and its own three functions, and it
#       reads no ai_events table. The events file's ai_erase_user() resolves
#       ai_rec_erase_user() at CALL time (to_regprocedure(...) IS NOT NULL ->
#       EXECUTE), so the two files work in either order and each of them works
#       alone. The extension it needs (pgvector) is created by
#       osionos-social-migration.sql, which is in ORDERED_FIRST, so the
#       extension exists before the alphabetical pass whatever the name says.
#       The file says so in its own header.
#
#   osionos-rec-serving-migration.sql (the two reads that serve the champion:
#       a user's context for the fold-in, and the champion's nearest items
#       through the HNSW index) is in the alphabetical pass and sorts AFTER
#       osionos-rec-factors-migration.sql ("factors" < "serving"). That order
#       HOLDS, and it is a correctness fact, not a style choice: the query
#       behind ai_rec_nearest is a plain SQL function, and a SQL function's
#       body is VALIDATED when it is created, so the factor tables have to
#       exist when this file is applied. The alphabetical pass applies the
#       factors file first, so they do.
#
#       It sorts BEFORE osionos-user-events-migration.sql ("serving" <
#       "user"), and that order is fine ONLY because the events tables are
#       read from PL/pgSQL, which resolves a relation at CALL time and not at
#       creation time: ai_rec_user_context reads public.ai_events and
#       public.ai_personalization_settings when it is called, never when it is
#       created. The runner applies both files in the same boot, so the tables
#       are there before the first call. It is the same trick the events file
#       uses in reverse, where ai_erase_user() resolves ai_rec_erase_user() at
#       CALL time. The file says so in its own header, and
#       scripts/verify/rec-serving.sh proves it: it applies the serving file
#       twice on a database that has the factors file and NOT the events file.
#
#   osionos-service-role-only-migration.sql runs LAST (ORDERED_LAST), after
#   everything: it revokes what earlier files and older boots granted. Its
#   sweep matches the osionos\_% NAME PATTERN, so the ai\_% relations are
#   outside it: ai_events, ai_jobs, ai_rec_models, ai_rec_item_factors,
#   ai_rec_user_factors and the ai_rec_* serving functions close themselves
#   with their own REVOKE, in their own file, on every replay. There is
#   nothing to add to that file.
#   users-pii-grants-migration.sql runs after it, last of all: it fixes the
#   public.users column grants (no anon email, no password_hash for anyone).
#   apply-models.sh runs it last too, by name (GRANTS_LAST), not by glob collation.
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
ORDERED_FIRST="auth-gateway-users-reconcile-migration.sql osionos-bridge-migration.sql osionos-chat-migration.sql osionos-social-migration.sql osionos-engagement-migration.sql osionos-page-search-migration.sql osionos-page-links-migration.sql"
ORDERED_LAST="osionos-account-foundation-migration.sql osionos-account-profiles-migration.sql osionos-account-username-migration.sql osionos-account-profession-migration.sql osionos-account-readme-migration.sql osionos-publish-account-migration.sql osionos-personal-access-tokens-migration.sql osionos-self-data-indexes-migration.sql osionos-social-follow-presence-migration.sql osionos-mfa-migration.sql osionos-service-role-only-migration.sql realtime-cdc-off-migration.sql users-pii-grants-migration.sql"

note() { printf '[models] %s\n' "$*" >&2; }

skipped() {
	case "$1" in
	gdpr-migration.sql | user.sql)
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

is_ordered_last() {
	case " ${ORDERED_LAST} " in
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
		printf '%s\n' "${line}"
		return
	}
	line="$(awk 'NF{l=$0} END{print l}' "$1" 2>/dev/null || true)"
	[ -n "${line}" ] && {
		printf '%s\n' "${line}"
		return
	}
	printf 'psql exited %s with no stderr output\n' "$2"
}

# A file is "pending" when any table it CREATEs is absent. Column/index gaps
# hide behind existing tables, so --check is a floor, not a full diff; apply
# mode runs every file regardless (IF NOT EXISTS makes that free). It also
# cannot see a cross-file dependency gap (see "ORDERING" above) — it only
# inspects what a file creates, never what it references.
# The line is lowercased by hand: IGNORECASE is a gawk extension, and under
# mawk (Debian's awk) an upper-case CREATE TABLE was never matched, so baas
# reported "converged" while public.auth_session_cutoffs was missing and the
# bridge answered 503 (2026-10-21). A `--` comment is dropped before matching:
# lowercased, auth-session-cutoffs.sql's "grobase's CREATE TABLE hook" read as a
# missing table `hook` and kept the file pending forever.
# Caveat: a `--` inside a string literal before a CREATE TABLE on the same line
# hides that table from --check (none in models/ today); apply mode is unaffected.
# A table created through dynamic SQL (EXECUTE format(...)) is invisible to --check too.
pending() {
	awk '{ l = tolower($0); sub(/--.*/, "", l) }
		match(l, /create table (if not exists )?(public\.)?[a-z_][a-z0-9_]*/) {
			t = substr(l, RSTART, RLENGTH)
			sub(/.* /, "", t); sub(/public\./, "", t); if (t != "public") print t
		}' "$1" | sort -u | while IFS= read -r t; do
		[ -n "${t}" ] || continue
		hit="$(docker exec "${PG_CTN}" psql -U postgres -d "${PG_DB}" -tAc \
			"SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='${t}' LIMIT 1" 2>/dev/null)"
		[ "${hit}" = "1" ] || {
			echo "${t}"
			return 0
		}
	done
}

# What still broadcasts rows on `pg/<table>`: public tables carrying a realtime_notify()
# trigger, plus the event trigger if it is enabled (it re-arms every new table). Empty =
# closed. A grobase `up` re-enables the event trigger (012:133-134), so this is checked
# after every run and by --check; a query error is reported as armed (unknown = fail).
realtime_armed() {
	docker exec "${PG_CTN}" psql -U postgres -d "${PG_DB}" -tA -v ON_ERROR_STOP=1 -c \
		"SELECT coalesce(string_agg(x, ' ' ORDER BY x), '') FROM (
		   SELECT c.relname AS x FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
		    WHERE c.relnamespace = 'public'::regnamespace AND NOT t.tgisinternal
		      AND t.tgfoid = to_regproc('public.realtime_notify')
		   UNION ALL
		   SELECT evtname || '(enabled)' FROM pg_event_trigger
		    WHERE evtname = 'realtime_auto_trigger_on_create' AND evtenabled <> 'D') armed" \
		2>/dev/null || echo "(query failed)"
}

# apply_one <file> [defer] — with `defer`, a failure is queued in ${deferred} for a retry
# after the alphabetical pass instead of being reported.
apply_one() {
	f="$1"
	base="$(basename "${f}")"
	miss="$(pending "${f}")"
	rc=0
	psql_in <"${f}" >/dev/null 2>"${ERR_FILE}" || rc=$?
	if [ "${rc}" -eq 0 ]; then
		if [ -n "${miss}" ]; then
			note "applied: ${base}"
			applied=$((applied + 1))
		fi
	elif [ "${2:-}" = defer ]; then
		deferred="${deferred} ${base}"
	else
		note "FAILED: ${base} — $(first_error "${ERR_FILE}" "${rc}")"
		failed=$((failed + 1))
	fi
	return 0
}

main() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"
		exit 1
	}
	docker ps --format '{{.Names}}' | grep -qx "${PG_CTN}" || {
		note "${PG_CTN} not running — skipping"
		exit 0
	}
	[ -d "${MODELS_DIR}" ] || {
		note "no ${MODELS_DIR} — skipping"
		exit 0
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
		armed="$(realtime_armed)"
		if [ -n "${armed}" ]; then
			note "realtime row broadcasts armed: ${armed}"
			gaps=$((gaps + 1))
		fi
		if [ "${gaps}" -gt 0 ]; then
			note "${gaps} migration(s) pending — run: make models-migrate"
			exit 1
		fi
		note "converged — no pending models migrations"
		exit 0
	fi

	applied=0 failed=0 deferred=""

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
		is_ordered_last "${base}" && continue
		apply_one "${f}" defer
	done
	# A file that references a table a LATER file creates fails once in alphabetical order
	# (osionos-rec-beacon indexes ai_events, which osionos-user-events creates): retry the
	# failures until a round makes no progress, then report what still fails.
	while [ -n "${deferred}" ]; do
		left="${deferred}"
		deferred=""
		for base in ${left}; do
			apply_one "${MODELS_DIR}/${base}" defer
		done
		[ "${deferred}" = "${left}" ] && break
	done
	for base in ${deferred}; do
		apply_one "${MODELS_DIR}/${base}"
	done

	for base in ${ORDERED_LAST}; do
		f="${MODELS_DIR}/${base}"
		if [ ! -f "${f}" ]; then
			note "FAILED: ${base} listed in ORDERED_LAST but not found in ${MODELS_DIR}"
			failed=$((failed + 1))
			continue
		fi
		apply_one "${f}"
	done

	armed="$(realtime_armed)"
	if [ -n "${armed}" ]; then
		note "FAILED: realtime row broadcasts still armed after realtime-cdc-off-migration.sql: ${armed}"
		failed=$((failed + 1))
	fi

	note "done — ${applied} newly applied, ${failed} failed, rest converged"
	[ "${failed}" -eq 0 ] || exit 1
}

main "$@"
