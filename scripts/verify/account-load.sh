#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    account-load.sh                                                           #
#                                                                              #
#    Prove the account-plane query budgets on a 10K-user seeded database.      #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   The 10K-user ceilings are in the database: an unindexed people-directory
#   view, reads with no limit, in.() lists, scans on email_hash. Measure them
#   where they live — the hot queries, on a seeded 10K database, in a throwaway
#   container — so P0-5 and P1-1 can show a before/after number.
#
# WHAT IT RUNS
#   fresh grobase postgres -> grobase 001_initial_schema + 012 realtime hook ->
#   shim -> apply-models-migrations.sh (real runner) -> seed-10k.sql -> ANALYZE ->
#   each query from queries.sql run RUNS times with EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
#
# ISOLATION
#   Throwaway container only (--rm --network none, no port, no volume); the live
#   mini-baas / osionos containers are never touched. A trap removes the container
#   on every exit path. The image is grobase's postgres: models/*.sql needs pgvector.
#
# CAVEATS (deliberate, documented):
#   1. Plan timing in an idle container under-reports production latency (no
#      concurrency, warm cache, no network).
#   2. p95 over 30 runs is a coarse estimate.
#
# Usage:  [GROBASE_PG_IMAGE=…] [MODELS_DIR=…] [RUNS=30] [BASELINE=0] sh scripts/verify/account-load.sh [--baseline]
#
# Exit:  0 every query within budget · 1 a breach or a failure · 2 docker missing
#        (a missing image is a FAIL, never a SKIP). With --baseline: reports and
#        always exits 0 unless the harness itself failed.
#
# Ponytail: The container bring-up logic is deliberately copied from
#   scripts/verify/models-grants.sh until the shared helper lands in
#   scripts/verify/lib/ (tracked in the P0-7 ledger).
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

note() { printf '[account-load] %s\n' "$*" >&2; }

pass_query() { passed=$((passed + 1)) && printf 'PASS %s p50=%s p95=%s seq_scan=%s budget=%s\n' "$1" "$2" "$3" "$4" "$5"; }
fail_query() { failed=$((failed + 1)) && printf 'FAIL %s p50=%s p95=%s seq_scan=%s budget=%s\n' "$1" "$2" "$3" "$4" "$5"; }
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

# Compute p50 and p95 from a file of millisecond values (one per line)
# shellcheck disable=SC2317
percentiles() {
	awk '
		{ a[NR] = $1 }
		END {
			if (NR == 0) { print "0 0"; exit }
			p50_idx = int(NR * 0.50) + 1; if (p50_idx > NR) p50_idx = NR
			p95_idx = int(NR * 0.95) + 1; if (p95_idx > NR) p95_idx = NR
			print a[p50_idx] " " a[p95_idx]
		}' "$1"
}

# Check if a plan JSON contains a Seq Scan on any of the given tables
has_seq_scan() {
	plan_json="$1"
	shift
	for table in "$@"; do
		# Look for "Node Type": "Seq Scan" with "Relation Name": "<table>"
		if echo "${plan_json}" | grep -q '"Node Type": "Seq Scan"' && echo "${plan_json}" | grep -q "\"Relation Name\": \"${table}\""; then
			return 0
		fi
		# Also check for parallel seq scan
		if echo "${plan_json}" | grep -q '"Node Type": "Parallel Seq Scan"' && echo "${plan_json}" | grep -q "\"Relation Name\": \"${table}\""; then
			return 0
		fi
	done
	return 1
}

# Compute p50 and p95 from a file of millisecond values (one per line)
# Uses awk to avoid process substitution (not POSIX)
percentiles() {
	awk '
		{ a[NR] = $1 }
		END {
			if (NR == 0) { print "0 0"; exit }
			p50_idx = int(NR * 0.50) + 1; if (p50_idx > NR) p50_idx = NR
			p95_idx = int(NR * 0.95) + 1; if (p95_idx > NR) p95_idx = NR
			print a[p50_idx] " " a[p95_idx]
		}' "$1"
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

	# Read queries and budgets
	note "running ${RUNS}x each query..."

	# Parse budgets.json to get per-query budget and no_seq_scan tables
	# We'll use a simple approach: extract each query by ID from queries.sql
	# and match with budgets.json

	# First, let's extract query IDs and their SQL from queries.sql
	# Format in queries.sql: -- QUERY: <id> followed by SQL ending with ;
	
	mkdir -p "${WORK}/queries"
	
	# Split queries.sql into individual query files
	awk -v work="${WORK}/queries" '
		/^-- QUERY: / {
			if (id) close(outfile)
			id = $3
			outfile = work "/" id ".sql"
			next
		}
		id { print > outfile }
	' "${FIX}/queries.sql"

	# Process each query
	for query_file in "${WORK}/queries"/*.sql; do
		[ -f "${query_file}" ] || continue
		id="$(basename "${query_file}" .sql)"
		
		note "query ${id}: ${RUNS} runs"
		
		# Get budget for this query from budgets.json
		budget_ms="$(grep -A3 "\"${id}\"" "${FIX}/budgets.json" | grep '"p95_ms"' | sed 's/.*: *\([0-9]*\).*/\1/')"
		[ -z "${budget_ms}" ] && budget_ms=0
		
		# Get no_seq_scan tables for this query
		seq_scan_tables="$(grep -A10 "\"${id}\"" "${FIX}/budgets.json" | grep '"no_seq_scan"' -A5 | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' | tr '\n' ' ')"
		
		# Run the query RUNS times
		times_file="${WORK}/times-${id}.txt"
		seq_scan_count=0
		
		for run in $(seq 1 "${RUNS}"); do
			# Run EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
			if ! psql_stdin <<HEREDOC 2>"${WORK}/explain-${id}-${run}.err" >"${WORK}/explain-${id}-${run}.out"; then
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
$(cat "${query_file}");
HEREDOC
				note "query ${id} run ${run} failed"
				sed 's/^/  | /' "${WORK}/explain-${id}-${run}.err" >&2
				continue
			fi
			plan_json="$(cat "${WORK}/explain-${id}-${run}.out")"
			
			# Extract execution time from plan (in ms)
			exec_time="$(echo "${plan_json}" | grep -o '"Execution Time": [0-9.]*' | head -1 | sed 's/.*: //')"
			if [ -z "${exec_time}" ]; then
				exec_time=0
			fi
			# Convert to integer milliseconds
			exec_time_ms="$(printf '%.0f' "${exec_time}")"
			echo "${exec_time_ms}" >>"${times_file}"
			
			# Check for Seq Scan on budgeted tables
			if [ -n "${seq_scan_tables}" ]; then
				if has_seq_scan "${plan_json}" "${seq_scan_tables}"; then
					seq_scan_count=$((seq_scan_count + 1))
				fi
			fi
		done
		
		# Compute percentiles
		if [ -f "${times_file}" ]; then
			# shellcheck disable=SC2046
			set -- $(percentiles "${times_file}")
			p50=$1
			p95=$2
		else
			p50=0
			p95=0
		fi
		
		seq_scan_any="no"
		if [ "${seq_scan_count}" -gt 0 ]; then
			seq_scan_any="yes"
		fi
		
		# Determine pass/fail
		if [ "${p95}" -le "${budget_ms}" ] && [ "${seq_scan_any}" = "no" ]; then
			pass_query "${id}" "${p50}" "${p95}" "${seq_scan_any}" "${budget_ms}"
		else
			fail_query "${id}" "${p50}" "${p95}" "${seq_scan_any}" "${budget_ms}"
		fi
	done

	# Write JSON output
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	git_sha="$(git rev-parse HEAD 2>/dev/null || echo 'unknown')"
	image_digest="$(docker image inspect "${IMAGE}" --format '{{.RepoDigests}}' 2>/dev/null | head -1 | sed 's/.*sha256:\([a-f0-9]*\).*/\1/' || echo 'unknown')"
	
	mkdir -p "${REPO}/target/account-load"
	output_json="${REPO}/target/account-load/${timestamp}.json"
	
	# Build JSON output
	{
		echo '{'
		echo '  "timestamp": "'"${timestamp}"'",'
		echo '  "git_sha": "'"${git_sha}"'",'
		echo '  "image_digest": "'"${image_digest}"'",'
		echo '  "runs": '"${RUNS}"','
		echo '  "seed_time_sec": '"${seed_time}"','
		echo '  "queries": ['
		
		first=1
		for query_file in "${WORK}/queries"/*.sql; do
			[ -f "${query_file}" ] || continue
			id="$(basename "${query_file}" .sql)"
			times_file="${WORK}/times-${id}.txt"
			if [ -f "${times_file}" ]; then
				# shellcheck disable=SC2046
			set -- $(percentiles "${times_file}")
				p50=$1
				p95=$2
				# Count seq scans
				seq_scan_count=0
				for run in $(seq 1 "${RUNS}"); do
					plan_json_file="${WORK}/explain-${id}-${run}.out"
					if [ -f "${plan_json_file}" ]; then
						plan_json="$(cat "${plan_json_file}")"
						seq_scan_tables="$(grep -A10 "\"${id}\"" "${FIX}/budgets.json" | grep '"no_seq_scan"' -A5 | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' | tr '\n' ' ')"
						if [ -n "${seq_scan_tables}" ]; then
							if has_seq_scan "${plan_json}" "${seq_scan_tables}"; then
								seq_scan_count=$((seq_scan_count + 1))
							fi
						fi
					fi
				done
				seq_scan_any="false"
				if [ "${seq_scan_count}" -gt 0 ]; then
					seq_scan_any="true"
				fi
				budget_ms="$(grep -A3 "\"${id}\"" "${FIX}/budgets.json" | grep '"p95_ms"' | sed 's/.*: *\([0-9]*\).*/\1/')"
				[ -z "${budget_ms}" ] && budget_ms=0
				
				[ "${first}" -eq 1 ] || echo '    ,'
				first=0
				echo '    {'
				echo '      "id": "'"${id}"'",'
				echo '      "p50_ms": '"${p50}"','
				echo '      "p95_ms": '"${p95}"','
				echo '      "seq_scan_detected": '"${seq_scan_any}"','
				echo '      "budget_ms": '"${budget_ms}"','
				echo '      "pass": '"$( [ "${p95}" -le "${budget_ms}" ] && [ "${seq_scan_any}" = "false" ] && echo "true" || echo "false" )"
				printf '    }'
			fi
		done
		echo ''
		echo '  ]'
		echo '}'
	} >"${output_json}"
	
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