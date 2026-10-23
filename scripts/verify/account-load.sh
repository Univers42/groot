#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    account-load.sh                                                           #
#                                                                              #
#    Prove the account-plane query budgets on a 10K-user seeded database.      #
#                                                                              #
# **************************************************************************** #
#
# WHY: 10K-user ceilings are in the DB: unindexed people-directory view,
# reads with no limit, in.() lists, scans on email_hash. Measure on a seeded
# 10K DB in a throwaway container so P0-5/P1-1 show before/after.
#
# WHAT: fresh grobase postgres -> 001 + 012 -> shim -> apply-models-migrations.sh
# -> seed-10k.sql -> ANALYZE -> each query RUNS times with EXPLAIN ANALYZE.
#
# THE BUDGET KEYS (scripts/verify/account-load/budgets.json, one entry per query)
#   p95_ms             the p95 of the EXPLAIN ANALYZE times, in ms
#   no_seq_scan        the relations the plan must not scan sequentially: a
#                      sequential scan of one of them fails the query
#   require_plan_nodes  OPTIONAL. The EXPLAIN (FORMAT JSON) plan must hold a
#                      node of each listed "Node Type" (e.g. "Bitmap Index
#                      Scan"). A plan without it fails the query, and the FAIL
#                      line names the node type that was missing: it says
#                      which PLAN a query has to come back with, where
#                      no_seq_scan only says what it must not scan.
#   why                what the plan is supposed to look like, and why
#
# A QUERY THAT ERRORS FAILS. A run whose EXPLAIN fails has no measurement, and
# percentiles() prints 0.00 for an empty file — a p95 of 0.00 passes every
# budget. The FAIL line carries the first line of the error.
#
# ISOLATION: throwaway container (--rm --network none), never touches live.
# CAVEATS: 1. Idle container under-reports prod latency (no concurrency/warm cache).
# 2. p95 over 30 runs is coarse.
# Usage: [GROBASE_PG_IMAGE=…] [MODELS_DIR=…] [RUNS=30] sh scripts/verify/account-load.sh [--baseline]
# Exit: 0 all within budget · 1 breach/failure · 2 docker missing. --baseline
# reports, exits 0 unless harness failed. Ponytail: container bring-up copied
# from models-grants.sh until shared helper lands.
#
set -eu
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="${REPO}/scripts/verify/account-load"
RUNNER="${REPO}/scripts/apply-models-migrations.sh"
GROBASE_INIT="${REPO}/apps/grobase/scripts/migrations/postgresql/001_initial_schema.sql"
GROBASE_REALTIME="${REPO}/apps/grobase/scripts/migrations/postgresql/012_realtime_triggers_all_tables.sql"
IMAGE="${GROBASE_PG_IMAGE:-ghcr.io/univers42/grobase-postgres:latest}"
MODELS_DIR="${MODELS_DIR:-${REPO}/models}"
READY_TIMEOUT=60
PG_USER=postgres
PG_DB=postgres
RUNS="${RUNS:-30}"
BASELINE=0
[ "${1:-}" = "--baseline" ] && BASELINE=1
CTN=''
WORK=''
passed=0
failed=0
# shellcheck disable=SC1091
. "${FIX}/measure.sh"
# shellcheck disable=SC1091
. "${FIX}/self-test.sh"
note() { printf '[account-load] %s\n' "$*" >&2; }
# shellcheck disable=SC2317
pass_query() { passed=$((passed + 1)) && printf 'PASS %s p50=%s p95=%s seq_scan=%s budget=%s%s%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }
# shellcheck disable=SC2317
fail_query() { failed=$((failed + 1)) && printf 'FAIL %s p50=%s p95=%s seq_scan=%s budget=%s%s%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }
# shellcheck disable=SC2317
fail_step() { failed=$((failed + 1)) && printf 'FAIL %s %s %s\n' "$1" "$2" "$3"; }
die() {
	fail_step "$@"
	finish 1
}
finish() {
	printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
	exit "$1"
}
cleanup() {
	# shellcheck disable=SC2317
	if [ -n "${CTN}" ]; then
		docker rm -f "${CTN}" >/dev/null 2>&1 || true
	fi
	# shellcheck disable=SC2317
	CTN=''
	# shellcheck disable=SC2317
	rm -rf "${WORK}"
}
trap 'cleanup' EXIT INT TERM
# shellcheck disable=SC2317
psql_stdin() {
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q
}
# shellcheck disable=SC2317
psql_rows() {
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q -At
}
apply() {
	if psql_stdin <"$1" >"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}
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
run_runner() {
	log="${WORK}/runner-$1.log"
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
		fail_step "runner" "exit ${rc}" "— ${last}"
		grep -h 'FAILED:' "${log}" | sed 's/^/  | /' >&2 || true
		finish 1
	fi
	note "runner: ${last}"
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
	[ -f "${FIX}/seed-10k.sql" ] || die "setup" "seed" "no ${FIX}/seed-10k.sql"
	[ -f "${FIX}/queries.sql" ] || die "setup" "queries" "no ${FIX}/queries.sql"
	[ -f "${FIX}/budgets.json" ] || die "setup" "budgets" "no ${FIX}/budgets.json"
	[ -f "${FIX}/self-test.sh" ] || die "setup" "self-test" "no ${FIX}/self-test.sh"
	ensure_image
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/account-load.XXXXXX")"
	CTN="account-load-$$"
	note "container ${CTN} (image: ${IMAGE})"
	docker run --rm --network none --name "${CTN}" -e POSTGRES_HOST_AUTH_METHOD=trust \
		-d "${IMAGE}" >/dev/null 2>&1 || die "setup" "container" "${IMAGE} did not start"
	wait_ready || die "setup" "container" "pg_isready never answered in ${READY_TIMEOUT}s"
	# Apply roles fixture (creates anon, authenticated, service_role roles)
	apply "${REPO}/scripts/verify/models-grants/roles.sql" || die "setup" "roles" "roles.sql"
	# Apply grobase initial schema (strip # comments)
	grep -v '^#' "${GROBASE_INIT}" >"${WORK}/001.sql" || die "setup" "grobase" "could not read ${GROBASE_INIT}"
	apply "${WORK}/001.sql" || die "setup" "grobase" "001_initial_schema.sql"
	# Apply realtime triggers
	grep -v '^#' "${GROBASE_REALTIME}" >"${WORK}/012.sql" || die "setup" "grobase" "could not read ${GROBASE_REALTIME}"
	apply "${WORK}/012.sql" || die "setup" "grobase" "012_realtime_triggers_all_tables.sql"
	# Apply shim (for auth.users, user_profiles)
	apply "${REPO}/scripts/verify/models-grants/shim.sql" || die "setup" "shim" "shim.sql"
	# Run the real migrations runner
	run_runner "first"
	# Seed 10K users
	note "seeding 10K users..."
	seed_start="$(date +%s)"
	if ! psql_stdin <"${FIX}/seed-10k.sql" >"${WORK}/seed.log" 2>&1; then
		note "seed-10k.sql failed"
		sed 's/^/  | /' "${WORK}/seed.log" >&2
		die "seed" "seed-10k.sql" "seed failed"
	fi
	seed_end="$(date +%s)"
	seed_time=$((seed_end - seed_start))
	note "seed completed in ${seed_time}s"
	if [ "${seed_time}" -gt 120 ]; then
		note "WARNING: seed time ${seed_time}s exceeds 120s budget"
	fi
	# ANALYZE for planner statistics
	note "running ANALYZE..."
	psql_stdin <<'SQL' >/dev/null 2>&1
ANALYZE;
SQL
	# Create _known_users table for queries (regular table, persists across psql sessions)
	note "creating _known_users table..."
	psql_stdin <<'SQL' >/dev/null 2>&1
CREATE TABLE _known_users (user_id uuid PRIMARY KEY);
INSERT INTO _known_users (user_id)
SELECT md5(('user-' || u::text))::uuid
FROM generate_series(1, 5) AS idx
CROSS JOIN LATERAL (VALUES (1), (100), (1000), (5000), (9999)) AS v(u)
WHERE idx = 1;
SQL
	# Run self-test for has_seq_scan_on
	self_test_has_seq_scan_on || die "self-test" "has_seq_scan_on" "self-test failed"
	self_test_missing_node_types || die "self-test" "missing_node_types" "self-test failed"
	self_test_error_query_fails || die "self-test" "error_query_fails" "self-test failed"
	# Split queries.sql into individual query files
	mkdir -p "${WORK}/queries"
	awk -v work="${WORK}/queries" '
		/^-- QUERY: / {
			if (id) close(outfile)
			id = $3
			outfile = work "/" id ".sql"
			next
		}
		id { print > outfile }
	' "${FIX}/queries.sql"
	# Measure each query
	note "running ${RUNS}x each query..."
	for query_file in "${WORK}/queries"/*.sql; do
		[ -f "${query_file}" ] || continue
		id="$(basename "${query_file}" .sql)"
		
		note "query ${id}: ${RUNS} runs"
		
		# Get budget for this query from budgets.json
		budget_ms="$(grep -A3 "\"${id}\"" "${FIX}/budgets.json" | grep '"p95_ms"' | sed 's/.*: *\([0-9]*\).*/\1/')"
		[ -z "${budget_ms}" ] && budget_ms=0
		
		# Get no_seq_scan tables for this query
		# Extract only the table names from the no_seq_scan array
		seq_scan_tables="$(python3 -c "
import sys, json
with open('${FIX}/budgets.json') as f:
    data = json.load(f)
query = data.get('${id}', {})
tables = query.get('no_seq_scan', [])
print(' '.join(tables))
" 2>/dev/null)"

		# Get the plan node types this query must come back with (optional).
		# They are joined with '|' because a node type holds spaces.
		require_nodes="$(python3 -c "
import sys, json
with open('${FIX}/budgets.json') as f:
    data = json.load(f)
query = data.get('${id}', {})
print('|'.join(query.get('require_plan_nodes', [])))
" 2>/dev/null)"

		times_file="${WORK}/times-${id}.txt"
		seq_scans_file="${WORK}/seq_scans-${id}.txt"
		budgeted_scan_flag="${WORK}/budgeted_scan-${id}.flag"
		missing_nodes_file="${WORK}/missing_nodes-${id}.txt"
		errors_file="${WORK}/errors-${id}.txt"

		# Run measurement
		measure_query "${query_file}" "${RUNS}" "${budget_ms}" "${seq_scan_tables}" \
			"${require_nodes}" "${times_file}" "${seq_scans_file}" "${budgeted_scan_flag}" \
			"${missing_nodes_file}" "${errors_file}"

		# Evaluate and print result
		if [ -f "${times_file}" ]; then
			# shellcheck disable=SC2046
			set -- $(percentiles "${times_file}")
			p50=$1
			p95=$2
			evaluate_query "${id}" "${p50}" "${p95}" "${seq_scans_file}" "${budget_ms}" \
				"${budgeted_scan_flag}" "${missing_nodes_file}" "${times_file}" "${errors_file}" || true
		else
			fail_query "${id}" "0.00" "0.00" "none" "${budget_ms}" "" " error=no measurement"
		fi
	done
	# Write JSON output
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	git_sha="$(git rev-parse HEAD 2>/dev/null || echo 'unknown')"
	mkdir -p "${REPO}/target/account-load"
	output_json="${REPO}/target/account-load/${timestamp}.json"
	
	write_json_output "${WORK}" "${RUNS}" "${seed_time}" "${REPO}" "${IMAGE}" "${git_sha}" "${timestamp}" "${output_json}"
	
	note "results written to ${output_json}"
	
	if [ "${BASELINE}" -eq 1 ]; then
		finish 0
	fi
	
	if [ "${failed}" -eq 0 ]; then
		finish 0
	fi
	finish 1
}
main "$@"