#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    models-grants.sh                                                          #
#                                                                              #
#    Prove public.osionos_*, auth_session_cutoffs and auth_audit_events are    #
#    reachable by service_role and by nothing else, on two throwaway DBs.      #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   models/*.sql is replayed on every boot (`make models-migrate`, and the desktop
#   edition's firstrun.mjs). Each file carries GRANTs, and nothing re-reads the ACL
#   they leave: a file that widens a grant, or an upgraded install still carrying an
#   old db-bootstrap's blanket grant, converges silently. Only asking a FRESH
#   database what anon and authenticated can reach catches it.
#
# WHAT IT RUNS  (both scenarios drive the REAL runner, never a re-typed file list)
#   fresh   roles -> grobase 001_initial_schema + 012 realtime hook -> shim -> runner -> checks
#   legacy  roles -> the pre-1e407614 default privileges -> 001 -> shim -> an old integer-keyed audit table with rows and a blanket grant -> runner
#           -> an old-bootstrap boot (blanket GRANT, DEFAULT revoked) -> runner -> checks
#   Checks: c no anon/authenticated privilege on an osionos_% or ai_% relation (partitions
#   included) or on auth_session_cutoffs, auth_audit_events or auth_audit_events_legacy_int · d no policy for PUBLIC/anon/authenticated · e1/e2 service_role
#   has full CRUD and round-trips a row · e3 it upserts a session cut-off as the
#   auth-gateway does · e4 service_role calls auth_record_audit_event with a new-list event ·
#   e5 a late, older upsert leaves the newer cut-off in place · f six probes (eight in legacy), S1-S3 on auth_session_cutoffs and A1-A3 on auth_audit_events and its RPC (A4-A5, legacy only: the renamed auth_audit_events_legacy_int), N1-N4 on newsletter_optins and its three RPCs, refused with 42501 ·
#   h no SECURITY DEFINER osionos_% function or auth_record_audit_event
#   they may execute · h-ai no ai_% writer function they may execute · P1 a direct read of an
#   ai_chunks partition refused with 42501 · g a second runner pass changes no ACL, policy or RLS flag ·
#   n the final notifications type CHECK admits every type the models files declare ·
#   r no public table keeps a realtime_notify() trigger (it broadcasts rows past every grant),
#   and r-cutoffs asserts it for auth_session_cutoffs by name ·
#   rt grobase's CREATE TABLE hook that re-arms new tables exists and is disabled ·
#   u anon cannot SELECT public.users.email or password_hash, authenticated cannot SELECT password_hash ·
#   colleague_edges_trigger the P0-5a colleague-edges trigger exists on
#   public.osionos_workspace_members under its own name (the migration's backfill
#   guard tests that same pair) · feed_counts_exec_grants · lifecycle_fn_settings
#   public.osionos_feed_page_counts is executable by service_role and by no
#   other role
#   sd the two self-data indexes the sys: sources read through — (owner_id, updated_at DESC) on
#   osionos_pages and on osionos_tasks — exist with that shape
#   wi1/wi2/wi3 the pending-invite table (osionos-workspace-invites-migration.sql): it exists with
#   forced RLS, its partial unique index has the exact live predicate, a second live invite is
#   refused (23505), one is allowed after a revoke, role 'owner' is refused (23514), and a
#   declined_at on a live row is refused (23514)
#   pa1/pa2 the page access requests (osionos-page-access-requests-migration.sql): forced RLS and
#   the pending-only unique index; a second pending request is refused (23505), one is allowed
#   after a decline, a 281-char note and an undated approval are refused (23514), and a page
#   delete removes its requests
#   tm1/tm2/tm3 the team tables (osionos-teams-migration.sql): both exist with forced RLS, the
#   (workspace_id, team_id) read index exists, a team member who is not a workspace member is
#   refused (23503), a duplicate name (23505) and a bad role (23514) too, and removing the
#   workspace member removes the team membership
#   ta1/ta2/ta3 the AI thread answers (osionos-ai-thread-answers-migration.sql): a run is
#   posted once (23505), a bot row needs its run and asker and a person's row has neither,
#   a run's surface is a text run's channel and message (23514), ai, ai-bot and assistant are
#   reserved; osionos_ai_channel_context labels the authors and windows the channel or the
#   thread up to the trigger; and it returns zero rows to an outsider, a non-member of a
#   private channel, in a dm or voice channel, or for someone else's or a deleted trigger,
#   while anon and authenticated may not execute it (42501)
#
#   The account plane (models/osionos-account-foundation-migration.sql, ADR 0028),
#   in scripts/verify/models-grants/account-checks.sql, piped after checks.sql into
#   the same psql stream:
#   k1 the account role holds no privilege on any relation that anon does not
#   hold — compared PER PRIVILEGE, so an UPDATE anon lacks is a reach even when
#   anon may SELECT the same table — except the tables marked
#   'osionos:account-plane' · k2 every marked table has RLS on, its policies name
#   no role but service_role and osionos_account_user, and its account-role
#   policy filters on the uid helper, keyed on what the policy does (SELECT and
#   DELETE read through polqual, INSERT writes through polwithcheck, UPDATE and
#   ALL constrain the written row) · k3 the expected account tables exist and are
#   marked · k4 the account indexes exist, compared on their whole shape (the
#   key columns with their expressions, the access method, the uniqueness and
#   the partial predicate) · k7 the role has the right shape and no membership
#   beyond authenticator · k8 the role may SELECT exactly nine session columns
#   and nothing else · k5 the role sees only its own rows (1) ·
#   k6 no forged claim set sees any (0) · K1-K6 six probes on the account plane,
#   refused with 42501 · account_secdef_exec the account role may execute no
#   SECURITY DEFINER osionos_% function · p1 the profile plane's own checks:
#   p1_role_column_acl the role's exact column reach on the four new tables,
#   p1_role_writes_profile the role writes its own profile and one row only,
#   p1_settings_merge two merges land and a null deletes a key, p1_hold the
#   held name is refused to B and reclaimed by A, p1_sync_changed_only the
#   legacy sync copies only the identity fields that changed, p1_noop_no_bump a
#   write that changes nothing leaves the profile's version alone,
#   p1_deletion_grace the role cannot set the deletion date and the grace is
#   a floor, p1_view_opt_out the directory view reports the profile's own
#   opt-out and keeps the columns the bridge selects,
#   p1_never_raises a colliding username and a missing auth.users row do not
#   fail a registration,
#   p1_isolation_own the role sees its own row in each of the four tables (4)
#   and p1_isolation_forged it sees and changes nothing of B's ·
#   p2s the atomic username change (models/osionos-account-username-migration.sql):
#   p2s_change the change writes both tables, one history row and one version,
#   p2s_history_once the change wrote exactly one history row,
#   p2s_atomic a name another identity holds is refused with 23505 and nothing
#   of the caller moves, p2s_hold the held name is refused to B and reclaimed by
#   A, p2s_invalid a short, a reserved, a malformed and a null name are all
#   22023, p2s_no_direct the role cannot write the username column itself,
#   p2s_no_uid six forged claim sets are all 42501 and never 22P02,
#   p2s_version_once the version moved by exactly one, p2s_keeps_typed_fields
#   the typed bio, headline and location survive the change, p2s_case a
#   case-only rename is a real change, p2s_no_identity a user with no
#   identities row can still change their name, p2s_same_name the same name
#   writes nothing and a drifted identity is brought in step, p2s_no_profile a
#   user with no profile row gets P0002, p2s_reverse_drift the change repairs a
#   profile that drifted the other way, p2s_function_config the function sets
#   exactly search_path=pg_catalog, public and lock_timeout=3s,
#   p2s_taken_by_profile a name another user's profile holds is refused with
#   23505 and nothing of the caller moves ·
#   p23 the follow and presence plane (models/osionos-social-follow-presence-migration.sql):
#   p23_social_grants the grants and RLS on both tables and the counts RPC,
#   p23_presence_state the default and the CHECKs, p23_status_columns the status
#   limits and the owner write, p23_block_trigger a block in either direction
#   refuses a follow, p23_counts_rpc one row with the right numbers,
#   p23_counts_plan the counts use index scans on 100K edges ·
#   p2_4 the profession column (P2-4-d1, models/osionos-account-profession-migration.sql):
#   p2_4_profession_check the CHECK named osionos_profiles_profession_check is
#   on the profession column and names all eight ids ·
#   p2_1 the README pointer (P2-1-a, models/osionos-account-readme-migration.sql):
#   p2_1_readme_fk readme_page_id is a UUID with a foreign key to osionos_pages
#   that sets NULL on delete ·
#   standalone the account foundation file applied alone leaves no realtime
#   trigger on the sessions table or on the audit table, no anon/authenticated
#   privilege and exactly the nine column grants — what the ledger runner
#   (scripts/apply-models.sh) relies on, and what the later passes hide; the
#   account profiles file applied after it leaves the same for the four new
#   tables and the directory view, and its NOTIFY comes after the COMMIT
#   p5 the account data map and the erase (P5-6-a, models/osionos-account-erasure-migration.sql):
#   p5_erasure_complete every user-keyed column (any uuid/varchar/text/json type) is in the registry · p5_erase_canary a
#   user's seeded row in every registry table is gone or tombstoned after the erase ·
#   p5_erase_transfer/_idempotent/_isolated/_sequence/_objects_recorded/_refuses_live/
#   _refuses_early/p5_plan_matches_erase/p5_dry_run_no_stamp/p5_audit_scrubbed/
#   p5_agents_two_scope (C314-C316: through osionos_account_erase no row of ai_agents, its audit or
#   ai_workspace_agent_settings mentions the erased user, in either scope; the other user's agent is byte-identical)/
#   p5_web_switch (web C374: through osionos_account_erase and through ai_erase_user no row of the
#   workspace web switch or its audit mentions the erased user; the workspace keeps its setting)/
#   p5_thread_answers (C446: an AI answer the erased user asked for in a channel is blanked, soft-deleted
#   and asked by the tombstone; the other user's answer is byte-identical)/
#   p5_summary (context C376/C390: a conversation summary is capped at 4000 chars, exported with the
#   conversation, and gone with it on erase; the other user's summary stays)/
#   p5_no_fk_to_tombstone/p5_report_survives_reporter/p5_users_scrubbed/
#   p5_foreign_content_null the erase's contract · p5_export_acl/_single_flight/
#   _no_secrets/_reachable the export job table · p5_no_exec_grants the functions are
#   service_role only · p5_race_claim/p5_race_cancel two-session races (run_races) ·
#   p5_race_cancel_first/p5_race_cancel_after_claim lock-ordered races (run_lock_races)
#  p4_activity_* the activity events table, its monthly partitions and the daily rollup:
#   _rollup_key/_rollup/_rollup_dropped_day/_no_user_column_in_rollup/_erase_rollup the
#   (day, event, surface) rollup with its 5-person floor · _default_empty/_default_drain/
#   _maintain/_maintain_failure partition upkeep · _children_closed/_grants RLS and ACLs on
#   every child · _canary_seedable/_canary_mutation the erase canary covers the table ·
#   _maintain_concurrent/_maintain_lock_timeout/_registry_reapply shell-driven sessions
#  p6_machines_* own machines (models/osionos-machines-migration.sql): _acl the account role's
#   seven columns of its own rows, no pubkey, no write, anon nothing, service_role writes ·
#   _rules one live default per user (23505) and the id/platform/pubkey/fingerprint/name CHECKs (23514) ·
#   _erase the erase removes A's machines and keeps B's · _erase_mutation without the registry row they survive
#
# ISOLATION
#   Throwaway containers only (--rm --network none, no port, no volume); the live
#   mini-baas / osionos containers are never touched. A trap removes each container
#   on every exit path. The image is grobase's postgres: models/*.sql needs pgvector.
#
# Usage:  [GROBASE_PG_IMAGE=…] [MODELS_DIR=…] sh scripts/verify/models-grants.sh
#
# Exit:  0 every check passed · 1 a check, fixture, image or runner failed (a missing
#        image is a FAIL, never a SKIP) · 2 docker is not installed
#
# Ponytail: shim.sql stands in for GoTrue's auth.users, user_profiles.display_name and a unique
#   index on user_profiles.user_id; a real-stack difference in those objects is not seen here.
# Ponytail: roles.sql mirrors apps/grobase/scripts/db/db-bootstrap.psql:1-43 by hand; a role or
#   default-privilege change there is not seen until this copy is updated.
# Ponytail: the f probes are six statements, not every statement. They sample one
#   table and one view as anon/authenticated; check c is the exhaustive sweep, and
#   a path that only exists through an osionos function's EXECUTE grant is caught
#   only when that function is SECURITY DEFINER (check h).
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="${REPO}/scripts/verify/models-grants"
RUNNER="${REPO}/scripts/apply-models-migrations.sh"
GROBASE_INIT="${REPO}/apps/grobase/scripts/migrations/postgresql/001_initial_schema.sql"
# 012 installs the CREATE TABLE hook that gives every new public table a realtime trigger, as live.
GROBASE_REALTIME="${REPO}/apps/grobase/scripts/migrations/postgresql/012_realtime_triggers_all_tables.sql"
IMAGE="${GROBASE_PG_IMAGE:-ghcr.io/univers42/grobase-postgres:latest}"
MODELS_DIR="${MODELS_DIR:-${REPO}/models}"
READY_TIMEOUT=60
PG_USER=postgres
PG_DB=postgres

CTN=''
WORK=''
passed=0
failed=0

note() { printf '[models-grants] %s\n' "$*" >&2; }

pass() { passed=$((passed + 1)) && printf 'PASS %s %s %s\n' "$1" "$2" "$3"; }
fail() { failed=$((failed + 1)) && printf 'FAIL %s %s %s\n' "$1" "$2" "$3"; }

# A failed precondition stops the run; the RESULT line still closes the log.
die() {
	fail "$@"
	finish 1
}

finish() {
	printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
	exit "$1"
}

drop_container() {
	if [ -n "${CTN}" ]; then
		docker rm -f "${CTN}" >/dev/null 2>&1 || true
	fi
	CTN=''
}
trap 'drop_container; rm -rf "${WORK}"' EXIT INT TERM

psql_stdin() {
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q
}

# -At: one '|'-joined line per tuple, so cut/grep can read the rows back.
psql_rows() {
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q -At
}

# Apply a fixture; on failure echo psql's stderr verbatim.
apply() {
	if psql_stdin <"$1" >"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

# Ready = answering on TCP. The image's entrypoint first runs a socket-only temporary
# server for its init scripts and then restarts; a socket probe can succeed in that window
# and the next psql finds no socket (CI job 117478667259, "FAIL scenario setup/fresh").
wait_ready() {
	i=0
	while [ "${i}" -lt "${READY_TIMEOUT}" ]; do
		if docker exec "${CTN}" pg_isready -h 127.0.0.1 -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

# run_runner <scenario> <tag> — the real runner. Clean = exit 0 AND a ` 0 failed`
# summary, which catches a runner that exits 0 while reporting a failure.
run_runner() {
	log="${WORK}/runner-$1-$2.log"
	if PG_CONTAINER="${CTN}" MODELS_DIR="${MODELS_DIR}" sh "${RUNNER}" >"${log}" 2>&1; then
		rc=0
	else
		rc=$?
	fi
	last="$(awk 'NF { l = $0 } END { print l }' "${log}")"
	summary_clean=no
	if [ "${rc}" -eq 0 ]; then
		case "${last}" in
		*' 0 failed'*) summary_clean=yes ;;
		esac
	fi
	if [ "${summary_clean}" = "no" ]; then
		rc=99
	fi
	if [ "${rc}" -ne 0 ]; then
		fail "$1" "runner/$2" "exit ${rc} — ${last}"
		grep -h 'FAILED:' "${log}" | sed 's/^/  | /' >&2 || true
		finish 1
	fi
	note "$1: ${last}"
}

# check_count <scenario> <id> <label> — a `<label>|<count>|<detail>` row from checks.sql.
check_count() {
	line="$(grep "^$3|" "${WORK}/checks-$1.out" || true)"
	if [ -z "${line}" ]; then
		fail "$1" "$2" "checks.sql printed no ${3} row"
		return 0
	fi
	n="$(printf '%s\n' "${line}" | cut -d'|' -f2)"
	detail="$(printf '%s\n' "${line}" | cut -d'|' -f3-)"
	if [ "${n}" = "0" ]; then
		pass "$1" "$2" "0"
	else
		fail "$1" "$2" "${n} — ${detail}"
	fi
}

# check_svc <scenario> <id> <label> — a `<label>|<count>` row from checks.sql that must be 1.
check_svc() {
	n="$(grep "^$3|" "${WORK}/checks-$1.out" | cut -d'|' -f2 || true)"
	if [ "${n}" = "1" ]; then
		pass "$1" "$2" "1"
	else
		fail "$1" "$2" "service_role round trip ($3) saw ${n:-no} row(s)"
	fi
}

# check_eq <scenario> <id> <label> <expected> — a `<label>|<count>|<detail>` row
# that must hold an exact value. check_count counts failures; the isolation row
# counts the tables in which the role saw its own row (four of them).
check_eq() {
	line="$(grep "^$3|" "${WORK}/checks-$1.out" || true)"
	if [ -z "${line}" ]; then
		fail "$1" "$2" "checks.sql printed no ${3} row"
		return 0
	fi
	n="$(printf '%s\n' "${line}" | cut -d'|' -f2)"
	if [ "$n" = "$4" ]; then
		pass "$1" "$2" "$4"
	else
		fail "$1" "$2" "${n:-no row} — expected $4"
	fi
}

# probe <scenario> <id> <role> <statement> — a rolled-back transaction that must be
# refused with exactly SQLSTATE 42501; success and any other code are both a FAIL.
probe() {
	claims=''
	if [ "$3" = "authenticated" ]; then
		claims="SELECT set_config('request.jwt.claims','{\"sub\":\"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\",\"role\":\"authenticated\"}', true);"
	fi
	err="${WORK}/probe-$1-$2.err"
	# Every line ends in ';' so a statement is never glued to the ROLLBACK.
	if printf '%s\n' '\set VERBOSITY sqlstate' 'BEGIN;' "SET LOCAL ROLE $3;" "${claims}" "$4;" 'ROLLBACK;' |
		psql_stdin >"${WORK}/probe-$1-$2.out" 2>"${err}"; then
		rc=0
	else
		rc=$?
	fi
	codes="$(sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' "${err}" | sort -u)"
	if [ "${rc}" -ne 0 ] && [ "${codes}" = "42501" ]; then
		pass "$1" "$2" "42501"
	else
		if [ "${rc}" -eq 0 ]; then
			reason="statement SUCCEEDED as $3"
		elif [ -n "${codes}" ]; then
			reason="sqlstate ${codes} — $(head -1 "${err}" || true)"
		else
			reason="exit ${rc} with no SQLSTATE — $(head -1 "${err}" || true)"
		fi
		fail "$1" "$2" "${reason}"
	fi
}

# check_idempotent <scenario> — snapshot, replay the runner, snapshot again: a
# migration that re-grants on every boot shows as a changed line.
check_idempotent() {
	if ! psql_rows <"${FIX}/snapshot.sql" >"${WORK}/snap1-$1.out" 2>"${WORK}/snap1-$1.err"; then
		note "snapshot failed before the replay"
		sed 's/^/  | /' "${WORK}/snap1-$1.err" >&2
		fail "$1" "g" "snapshot.sql failed before the replay"
		return 0
	fi
	run_runner "$1" "idempotency"
	if ! psql_rows <"${FIX}/snapshot.sql" >"${WORK}/snap2-$1.out" 2>"${WORK}/snap2-$1.err"; then
		note "snapshot failed after the replay"
		sed 's/^/  | /' "${WORK}/snap2-$1.err" >&2
		fail "$1" "g" "snapshot.sql failed after the replay"
		return 0
	fi
	if diff -u "${WORK}/snap1-$1.out" "${WORK}/snap2-$1.out" >"${WORK}/diff-$1.out" 2>&1; then
		pass "$1" "g" "no ACL/RLS drift on the replay"
	else
		fail "$1" "g" "$(grep -c '^[-+][^-+]' "${WORK}/diff-$1.out" || true) line(s) of drift:"
		sed 's/^/  | /' "${WORK}/diff-$1.out" >&2
	fi
}

# check_standalone <scenario> — the account foundation file applied ALONE, on a
# database where the later passes would hide what it leaves behind: the realtime
# hook armed again, the legacy default privilege back, and the sessions table
# dropped so the file has to recreate it. The ledger runner
# (scripts/apply-models.sh) may run this file with no service-role-only and no
# realtime-cdc-off pass after it, so the file has to be self-sufficient.
# The account profiles file is applied after it, for the same reason: it
# creates four more tables and the directory view, and it has to leave no
# realtime trigger and no anon/authenticated privilege behind either.
# The personal access tokens file is applied after it, for the same reason: it
# creates one more osionos_* relation, grants it to the account role and drops
# the realtime trigger the CREATE TABLE hook armed on it. Its table is dropped
# first, like the others: the hook only arms a table when it is CREATED, so a
# table that is still there would make the realtime row vacuous.
check_standalone() {
	file="${MODELS_DIR}/osionos-account-foundation-migration.sql"
	profiles="${MODELS_DIR}/osionos-account-profiles-migration.sql"
	pat="${MODELS_DIR}/osionos-personal-access-tokens-migration.sql"
	social="${MODELS_DIR}/osionos-social-follow-presence-migration.sql"
	keys="${MODELS_DIR}/osionos-user-keys-migration.sql"
	if [ ! -f "${file}" ]; then
		fail "$1" "standalone" "no ${file}"
		return 0
	fi
	if [ ! -f "${profiles}" ]; then
		fail "$1" "standalone" "no ${profiles}"
		return 0
	fi
	if [ ! -f "${pat}" ]; then
		fail "$1" "standalone" "no ${pat}"
		return 0
	fi
	if [ ! -f "${social}" ]; then
		fail "$1" "standalone" "no ${social}"
		return 0
	fi
	if [ ! -f "${keys}" ]; then
		fail "$1" "standalone" "no ${keys}"
		return 0
	fi
	if ! printf '%s\n' \
		'DO $$ BEGIN' \
		"  IF EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'realtime_auto_trigger_on_create') THEN" \
		'    ALTER EVENT TRIGGER realtime_auto_trigger_on_create ENABLE;' \
		'  END IF;' \
		'END $$;' | psql_stdin >"${WORK}/standalone-$1.log" 2>&1; then
		fail "$1" "standalone" "could not re-arm the realtime hook"
		sed 's/^/  | /' "${WORK}/standalone-$1.log" >&2
		return 0
	fi
	if ! psql_stdin <"${FIX}/legacy-default.sql" >"${WORK}/standalone-$1.log" 2>&1; then
		fail "$1" "standalone" "could not re-apply the legacy default privilege"
		return 0
	fi
	if ! printf '%s\n' 'DROP TABLE IF EXISTS public.osionos_sessions;' |
		psql_stdin >"${WORK}/standalone-$1.log" 2>&1; then
		fail "$1" "standalone" "could not drop public.osionos_sessions"
		return 0
	fi
	# The four profile tables and the view go too: the realtime hook only arms
	# a table when it is CREATED, so a table that is still there would make the
	# realtime row vacuous.
	if ! printf '%s\n' \
		'DROP VIEW IF EXISTS public.osionos_people_directory;' \
		'DROP TABLE IF EXISTS public.osionos_profiles;' \
		'DROP TABLE IF EXISTS public.osionos_user_settings;' \
		'DROP TABLE IF EXISTS public.osionos_username_history;' \
		'DROP TABLE IF EXISTS public.osionos_account_deletion_requests;' \
		'DROP TABLE IF EXISTS public.osionos_personal_access_tokens;' \
		'DROP TABLE IF EXISTS public.osionos_follows;' \
		'DROP TABLE IF EXISTS public.osionos_presence;' |
		psql_stdin >"${WORK}/standalone-$1.log" 2>&1; then
		fail "$1" "standalone" "could not drop the profile tables"
		return 0
	fi
	# The audit table's realtime trigger is re-armed on purpose: the file claims
	# to drop it (the table now carries ip_hash and user_agent), and nothing
	# after the solo apply would drop it for us.
	if ! printf '%s\n' "SELECT public.realtime_ensure_trigger('public','osionos_bridge_audit_events');" |
		psql_stdin >"${WORK}/standalone-$1.log" 2>&1; then
		fail "$1" "standalone" "could not re-arm the audit table's realtime trigger"
		sed 's/^/  | /' "${WORK}/standalone-$1.log" >&2
		return 0
	fi
	if ! psql_stdin <"${file}" >"${WORK}/standalone-$1.log" 2>&1; then
		fail "$1" "standalone" "the account foundation file did not apply alone"
		sed 's/^/  | /' "${WORK}/standalone-$1.log" >&2
		return 0
	fi
	# The profiles file is applied without -q: the command tags are what the
	# NOTIFY assertion reads, and -q hides them.
	if ! docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 \
		<"${profiles}" >"${WORK}/standalone-$1.tags" 2>&1; then
		fail "$1" "standalone" "the account profiles file did not apply after the foundation"
		sed 's/^/  | /' "${WORK}/standalone-$1.tags" >&2
		return 0
	fi
	# The token file is applied alone after it: the table it creates is the one
	# the realtime hook arms, so its own DROP TRIGGER is the only thing that can
	# take the trigger away.
	if ! psql_stdin <"${pat}" >"${WORK}/standalone-$1.log" 2>&1; then
		fail "$1" "standalone" "the personal access tokens file did not apply after the profiles"
		sed 's/^/  | /' "${WORK}/standalone-$1.log" >&2
		return 0
	fi
	# The follow and presence file is applied alone too: it creates two more
	# tables for the hook to arm, and the service-role-only pass that hides a
	# stray anon grant does not run after it here.
	if ! psql_stdin <"${social}" >"${WORK}/standalone-$1.log" 2>&1; then
		fail "$1" "standalone" "the follow and presence file did not apply after the tokens file"
		sed 's/^/  | /' "${WORK}/standalone-$1.log" >&2
		return 0
	fi
	if ! psql_stdin <"${keys}" >"${WORK}/standalone-$1.log" 2>&1; then
		fail "$1" "standalone" "the user keys file did not apply after the follow and presence file"
		sed 's/^/  | /' "${WORK}/standalone-$1.log" >&2
		return 0
	fi
	# The NOTIFY must come AFTER the COMMIT: the view is dropped and recreated,
	# and PostgREST has to reload the schema only once the new view exists.
	commit_line="$(grep -n '^COMMIT$' "${WORK}/standalone-$1.tags" | tail -1 | cut -d: -f1)"
	notify_line="$(grep -n '^NOTIFY$' "${WORK}/standalone-$1.tags" | tail -1 | cut -d: -f1)"
	if [ -n "${notify_line}" ] && [ -n "${commit_line}" ] && [ "${notify_line}" -gt "${commit_line}" ]; then
		pass "$1" "standalone_notify" "after the COMMIT"
	else
		fail "$1" "standalone_notify" "the NOTIFY is not after the COMMIT (notify=${notify_line:-none} commit=${commit_line:-none})"
	fi
	if ! psql_rows >"${WORK}/standalone-$1.out" 2>"${WORK}/standalone-$1.err" <<'SQL'
SELECT 'sessions_realtime_triggers', count(*)::text, ''
  FROM pg_trigger t
 WHERE t.tgrelid = 'public.osionos_sessions'::regclass
   AND NOT t.tgisinternal AND t.tgfoid = to_regproc('public.realtime_notify');
SELECT 'audit_realtime_triggers', count(*)::text, ''
  FROM pg_trigger t
 WHERE t.tgrelid = 'public.osionos_bridge_audit_events'::regclass
   AND NOT t.tgisinternal AND t.tgfoid = to_regproc('public.realtime_notify');
SELECT 'sessions_anon_auth_privs', count(*)::text, ''
  FROM (VALUES ('anon'),('authenticated')) AS x(rolname)
  CROSS JOIN (VALUES ('SELECT',true),('INSERT',true),('UPDATE',true),('REFERENCES',true),
                     ('DELETE',false),('TRUNCATE',false),('TRIGGER',false)) AS p(priv, col_level)
 WHERE has_table_privilege(x.rolname, 'public.osionos_sessions', p.priv)
    OR (p.col_level AND has_any_column_privilege(x.rolname, 'public.osionos_sessions', p.priv));
SELECT 'sessions_column_acl', coalesce(string_agg(a.attname, ',' ORDER BY a.attnum), ''), ''
  FROM pg_attribute a
 WHERE a.attrelid = 'public.osionos_sessions'::regclass AND a.attnum > 0 AND NOT a.attisdropped
   AND has_column_privilege('osionos_account_user', a.attrelid, a.attname, 'SELECT');
SELECT r.rel || '_realtime_triggers', count(t.tgrelid)::text, ''
  FROM unnest(ARRAY['osionos_profiles','osionos_user_settings','osionos_username_history',
                    'osionos_account_deletion_requests','osionos_people_directory',
                    'osionos_personal_access_tokens','osionos_follows','osionos_presence','osionos_user_keys']) AS r(rel)
  LEFT JOIN pg_class c ON c.relname = r.rel AND c.relnamespace = 'public'::regnamespace
  LEFT JOIN pg_trigger t ON t.tgrelid = c.oid AND NOT t.tgisinternal
                         AND t.tgfoid = to_regproc('public.realtime_notify')
 GROUP BY r.rel ORDER BY r.rel;
SELECT r.rel || '_anon_auth_privs',
       (SELECT count(*)::text
          FROM (VALUES ('anon'),('authenticated')) AS x(rolname)
          CROSS JOIN (VALUES ('SELECT',true),('INSERT',true),('UPDATE',true),('REFERENCES',true),
                             ('DELETE',false),('TRUNCATE',false),('TRIGGER',false)) AS p(priv, col_level)
         WHERE has_table_privilege(x.rolname, 'public.' || r.rel, p.priv)
            OR (p.col_level AND has_any_column_privilege(x.rolname, 'public.' || r.rel, p.priv))) AS v,
       ''
  FROM unnest(ARRAY['osionos_profiles','osionos_user_settings','osionos_username_history',
                    'osionos_account_deletion_requests','osionos_people_directory',
                    'osionos_personal_access_tokens','osionos_follows','osionos_presence','osionos_user_keys']) AS r(rel)
 ORDER BY r.rel;
SQL
	then
		fail "$1" "standalone" "the standalone assertions did not run"
		sed 's/^/  | /' "${WORK}/standalone-$1.err" >&2
		return 0
	fi
	assert_standalone "$1" sessions_realtime_triggers 0
	assert_standalone "$1" audit_realtime_triggers 0
	assert_standalone "$1" sessions_anon_auth_privs 0
	assert_standalone "$1" sessions_column_acl \
		'id,created_at,expires_at,last_seen_at,auth_method,ip_prefix,user_agent,revoked_at,revoked_reason'
	for rel in osionos_profiles osionos_user_settings osionos_username_history \
	           osionos_account_deletion_requests osionos_people_directory \
	           osionos_personal_access_tokens osionos_follows osionos_presence osionos_user_keys; do
		assert_standalone "$1" "${rel}_realtime_triggers" 0
		assert_standalone "$1" "${rel}_anon_auth_privs" 0
	done
}

# assert_standalone <scenario> <label> <expected> — one named row of the
# standalone step, compared to the value it must hold.
assert_standalone() {
	got="$(grep "^$2|" "${WORK}/standalone-$1.out" | head -1 | cut -d'|' -f2 || true)"
	if [ "$got" = "$3" ]; then
		pass "$1" "$2" "$3"
	else
		fail "$1" "$2" "${got:-no row} — expected $3"
	fi
}

# check_ordered_last <scenario> — the runner's ORDERED_LAST list, pinned. The
# catalog pass (osionos-service-role-only-migration.sql) is what revokes what
# the legacy default privileges handed to a relation the runner creates, so a
# file that runs after it is outside the revocation the runner exists for; and
# the token file grants to the role the foundation file creates, so it has to
# run after it. The order is a thing to prove, not to assume.
check_ordered_last() {
	pinned_tail="osionos-service-role-only-migration.sql realtime-cdc-off-migration.sql users-pii-grants-migration.sql"
	line="$(grep -E '^ORDERED_LAST=' "${RUNNER}" | tail -1 || true)"
	if [ -z "${line}" ]; then
		fail "$1" "ordered_last" "no ORDERED_LAST line in ${RUNNER}"
		return 0
	fi
	list="$(printf '%s\n' "${line}" | sed -e 's/^ORDERED_LAST="//' -e 's/"$//')"
	tail3="$(printf '%s\n' "${list}" | awk 'NF < 3 { print ""; next } { s = ""; for (i = NF - 2; i <= NF; i++) { s = s (s == "" ? "" : " ") $i } print s }')"
	if [ "${tail3}" != "${pinned_tail}" ]; then
		fail "$1" "ordered_last" "the tail is '${tail3}', expected '${pinned_tail}'"
		return 0
	fi
	pos_foundation=0
	pos_token=0
	i=0
	for f in ${list}; do
		i=$((i + 1))
		if [ "${f}" = "osionos-account-foundation-migration.sql" ]; then
			pos_foundation="${i}"
		fi
		if [ "${f}" = "osionos-personal-access-tokens-migration.sql" ]; then
			pos_token="${i}"
		fi
	done
	if [ "${pos_foundation}" -eq 0 ] || [ "${pos_token}" -eq 0 ]; then
		fail "$1" "ordered_last" "the list names neither the foundation file nor the token file: ${list}"
		return 0
	fi
	if [ "${pos_foundation}" -ge "${pos_token}" ]; then
		fail "$1" "ordered_last" "the foundation file is not before the token file: ${list}"
		return 0
	fi
	pass "$1" "ordered_last" "the tail is pinned"
}

run_checks() {
	# The runner's file order is a fact about the script, not about this
	# database, so it is read from the script itself.
	check_ordered_last "$1"
	# A checks.sql error is echoed, then read back anyway: a missing row is a FAIL.
	# checks.sql and account-checks.sql go into ONE psql: one stream, so the two
	# isolation rows stay last, and one transaction for the k5/k6 GUCs.
	if ! cat "${FIX}/checks.sql" "${FIX}/account-checks.sql" |
		psql_rows >"${WORK}/checks-$1.out" 2>"${WORK}/checks-$1.err"; then
		note "the check files did not run to completion"
		sed 's/^/  | /' "${WORK}/checks-$1.err" >&2
	fi
	check_count "$1" c privileged
	check_count "$1" d member_policies
	check_count "$1" e1 service_role_gaps
	check_svc "$1" e2 svc_rows
	check_svc "$1" e3 svc_cutoff
	check_svc "$1" e4 svc_audit
	check_svc "$1" e5 svc_cutoff_monotonic
	probe "$1" T1 authenticated "SELECT count(*) FROM public.osionos_pages"
	probe "$1" T2 authenticated "DELETE FROM public.osionos_pages"
	probe "$1" T3 authenticated "UPDATE public.osionos_pages SET owner_id='cccccccc-cccc-cccc-cccc-cccccccccccc', visibility='public'"
	probe "$1" V1 anon "SELECT user_id, display_name FROM public.osionos_directory"
	probe "$1" V4 anon "UPDATE public.osionos_directory SET display_name='x'"
	probe "$1" V5 anon "DELETE FROM public.osionos_directory"
	probe "$1" S1 authenticated "SELECT user_id, sessions_valid_after FROM public.auth_session_cutoffs"
	probe "$1" S2 anon "INSERT INTO public.auth_session_cutoffs (user_id) VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')"
	probe "$1" S3 authenticated "UPDATE public.auth_session_cutoffs SET sessions_valid_after = 'epoch'"
	probe "$1" A1 authenticated "SELECT event_type FROM public.auth_audit_events"
	probe "$1" A2 anon "SELECT public.auth_record_audit_event('logout')"
	probe "$1" A3 authenticated "INSERT INTO public.auth_audit_events (event_type) VALUES ('logout')"
	# The newsletter RPCs are service_role-only: an anon caller choosing the token could request
	# and confirm an opt-in for someone else's address.
	probe "$1" N1 anon "SELECT public.gdpr_request_newsletter_optin('victim@example.com', repeat('a', 64))"
	probe "$1" N2 anon "SELECT public.gdpr_confirm_newsletter_optin(repeat('a', 64))"
	probe "$1" N3 authenticated "SELECT public.gdpr_withdraw_consent('newsletter', repeat('a', 64))"
	probe "$1" N4 anon "SELECT email FROM public.newsletter_optins"
	# Only the legacy scenario plants the old-shape table the migration renames.
	if [ "$1" = "legacy" ]; then
		probe "$1" A4 authenticated "SELECT event_type FROM public.auth_audit_events_legacy_int"
		probe "$1" A5 anon "SELECT event_type FROM public.auth_audit_events_legacy_int"
	fi
	check_count "$1" h secdef_exec
	check_count "$1" h-ai ai_write_fn_exec
	probe "$1" P1 anon "SELECT count(*) FROM public.ai_chunks_p00"
	check_count "$1" n notify_types_missing
	check_count "$1" r realtime_triggers
	check_count "$1" r-cutoffs cutoff_realtime_triggers
	check_count "$1" rt realtime_event_trigger
	check_count "$1" u users_pii
	check_count "$1" m1 moderation_columns
	check_count "$1" audit_viewer_index audit_viewer_index
	# P0-5a: the colleague-edges trigger and the feed counts function.
	check_count "$1" colleague_edges_trigger colleague_edges_trigger
	check_count "$1" feed_counts_exec_grants feed_counts_exec_grants
	check_count "$1" lifecycle_fn_settings lifecycle_fn_settings
	check_count "$1" lifecycle_mark_first lifecycle_mark_first
	check_count "$1" lifecycle_mark_last_workspace lifecycle_mark_last_workspace
	check_count "$1" lifecycle_mark_not_owner lifecycle_mark_not_owner
	check_count "$1" lifecycle_mark_already_pending lifecycle_mark_already_pending
	check_count "$1" lifecycle_mark_restamp lifecycle_mark_restamp
	check_count "$1" lifecycle_mark_restamp_stamps lifecycle_mark_restamp_stamps
	check_count "$1" lifecycle_transfer_refused_pending lifecycle_transfer_refused_pending
	check_count "$1" lifecycle_transfer_ok lifecycle_transfer_ok
	check_count "$1" lifecycle_transfer_one_owner lifecycle_transfer_one_owner
	lifecycle_race "$1"
	check_count "$1" sd1 self_data_indexes_missing
	check_count "$1" wi1 workspace_invites_table
	check_count "$1" wi2 workspace_invites_live_index
	check_count "$1" wi3 workspace_invites_behaviour
	check_count "$1" pa1 page_access_requests_table
	check_count "$1" pa2 page_access_requests_behaviour
	check_count "$1" tm1 teams_tables
	check_count "$1" tm2 teams_workspace_index
	check_count "$1" tm3 teams_behaviour
	check_count "$1" ta1 thread_answers_schema
	check_count "$1" ta2 thread_answers_context
	check_count "$1" ta3 thread_answers_acl
	check_count "$1" k1 account_role_reach
	check_count "$1" k2 account_plane_rls
	check_count "$1" k3 account_plane_expected
	check_count "$1" k4 account_indexes_missing
	check_count "$1" k7 account_role_shape
	check_count "$1" k8 account_session_columns
	check_count "$1" p1_role_column_acl p1_role_column_acl
	check_count "$1" p1_role_writes_profile p1_role_writes_profile
	check_count "$1" p1_settings_merge p1_settings_merge
	check_count "$1" p1_hold p1_hold
	check_count "$1" p1_sync_changed_only p1_sync_changed_only
	check_count "$1" p1_noop_no_bump p1_noop_no_bump
	check_count "$1" p1_deletion_grace p1_deletion_grace
	check_count "$1" p1_view_opt_out p1_view_opt_out
	check_count "$1" p1_never_raises p1_never_raises
	check_eq "$1" p1_isolation_own p1_isolation_own 4
	check_count "$1" p1_isolation_forged p1_isolation_forged
	check_count "$1" p5_published_read p5_published_read
	check_count "$1" p5_pat_column_acl p5_pat_column_acl
	check_count "$1" p5_pat_row_rules p5_pat_row_rules
	check_count "$1" p5_keys_column_acl p5_keys_column_acl
	check_count "$1" p5_keys_row_rules p5_keys_row_rules
	check_count "$1" h2 account_secdef_exec
	check_count "$1" p2s_change p2s_change
	check_count "$1" p2s_history_once p2s_history_once
	check_count "$1" p2s_atomic p2s_atomic
	check_count "$1" p2s_hold p2s_hold
	check_count "$1" p2s_invalid p2s_invalid
	check_count "$1" p2s_no_direct p2s_no_direct
	check_count "$1" p2s_no_uid p2s_no_uid
	check_count "$1" p2s_version_once p2s_version_once
	check_count "$1" p2s_keeps_typed_fields p2s_keeps_typed_fields
	check_count "$1" p2s_case p2s_case
	check_count "$1" p2s_no_identity p2s_no_identity
	check_count "$1" p2s_same_name p2s_same_name
	check_count "$1" p2s_no_profile p2s_no_profile
	check_count "$1" p2s_reverse_drift p2s_reverse_drift
	check_count "$1" p2s_function_config p2s_function_config
	check_count "$1" p2s_taken_by_profile p2s_taken_by_profile
	check_count "$1" p2_4_profession_check p2_4_profession_check
	check_count "$1" p2_1_readme_fk p2_1_readme_fk
	check_count "$1" p23_social_grants p23_social_grants
	check_count "$1" p23_presence_state p23_presence_state
	check_count "$1" p23_status_columns p23_status_columns
	check_count "$1" p23_block_trigger p23_block_trigger
	check_count "$1" p23_counts_rpc p23_counts_rpc
	check_count "$1" p23_counts_plan p23_counts_plan
	check_count "$1" p32_mfa_secrets p32_mfa_secrets
	check_count "$1" p32_mfa_secrets_read p32_mfa_secrets_read
	check_count "$1" p5_erasure_complete p5_erasure_complete
	check_count "$1" f3b_user_emails_unique f3b_user_emails_unique
	check_count "$1" p5_erase_canary p5_erase_canary
	check_count "$1" p5_erase_transfer p5_erase_transfer
	check_count "$1" p5_erase_idempotent p5_erase_idempotent
	check_count "$1" p5_erase_isolated p5_erase_isolated
	check_count "$1" p5_plan_matches_erase p5_plan_matches_erase
	check_count "$1" p5_erase_refuses_live p5_erase_refuses_live
	check_count "$1" p5_erase_refuses_early p5_erase_refuses_early
	check_count "$1" p5_dry_run_no_stamp p5_dry_run_no_stamp
	check_count "$1" p5_no_fk_to_tombstone p5_no_fk_to_tombstone
	check_count "$1" p5_erase_objects_recorded p5_erase_objects_recorded
	check_count "$1" p5_audit_scrubbed p5_audit_scrubbed
	check_count "$1" p5_agents_two_scope p5_agents_two_scope
	check_count "$1" p5_web_switch p5_web_switch
	check_count "$1" p5_thread_answers p5_thread_answers
	check_count "$1" p5_summary p5_summary
	check_count "$1" p5_erase_sequence p5_erase_sequence
	check_count "$1" p5_export_acl p5_export_acl
	check_count "$1" p5_export_single_flight p5_export_single_flight
	check_count "$1" p5_export_no_secrets p5_export_no_secrets
	check_count "$1" p5_export_reachable p5_export_reachable
	check_count "$1" p5_no_exec_grants p5_no_exec_grants
	check_count "$1" p5_report_survives_reporter p5_report_survives_reporter
	check_count "$1" p5_users_scrubbed p5_users_scrubbed
	check_count "$1" p5_foreign_content_null p5_foreign_content_null
	check_count "$1" p4_activity_rollup_key p4_activity_rollup_key
	check_count "$1" p4_activity_default_empty p4_activity_default_empty
	check_count "$1" p4_activity_default_drain p4_activity_default_drain
	check_count "$1" p4_activity_maintain p4_activity_maintain
	check_count "$1" p4_activity_maintain_failure p4_activity_maintain_failure
	check_count "$1" p4_activity_children_closed p4_activity_children_closed
	check_count "$1" p4_activity_grants p4_activity_grants
	check_count "$1" p4_activity_rollup p4_activity_rollup
	check_count "$1" p4_activity_rollup_dropped_day p4_activity_rollup_dropped_day
	check_count "$1" p4_activity_no_user_column_in_rollup p4_activity_no_user_column_in_rollup
	check_count "$1" p4_activity_erase_rollup p4_activity_erase_rollup
	check_count "$1" p4_activity_canary_seedable p4_activity_canary_seedable
	check_count "$1" p4_activity_canary_mutation p4_activity_canary_mutation
	check_count "$1" p6_machines_acl p6_machines_acl
	check_count "$1" p6_machines_rules p6_machines_rules
	check_count "$1" p6_machines_erase p6_machines_erase
	check_count "$1" p6_machines_erase_mutation p6_machines_erase_mutation
	p4_activity_maintain_concurrent "$1"
	p4_activity_maintain_lock_timeout "$1"
	p4_activity_registry_reapply "$1"
	# Before check_standalone: it drops the account tables, which the races need.
	run_races "$1"
	probe "$1" K1 authenticated "SELECT count(*) FROM public.osionos_sessions"
	probe "$1" K2 osionos_account_user "SELECT refresh_hash FROM public.osionos_sessions"
	probe "$1" K3 osionos_account_user "UPDATE public.osionos_sessions SET revoked_at = now()"
	probe "$1" K4 osionos_account_user "SELECT count(*) FROM public.osionos_pages"
	probe "$1" K5 authenticated "SELECT public.osionos_account_uid()"
	probe "$1" K6 anon "INSERT INTO public.osionos_sessions (id, user_id, expires_at, auth_method) VALUES (gen_random_uuid(), gen_random_uuid(), now() + interval '1 hour', 'password')"
	check_svc "$1" k5 account_isolation_own
	check_count "$1" k6 account_isolation_forged
	check_idempotent "$1"
	check_standalone "$1"
}

# lock_race <scenario> <label> <user> <claimed> — the cancel wins, ordered by a held
# row lock and a flag file, never by a sleep. Session one cancels (DELETE as the
# account role) and keeps the request row locked, uncommitted, until the flag
# file appears; session two runs the erase, which must queue behind that lock;
# the flag is written only once pg_stat_activity shows the erase waiting on a
# lock. When the cancel then commits, the erase wakes to no row and must raise
# no_deletion_request with the person's users row unchanged and no object key
# recorded. <claimed> = 1 claims the request first, so the cancel lands after the
# claim and before erased_at.
# Caveat: every wait is a bounded poll (about 20 s); on a host too loaded to get
# there the case fails (a missing pass, never a false pass).
lock_race() {
	lr_flag="/tmp/lock-race-${2}-$$.flag"
	lr_u="$3"
	lr_label="p5_race_${2}"
	docker exec "${CTN}" rm -f "${lr_flag}"
	lr_before="$(printf "SELECT md5(to_jsonb(u)::text) FROM public.users u WHERE id = '%s';\n" "${lr_u}" | psql_rows)"
	if [ "$4" = 1 ]; then
		printf '%s\n' "SELECT count(*) FROM public.osionos_account_deletion_claim(20);" | psql_rows >/dev/null 2>&1 || true
		if [ "$(printf "SELECT count(*) FROM public.osionos_account_deletion_requests WHERE user_id = '%s' AND claimed_at IS NOT NULL AND erased_at IS NULL;\n" "${lr_u}" | psql_rows)" != 1 ]; then
			fail "$1" "${lr_label}" "the request was not claimed before the cancel"
			return 0
		fi
	fi
	printf '%s\n' 'BEGIN;' 'SET LOCAL ROLE osionos_account_user;' \
		"SELECT set_config('request.jwt.claims','{\"sub\":\"${lr_u}\",\"aud\":\"osionos-account\",\"role\":\"osionos_account_user\"}', true);" \
		"DELETE FROM public.osionos_account_deletion_requests WHERE user_id = '${lr_u}';" \
		"\\! i=0; while [ ! -e ${lr_flag} ] && [ \$i -lt 400 ]; do sleep 0.05; i=\$((i+1)); done" 'COMMIT;' |
		psql_rows >"${WORK}/${lr_label}-cancel-$1.out" 2>"${WORK}/${lr_label}-cancel-$1.err" &
	lr_cancel=$!
	lr_i=0
	until [ "$(printf "SELECT xmax::text FROM public.osionos_account_deletion_requests WHERE user_id = '%s';\n" "${lr_u}" | psql_rows)" != 0 ] || [ "${lr_i}" -ge 200 ]; do
		sleep 0.1
		lr_i=$((lr_i + 1))
	done
	printf '%s\n' "SELECT public.osionos_account_erase('${lr_u}') IS NOT NULL;" |
		psql_rows >"${WORK}/${lr_label}-erase-$1.out" 2>"${WORK}/${lr_label}-erase-$1.err" &
	lr_erase=$!
	lr_i=0
	until [ "$(printf "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND pid <> pg_backend_pid() AND query LIKE '%%osionos_account_erase(%%%s%%';\n" "${lr_u}" | psql_rows)" -ge 1 ] || [ "${lr_i}" -ge 200 ]; do
		sleep 0.1
		lr_i=$((lr_i + 1))
	done
	lr_blocked=$((lr_i < 200))
	docker exec "${CTN}" touch "${lr_flag}"
	wait "${lr_cancel}" || true
	wait "${lr_erase}" || true
	docker exec "${CTN}" rm -f "${lr_flag}"
	lr_after="$(printf "SELECT md5(to_jsonb(u)::text) FROM public.users u WHERE id = '%s';\n" "${lr_u}" | psql_rows)"
	lr_reqs="$(printf "SELECT count(*) FROM public.osionos_account_deletion_requests WHERE user_id = '%s';\n" "${lr_u}" | psql_rows)"
	lr_objs="$(printf "SELECT count(*) FROM public.osionos_account_erasure_objects WHERE user_id = '%s';\n" "${lr_u}" | psql_rows)"
	if [ "${lr_blocked}" = 1 ] && grep -q 'no_deletion_request' "${WORK}/${lr_label}-erase-$1.err" &&
		[ "${lr_reqs}" = 0 ] && [ "${lr_objs}" = 0 ] && [ -n "${lr_before}" ] && [ "${lr_before}" = "${lr_after}" ]; then
		pass "$1" "${lr_label}" "the erase queued behind the cancel, raised no_deletion_request and changed nothing"
	else
		fail "$1" "${lr_label}" "queued=${lr_blocked} requests=${lr_reqs} objects=${lr_objs} users-row-same=$([ "${lr_before}" = "${lr_after}" ] && echo yes || echo no); $(head -2 "${WORK}/${lr_label}-erase-$1.err" | tr '\n' ' ')"
	fi
}

run_lock_races() {
	lr_d='c5c5c5c5-0000-4000-8000-0000000000d4'
	lr_e='c5c5c5c5-0000-4000-8000-0000000000e5'
	lr_clean="SET session_replication_role = replica; DELETE FROM public.osionos_account_deletion_requests WHERE user_id IN ('${lr_d}','${lr_e}'); DELETE FROM public.users WHERE id IN ('${lr_d}','${lr_e}'); DELETE FROM auth.users WHERE id IN ('${lr_d}','${lr_e}');"
	printf '%s\n' "${lr_clean}" | psql_rows >/dev/null 2>&1 || true
	if ! printf '%s\n' "SET session_replication_role = replica;" \
		"INSERT INTO auth.users (id) VALUES ('${lr_d}'), ('${lr_e}');" \
		"INSERT INTO public.users (id, email, name, username) VALUES ('${lr_d}', 'd@lock.test', 'Dee Lock', 'deelock'), ('${lr_e}', 'e@lock.test', 'Eve Lock', 'evelock');" \
		"INSERT INTO public.osionos_account_deletion_requests (user_id, requested_at, scheduled_for)" \
		"VALUES ('${lr_d}', now() - interval '30 days', now() - interval '1 day'), ('${lr_e}', now() - interval '30 days', now() - interval '1 day');" |
		psql_rows >"${WORK}/lock-seed-$1.out" 2>"${WORK}/lock-seed-$1.err"; then
		fail "$1" "p5_race_cancel_first" "could not seed the lock races: $(head -1 "${WORK}/lock-seed-$1.err")"
		fail "$1" "p5_race_cancel_after_claim" "could not seed the lock races"
		return 0
	fi
	lock_race "$1" cancel_first "${lr_d}" 0
	lock_race "$1" cancel_after_claim "${lr_e}" 1
	printf '%s\n' "${lr_clean}" | psql_rows >/dev/null 2>&1 || true
}

# run_races <scenario> — the two interleavings a single-session check cannot
# make. Two sessions, committed rows, a sleep to hold the first one open:
#  p5_race_claim   a second claimer must skip the row the first holds, and return
#                  the next one, inside 2 s (lock_timeout turns a wait into an error)
#  p5_race_cancel  a cancel that arrives while the erase holds the request is
#                  refused with deletion_in_progress once the erase commits
# run_lock_races then covers the other order, by a held lock and not a sleep:
#  p5_race_cancel_first        the cancel holds the request row, the erase queues
#                              behind it, the cancel commits: no_deletion_request
#  p5_race_cancel_after_claim  the same after the runner claimed the request
# Caveat: ordering is by sleep (session two starts 1.5 s after session one has taken
# its lock), so a loaded host can invert it; the claim race then reads as a FAIL
# (under-reporting a pass, never over-reporting one). Rows use fixed ids and are
# deleted on every exit path of the function.
run_races() {
	race_a='c5c5c5c5-0000-4000-8000-0000000000a1'
	race_b='c5c5c5c5-0000-4000-8000-0000000000b2'
	race_c='c5c5c5c5-0000-4000-8000-0000000000c3'
	race_clean="SET session_replication_role = replica; DELETE FROM public.osionos_account_deletion_requests WHERE user_id IN ('${race_a}','${race_b}','${race_c}'); DELETE FROM public.osionos_account_erasure_objects WHERE user_id IN ('${race_a}','${race_b}','${race_c}');"
	printf '%s\n' "${race_clean}" |
		psql_rows >"${WORK}/race-clean0-$1.out" 2>&1 || true
	if ! printf '%s\n' "SET session_replication_role = replica;" \
		"INSERT INTO public.osionos_account_deletion_requests (user_id, requested_at, scheduled_for)" \
		"VALUES ('${race_a}', now() - interval '30 days', now() - interval '3 days')," \
		"       ('${race_b}', now() - interval '30 days', now() - interval '2 days')," \
		"       ('${race_c}', now() - interval '30 days', now() - interval '1 day');" |
		psql_rows >"${WORK}/race-seed-$1.out" 2>"${WORK}/race-seed-$1.err"; then
		fail "$1" "p5_race_claim" "could not seed the due requests: $(head -1 "${WORK}/race-seed-$1.err")"
		fail "$1" "p5_race_cancel" "could not seed the due requests"
		return 0
	fi
	# Race 1: session one claims 1 (A) and holds; session two asks for 5 and must get B and C.
	printf '%s\n' 'BEGIN;' "SELECT user_id FROM public.osionos_account_deletion_claim(1);" 'SELECT pg_sleep(4);' 'COMMIT;' |
		psql_rows >"${WORK}/race1-a-$1.out" 2>"${WORK}/race1-a-$1.err" &
	race_pid=$!
	sleep 1.5
	printf '%s\n' 'BEGIN;' "SET LOCAL lock_timeout = '2s';" "SELECT user_id FROM public.osionos_account_deletion_claim(5) ORDER BY 1;" 'COMMIT;' |
		psql_rows >"${WORK}/race1-b-$1.out" 2>"${WORK}/race1-b-$1.err" || true
	wait "${race_pid}" || true
	got_a="$(grep -E '^[0-9a-f-]{36}$' "${WORK}/race1-a-$1.out" | tr '\n' ' ')"
	got_b="$(tr '\n' ' ' <"${WORK}/race1-b-$1.out")"
	race_att="$(printf "SELECT count(*) FROM public.osionos_account_deletion_requests WHERE user_id IN ('%s','%s','%s') AND attempts = 1 AND claimed_at IS NOT NULL;\n" "${race_a}" "${race_b}" "${race_c}" | psql_rows)"
	if [ "${got_a}" = "${race_a} " ] && [ "${got_b}" = "${race_b} ${race_c} " ] && [ "${race_att}" = 3 ]; then
		pass "$1" "p5_race_claim" "the second claimer skipped the held row and took the next two; each claim counted one attempt"
	else
		fail "$1" "p5_race_claim" "expected one claimer on ${race_a} and the other on ${race_b} ${race_c}, three claimed rows at attempts=1 (got ${race_att}); got [${got_a}] and [${got_b}] $(head -1 "${WORK}/race1-b-$1.err")"
	fi
	# Race 2: the erase of C holds the request open; the account role's cancel must lose.
	printf '%s\n' 'BEGIN;' "SELECT public.osionos_account_erase('${race_c}') IS NOT NULL;" 'SELECT pg_sleep(4);' 'COMMIT;' |
		psql_rows >"${WORK}/race2-a-$1.out" 2>"${WORK}/race2-a-$1.err" &
	race_pid=$!
	sleep 1.5
	printf '%s\n' '\set VERBOSITY verbose' 'BEGIN;' "SET LOCAL lock_timeout = '10s';" 'SET LOCAL ROLE osionos_account_user;' \
		"SELECT set_config('request.jwt.claims','{\"sub\":\"${race_c}\",\"aud\":\"osionos-account\",\"role\":\"osionos_account_user\"}', true);" \
		"DELETE FROM public.osionos_account_deletion_requests WHERE user_id = '${race_c}';" 'COMMIT;' |
		psql_rows >"${WORK}/race2-b-$1.out" 2>"${WORK}/race2-b-$1.err" || true
	wait "${race_pid}" || true
	left="$(printf "SELECT count(*) FROM public.osionos_account_deletion_requests WHERE user_id = '%s' AND erased_at IS NOT NULL;\n" "${race_c}" | psql_rows)"
	if grep -q 'deletion_in_progress' "${WORK}/race2-b-$1.err" && [ "${left}" = "1" ]; then
		pass "$1" "p5_race_cancel" "a cancel racing the erase was refused and the stamped request stayed"
	else
		fail "$1" "p5_race_cancel" "cancel racing the erase: stamped rows left ${left}; $(head -2 "${WORK}/race2-b-$1.err" | tr '\n' ' ')"
	fi
	printf '%s\n' "${race_clean}" | psql_rows >"${WORK}/race-clean-$1.out" 2>&1 || true
	run_lock_races "$1"
}

# lifecycle_race <scenario> — two parallel mark_delete calls for an owner's only two live
# workspaces: exactly one 'marked' and one 'last_workspace'. Ordered by a held lock and a flag
# file, never a sleep: session one marks W1 and keeps its locks, uncommitted, until the flag file
# appears; session two marks W2 and must queue on the owner's row locks; the flag is written only
# once pg_stat_activity shows session two waiting on a lock. Session two then wakes to a W1 that
# is pending and must answer last_workspace. Without the FOR UPDATE it never queues (and would
# read W1 as live), without the pending filter it counts W1 as a survivor.
# Caveat: the wait is a bounded poll (about 20 s); on a host too loaded to get there the case
# fails (a missing pass, never a false pass). Rows use fixed ids and are deleted on every exit.
lifecycle_race() {
	lc_o='e1e1e1e1-0000-4000-8000-0000000000d4'
	lc_1='e1e1e1e1-0000-4000-8000-0000000000d1'
	lc_2='e1e1e1e1-0000-4000-8000-0000000000d2'
	lc_flag="/tmp/lifecycle-race-$$.flag"
	lc_clean="DELETE FROM public.osionos_workspaces WHERE id IN ('${lc_1}','${lc_2}');"
	printf '%s\n' "${lc_clean}" | psql_rows >/dev/null 2>&1 || true
	docker exec "${CTN}" rm -f "${lc_flag}"
	if ! printf '%s\n' "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${lc_1}', '${lc_o}', 'lr1', 'lr-1'), ('${lc_2}', '${lc_o}', 'lr2', 'lr-2');" |
		psql_rows >"${WORK}/lc-seed-$1.out" 2>"${WORK}/lc-seed-$1.err"; then
		fail "$1" "lifecycle_race" "could not seed the race: $(head -1 "${WORK}/lc-seed-$1.err")"
		return 0
	fi
	printf '%s\n' 'BEGIN;' \
		"SELECT public.osionos_workspace_mark_delete('${lc_1}', '${lc_o}', now(), now() + interval '14 days');" \
		"\\! i=0; while [ ! -e ${lc_flag} ] && [ \$i -lt 400 ]; do sleep 0.05; i=\$((i+1)); done" 'COMMIT;' |
		psql_rows >"${WORK}/lc-one-$1.out" 2>"${WORK}/lc-one-$1.err" &
	lc_one=$!
	lc_i=0
	until [ "$(printf "SELECT xmax::text FROM public.osionos_workspaces WHERE id = '%s';\n" "${lc_1}" | psql_rows)" != 0 ] || [ "${lc_i}" -ge 200 ]; do
		sleep 0.1
		lc_i=$((lc_i + 1))
	done
	printf '%s\n' "SELECT public.osionos_workspace_mark_delete('${lc_2}', '${lc_o}', now(), now() + interval '14 days');" |
		psql_rows >"${WORK}/lc-two-$1.out" 2>"${WORK}/lc-two-$1.err" &
	lc_two=$!
	lc_i=0
	until [ "$(printf "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND pid <> pg_backend_pid() AND query LIKE '%%mark_delete(%%%s%%';\n" "${lc_2}" | psql_rows)" -ge 1 ] || [ "${lc_i}" -ge 200 ]; do
		sleep 0.1
		lc_i=$((lc_i + 1))
	done
	lc_blocked=$((lc_i < 200))
	docker exec "${CTN}" touch "${lc_flag}"
	wait "${lc_one}" || true
	wait "${lc_two}" || true
	docker exec "${CTN}" rm -f "${lc_flag}"
	lc_got="$(cat "${WORK}/lc-one-$1.out" "${WORK}/lc-two-$1.out" | grep -E '^(marked|last_workspace)$' | sort | tr '\n' ' ')"
	printf '%s\n' "${lc_clean}" | psql_rows >/dev/null 2>&1 || true
	if [ "${lc_blocked}" = 1 ] && [ "${lc_got}" = "last_workspace marked " ]; then
		pass "$1" "lifecycle_race" "the second delete queued behind the first and was refused as the last workspace"
	else
		fail "$1" "lifecycle_race" "queued=${lc_blocked} results=[${lc_got}] (want one marked, one last_workspace); $(head -1 "${WORK}/lc-two-$1.err")"
	fi
}

# p4_activity_maintain_concurrent <scenario> — maintain() while another maintain() holds its
# advisory lock inside an open transaction. Setup drops the next month's child so the holder has
# real work; the second caller must come back at once with ok and zero created instead of
# queueing or building the same partition twice. Without the advisory lock it blocks behind the
# holder's DDL and either waits out lock_timeout (ok = f) or duplicates the work.
# Caveat: ordering is by sleep (the second session starts 1.5 s into the holder's 4 s hold), so a
# loaded host can invert it; that reads as a FAIL (a missing pass, never a false pass).
p4_activity_maintain_concurrent() {
	ac_child="osionos_activity_events_y$(printf "SELECT to_char(date_trunc('month', now() AT TIME ZONE 'UTC') + interval '2 months', 'YYYYMM');\n" | psql_rows)"
	printf 'DROP TABLE IF EXISTS public.%s;\n' "${ac_child}" | psql_rows >/dev/null 2>&1 || true
	printf '%s\n' 'BEGIN;' 'SELECT ok, created FROM public.osionos_activity_maintain();' 'SELECT pg_sleep(4);' 'COMMIT;' |
		psql_rows >"${WORK}/ac-one-$1.out" 2>"${WORK}/ac-one-$1.err" &
	ac_pid=$!
	sleep 1.5
	printf '%s\n' "SELECT ok, created FROM public.osionos_activity_maintain();" |
		psql_rows >"${WORK}/ac-two-$1.out" 2>"${WORK}/ac-two-$1.err" || true
	wait "${ac_pid}" || true
	ac_one="$(head -1 "${WORK}/ac-one-$1.out")"
	ac_two="$(head -1 "${WORK}/ac-two-$1.out")"
	ac_n="$(printf "SELECT count(*) FROM pg_class WHERE relname = '%s';\n" "${ac_child}" | psql_rows)"
	if [ "${ac_one}" = "t|1" ] && [ "${ac_two}" = "t|0" ] && [ "${ac_n}" = 1 ]; then
		pass "$1" "p4_activity_maintain_concurrent" "the second maintain skipped while the first held the lock; one child built"
	else
		fail "$1" "p4_activity_maintain_concurrent" "holder=[${ac_one}] second=[${ac_two}] children=${ac_n} (want t|1, t|0, 1); $(head -1 "${WORK}/ac-two-$1.err")"
	fi
}

# p4_activity_maintain_lock_timeout <scenario> — a session holds ACCESS EXCLUSIVE on the events
# table; maintain() needs that lock to build a missing month. It must give up on its own
# lock_timeout (2 s) with ok = f, not queue behind the holder (and every writer behind it).
# Caveat: bounded by wall clock (under 5 s against a 6 s hold); a host stalled for seconds can
# fail it (a missing pass, never a false pass).
p4_activity_maintain_lock_timeout() {
	ac_child="osionos_activity_events_y$(printf "SELECT to_char(date_trunc('month', now() AT TIME ZONE 'UTC') + interval '2 months', 'YYYYMM');\n" | psql_rows)"
	printf 'DROP TABLE IF EXISTS public.%s;\n' "${ac_child}" | psql_rows >/dev/null 2>&1 || true
	printf '%s\n' 'BEGIN;' 'LOCK TABLE public.osionos_activity_events IN ACCESS EXCLUSIVE MODE;' 'SELECT pg_sleep(6);' 'COMMIT;' |
		psql_rows >"${WORK}/ac-hold-$1.out" 2>"${WORK}/ac-hold-$1.err" &
	ac_pid=$!
	sleep 1.5
	ac_t0="$(date +%s)"
	printf '%s\n' "SELECT ok FROM public.osionos_activity_maintain();" |
		psql_rows >"${WORK}/ac-lt-$1.out" 2>"${WORK}/ac-lt-$1.err" || true
	ac_dt=$(($(date +%s) - ac_t0))
	wait "${ac_pid}" || true
	ac_got="$(head -1 "${WORK}/ac-lt-$1.out")"
	printf '%s\n' "SELECT ok FROM public.osionos_activity_maintain();" | psql_rows >/dev/null 2>&1 || true
	if [ "${ac_got}" = "f" ] && [ "${ac_dt}" -lt 5 ]; then
		pass "$1" "p4_activity_maintain_lock_timeout" "gave up after ${ac_dt}s with ok = f while the table was locked"
	else
		fail "$1" "p4_activity_maintain_lock_timeout" "result=[${ac_got}] after ${ac_dt}s (want f in under 5s); $(head -1 "${WORK}/ac-lt-$1.err")"
	fi
}

# p4_activity_registry_reapply <scenario> — the erasure migration replays cleanly and keeps the
# activity row exactly once, and the runner applies the analytics file before the erasure file.
# Caveat: the order check is textual (position of each name in the ORDERED_LAST line), not a run.
p4_activity_registry_reapply() {
	ac_bad=0
	for ac_i in 1 2; do
		apply "${MODELS_DIR}/osionos-account-erasure-migration.sql" || ac_bad=1
	done
	ac_rows="$(printf "SELECT count(*) FROM public.osionos_account_data_map WHERE table_name = 'osionos_activity_events' AND column_name = 'user_id' AND erase = 'delete';\n" | psql_rows)"
	ac_order="$(awk '/^ORDERED_LAST=/ { a = index($0, "osionos-activity-analytics-migration.sql"); e = index($0, "osionos-account-erasure-migration.sql"); r = (a > 0 && e > a) ? "ok" : "bad" } END { print r }' "${RUNNER}")"
	if [ "${ac_bad}" = 0 ] && [ "${ac_rows}" = 1 ] && [ "${ac_order}" = ok ]; then
		pass "$1" "p4_activity_registry_reapply" "two replays left one registry row; analytics file precedes erasure in the runner"
	else
		fail "$1" "p4_activity_registry_reapply" "replay_failed=${ac_bad} rows=${ac_rows} order=${ac_order}"
	fi
}

run_scenario() {
	CTN="models-grants-$1-$$"
	note "scenario $1 — container ${CTN}"
	docker run --rm --network none --name "${CTN}" -e POSTGRES_HOST_AUTH_METHOD=trust \
		-d "${IMAGE}" >/dev/null 2>&1 || die "scenario" "setup/$1" "${IMAGE} did not start"
	wait_ready || die "scenario" "setup/$1" "pg_isready never answered in ${READY_TIMEOUT}s"
	apply "${FIX}/roles.sql" || die "scenario" "setup/$1" "roles.sql"
	if [ "$1" = "legacy" ]; then
		apply "${FIX}/legacy-default.sql" || die "scenario" "setup/$1" "legacy-default.sql"
	fi
	# grobase applies 001 with fly; its '#' lines are not SQL, so psql gets them stripped.
	grep -v '^#' "${GROBASE_INIT}" >"${WORK}/001.sql" ||
		die "scenario" "setup/$1" "could not read ${GROBASE_INIT}"
	apply "${WORK}/001.sql" || die "scenario" "setup/$1" "001_initial_schema.sql"
	grep -v '^#' "${GROBASE_REALTIME}" >"${WORK}/012.sql" ||
		die "scenario" "setup/$1" "could not read ${GROBASE_REALTIME}"
	apply "${WORK}/012.sql" || die "scenario" "setup/$1" "012_realtime_triggers_all_tables.sql"
	apply "${FIX}/shim.sql" || die "scenario" "setup/$1" "shim.sql"
	if [ "$1" = "legacy" ]; then
		apply "${FIX}/legacy-audit.sql" || die "scenario" "setup/$1" "legacy-audit.sql"
	fi
	run_runner "$1" first
	if [ "$1" = "legacy" ]; then
		apply "${FIX}/legacy-reboot.sql" || die "scenario" "setup/$1" "legacy-reboot.sql"
		run_runner "$1" reboot
	fi
	run_checks "$1"
	drop_container
}

ensure_image() {
	if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
		return 0
	fi
	note "pulling ${IMAGE}"
	if docker pull "${IMAGE}" >/dev/null 2>&1; then
		return 0
	fi
	printf 'FAIL image %s\n' "${IMAGE}"
	exit 1
}

main() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"
		exit 2
	}
	[ -f "${RUNNER}" ] || die "setup" "runner" "no ${RUNNER}"
	[ -f "${GROBASE_INIT}" ] || die "setup" "grobase" "no ${GROBASE_INIT} — check out the apps/grobase submodule"
	[ -d "${MODELS_DIR}" ] || die "setup" "models" "no ${MODELS_DIR}"
	ensure_image
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/models-grants.XXXXXX")"
	run_scenario fresh
	run_scenario legacy
	if [ "${failed}" -eq 0 ]; then
		finish 0
	fi
	finish 1
}

main "$@"
