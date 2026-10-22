#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    models-grants.sh                                                          #
#                                                                              #
#    Prove every public.osionos_* relation and auth_session_cutoffs is        #
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
#   legacy  roles -> the pre-1e407614 default privileges -> 001 -> shim -> runner
#           -> an old-bootstrap boot (blanket GRANT, DEFAULT revoked) -> runner -> checks
#   Checks: c no anon/authenticated privilege on an osionos_% relation or on
#   auth_session_cutoffs · d no policy for PUBLIC/anon/authenticated · e1/e2 service_role
#   has full CRUD and round-trips a row · e3 it upserts a session cut-off as the
#   auth-gateway does · e4 a late, older upsert leaves the newer cut-off in place · f six probes, and S1-S3 on auth_session_cutoffs, refused with 42501 · h no SECURITY DEFINER osionos_% function
#   they may execute · g a second runner pass changes no ACL, policy or RLS flag ·
#   n the final notifications type CHECK admits every type the models files declare ·
#   r no public table keeps a realtime_notify() trigger (it broadcasts rows past every grant),
#   and r-cutoffs asserts it for auth_session_cutoffs by name ·
#   rt grobase's CREATE TABLE hook that re-arms new tables exists and is disabled ·
#   u anon cannot SELECT public.users.email or password_hash, authenticated cannot SELECT password_hash
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
#   marked · k4 the account indexes exist · k7 the role has the right shape and
#   no membership beyond authenticator · k8 the role may SELECT exactly nine
#   session columns and nothing else · k5 the role sees only its own rows (1) ·
#   k6 no forged claim set sees any (0) · K1-K6 six probes on the account plane,
#   refused with 42501 · account_secdef_exec the account role may execute no
#   SECURITY DEFINER osionos_% function · standalone the account foundation file
#   applied alone leaves no realtime trigger on the sessions table or on the
#   audit table, no anon/authenticated privilege and exactly the nine column
#   grants — what the ledger runner (scripts/apply-models.sh) relies on, and
#   what the later passes hide
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
check_standalone() {
	file="${MODELS_DIR}/osionos-account-foundation-migration.sql"
	if [ ! -f "${file}" ]; then
		fail "$1" "standalone" "no ${file}"
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

run_checks() {
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
	check_svc "$1" e4 svc_cutoff_monotonic
	probe "$1" T1 authenticated "SELECT count(*) FROM public.osionos_pages"
	probe "$1" T2 authenticated "DELETE FROM public.osionos_pages"
	probe "$1" T3 authenticated "UPDATE public.osionos_pages SET owner_id='cccccccc-cccc-cccc-cccc-cccccccccccc', visibility='public'"
	probe "$1" V1 anon "SELECT user_id, display_name FROM public.osionos_directory"
	probe "$1" V4 anon "UPDATE public.osionos_directory SET display_name='x'"
	probe "$1" V5 anon "DELETE FROM public.osionos_directory"
	probe "$1" S1 authenticated "SELECT user_id, sessions_valid_after FROM public.auth_session_cutoffs"
	probe "$1" S2 anon "INSERT INTO public.auth_session_cutoffs (user_id) VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')"
	probe "$1" S3 authenticated "UPDATE public.auth_session_cutoffs SET sessions_valid_after = 'epoch'"
	check_count "$1" h secdef_exec
	check_count "$1" n notify_types_missing
	check_count "$1" r realtime_triggers
	check_count "$1" r-cutoffs cutoff_realtime_triggers
	check_count "$1" rt realtime_event_trigger
	check_count "$1" u users_pii
	check_count "$1" k1 account_role_reach
	check_count "$1" k2 account_plane_rls
	check_count "$1" k3 account_plane_expected
	check_count "$1" k4 account_indexes_missing
	check_count "$1" k7 account_role_shape
	check_count "$1" k8 account_session_columns
	check_count "$1" h2 account_secdef_exec
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
