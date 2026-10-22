#!/bin/sh
# **************************************************************************** #
# measure.sh — Query measurement and reporting for account-load
# WHY: Separated to keep each file ≤300 lines. Handles EXPLAIN ANALYZE runs,
# percentile computation, seq-scan detection, pass/fail, JSON output.
# Ponytail: small, no deps beyond POSIX sh + awk + python3.
# Compute p50/p95 nearest-rank on sorted numeric values.
# Input: file with one float ms per line from EXPLAIN JSON "Execution Time".
# Output: "p50 p95" with 2 decimals. Nearest-rank: p = sorted[ceil(q/100*n)-1].
percentiles() {
	awk '
		{ a[NR] = $1 }
		END {
			if (NR == 0) { print "0.00 0.00"; exit }
			for (i = 1; i <= NR; i++)
				for (j = i + 1; j <= NR; j++)
					if (a[i] > a[j]) { t = a[i]; a[i] = a[j]; a[j] = t }
			p50_idx = int(0.50 * NR) + (0.50 * NR > int(0.50 * NR) ? 1 : 0)
			p95_idx = int(0.95 * NR) + (0.95 * NR > int(0.95 * NR) ? 1 : 0)
			if (p50_idx < 1) p50_idx = 1
			if (p50_idx > NR) p50_idx = NR
			if (p95_idx < 1) p95_idx = 1
			if (p95_idx > NR) p95_idx = NR
			printf "%.2f %.2f\n", a[p50_idx], a[p95_idx]
		}' "$1"
}
# Print the JSON of an EXPLAIN (FORMAT JSON) output. psql wraps it in a
# header, a row of dashes and a frame; the parser below has to skip those.
# Input: the raw EXPLAIN output on stdin. Output: the JSON, on stdout.
plan_json() {
	python3 -c "
import sys
lines = sys.stdin.read().strip().split('\n')
json_lines = [l.rstrip(' +') for l in lines if l.strip() and not l.strip().startswith('-') and 'QUERY PLAN' not in l and not all(c == '-' for c in l.strip())]
json_str = '\n'.join(json_lines)
depth = 0; end_idx = 0
for i, ch in enumerate(json_str):
    if ch in '[{': depth += 1
    elif ch in '}]':
        depth -= 1
        if depth == 0: end_idx = i + 1; break
print(json_str[:end_idx])
" 2>/dev/null
}
# Extract all relation names with Seq Scan or Parallel Seq Scan in the plan.
# Input: plan JSON from EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON).
# Output: comma-separated relation names, or "none".
all_seq_scans() {
	echo "$1" | plan_json | python3 -c "
import sys, json
def find_seq_scans(obj, scans):
    if isinstance(obj, dict):
        if obj.get('Node Type') in ('Seq Scan', 'Parallel Seq Scan'):
            rel = obj.get('Relation Name')
            if rel: scans.append(rel)
        for v in obj.values(): find_seq_scans(v, scans)
    elif isinstance(obj, list):
        for item in obj: find_seq_scans(item, scans)
try:
    data = json.load(sys.stdin)
    scans = []
    find_seq_scans(data, scans)
    print(','.join(sorted(set(scans))) if scans else 'none')
except Exception:
    print('parse_error')
"
}
# Check if a plan JSON contains a Seq Scan on any of the given tables.
# Returns 0 if found, 1 otherwise.
# Usage: echo <plan_json> | has_seq_scan_on <table>...
has_seq_scan_on() {
	plan_json | python3 -c "
import sys, json
def find_seq_scan_on(obj, target_tables):
    if isinstance(obj, dict):
        if obj.get('Node Type') in ('Seq Scan', 'Parallel Seq Scan'):
            rel = obj.get('Relation Name')
            if rel in target_tables:
                return True
        for v in obj.values():
            if find_seq_scan_on(v, target_tables):
                return True
    elif isinstance(obj, list):
        for item in obj:
            if find_seq_scan_on(item, target_tables):
                return True
    return False
try:
    data = json.load(sys.stdin)
    target_tables = set(sys.argv[1:])
    sys.exit(0 if find_seq_scan_on(data, target_tables) else 1)
except Exception:
    sys.exit(1)
" "$@" 2>/dev/null
}
# Print the required "Node Type"s the plan does NOT contain, space separated.
# Input: plan JSON from EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) on stdin.
# Usage: echo <plan_json> | missing_node_types "<type>|<type>..."
# The types come in one argument, separated by '|': a node type holds spaces
# ("Bitmap Index Scan"), and a word-split argument list would break it apart.
# A plan that cannot be parsed reports every required type as missing: a
# measurement that cannot be read must not pass.
missing_node_types() {
	plan_json | python3 -c "
import sys, json
def walk(obj, found):
    if isinstance(obj, dict):
        nt = obj.get('Node Type')
        if nt: found.add(nt)
        for v in obj.values(): walk(v, found)
    elif isinstance(obj, list):
        for item in obj: walk(item, found)
want = set(sys.argv[1].split('|')) if len(sys.argv) > 1 and sys.argv[1] else set()
try:
    data = json.load(sys.stdin)
    found = set()
    walk(data, found)
    print(' '.join(sorted(want - found)))
except Exception:
    print(' '.join(sorted(want)))
" "$@" 2>/dev/null
}
# Run a single query RUNS times, collect times and seq-scan info.
# Inputs: query_file, runs, budget_ms, seq_scan_tables (space-separated),
#         require_nodes (space-separated), times_file, seq_scans_file,
#         budgeted_flag, missing_nodes_file
# Outputs: writes times to times_file, seq_scans to seq_scans_file, budgeted
#          scans to budgeted_flag, missing plan node types to missing_nodes_file
measure_query() {
	query_file="$1"
	runs="$2"
	budget_ms="$3"
	seq_scan_tables="$4"
	require_nodes="$5"
	times_file="$6"
	seq_scans_file="$7"
	budgeted_flag="$8"
	missing_nodes_file="$9"
	# Clear output files
	: >"${times_file}"
	: >"${seq_scans_file}"
	: >"${budgeted_flag}"
	: >"${missing_nodes_file}"
	# Ensure plans directory exists
	mkdir -p "${WORK}/plans"
	for _ in $(seq 1 "${runs}"); do
		# Run EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
		if ! psql_stdin <<HEREDOC 2>"${WORK}/plans/explain.err" >"${WORK}/plans/explain.out"; then
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
$(cat "${query_file}");
HEREDOC
			continue
		fi
		plan_json="$(cat "${WORK}/plans/explain.out")"
		# Extract execution time from plan (float ms)
		exec_time="$(echo "${plan_json}" | grep -o '"Execution Time": [0-9.]*' | head -1 | sed 's/.*: //')"
		if [ -z "${exec_time}" ]; then
			exec_time=0
		fi
		echo "${exec_time}" >>"${times_file}"
		# Get ALL relations with Seq Scan
		all_scans="$(all_seq_scans "${plan_json}")"
		echo "${all_scans}" >>"${seq_scans_file}"
		# Check for Seq Scan on budgeted tables
		if [ -n "${seq_scan_tables}" ]; then
			# shellcheck disable=SC2086
			if echo "${plan_json}" | has_seq_scan_on ${seq_scan_tables}; then
				echo "budgeted" >>"${budgeted_flag}"
			fi
		fi
		# The plan must contain each required node type (a GIN bitmap, say)
		if [ -n "${require_nodes}" ]; then
			missing="$(echo "${plan_json}" | missing_node_types "${require_nodes}")"
			if [ -n "${missing}" ]; then
				echo "${missing}" >>"${missing_nodes_file}"
			fi
		fi
	done
}
# Determine pass/fail and print result line.
# Inputs: id, p50, p95, seq_scans_file, budget_ms, budgeted_scan_flag,
#         missing_nodes_file
# Returns: 0 for pass, 1 for fail
evaluate_query() {
	id="$1"
	p50="$2"
	p95="$3"
	seq_scans_file="$4"
	budget_ms="$5"
	budgeted_scan_flag="$6"
	missing_nodes_file="$7"
	# Aggregate all unique seq scans across runs
	all_scans="$(sort -u "${seq_scans_file}" | grep -v '^none$' | tr '\n' ',' | sed 's/,$//')"
	[ -z "${all_scans}" ] && all_scans="none"
	# Check if any run had a budgeted table seq scan (file exists and is non-empty)
	budgeted_scan="no"
	if [ -s "${budgeted_scan_flag}" ]; then
		budgeted_scan="yes"
	fi
	# The required plan node types the plan did not contain
	missing_nodes="none"
	plan_detail=""
	if [ -s "${missing_nodes_file}" ]; then
		missing_nodes="$(sort -u "${missing_nodes_file}" | tr '\n' ',' | sed 's/,$//')"
		plan_detail=" plan=missing ${missing_nodes}"
	fi
	# Self-check: p95 must not be < p50
	if awk -v p50="${p50}" -v p95="${p95}" 'BEGIN { exit (p95 < p50) ? 0 : 1 }'; then
		note "SELF-CHECK FAILED: ${id} p95=${p95} < p50=${p50}"
		return 1
	fi
	# Pass if p95 <= budget AND no budgeted seq scan AND the plan holds every
	# required node type
	if awk -v p95="${p95}" -v budget="${budget_ms}" 'BEGIN { exit (p95 <= budget) ? 0 : 1 }' && [ "${budgeted_scan}" = "no" ] && [ "${missing_nodes}" = "none" ]; then
		pass_query "${id}" "${p50}" "${p95}" "${all_scans}" "${budget_ms}" "${plan_detail}"
		return 0
	else
		fail_query "${id}" "${p50}" "${p95}" "${all_scans}" "${budget_ms}" "${plan_detail}"
		return 1
	fi
}
# Build JSON output for all queries.
# Inputs: work_dir, runs, seed_time, repo_root, image, git_sha, timestamp
write_json_output() {
	work_dir="$1"
	runs="$2"
	seed_time="$3"
	# repo_root is unused but kept for API compatibility
	_="$4"
	image="$5"
	git_sha="$6"
	timestamp="$7"
	output_json="$8"
	image_digest="$(docker image inspect "${image}" --format '{{.RepoDigests}}' 2>/dev/null | head -1 | sed 's/.*sha256:\([a-f0-9]*\).*/\1/' || echo 'unknown')"
	{
		echo '{'
		echo '  "timestamp": "'"${timestamp}"'",'
		echo '  "git_sha": "'"${git_sha}"'",'
		echo '  "image_digest": "'"${image_digest}"'",'
		echo '  "runs": '"${runs}"','
		echo '  "seed_time_sec": '"${seed_time}"','
		echo '  "queries": ['
		first=1
		for query_file in "${work_dir}/queries"/*.sql; do
			[ -f "${query_file}" ] || continue
			id="$(basename "${query_file}" .sql)"
			times_file="${work_dir}/times-${id}.txt"
			seq_scans_file="${work_dir}/seq_scans-${id}.txt"
			budgeted_scan_flag="${work_dir}/budgeted_scan-${id}.flag"
			if [ -f "${times_file}" ]; then
				# shellcheck disable=SC2046
				set -- $(percentiles "${times_file}")
				p50=$1
				p95=$2
				# Aggregate seq scans
				all_scans="$(sort -u "${seq_scans_file}" 2>/dev/null | grep -v '^none$' | tr '\n' ',' | sed 's/,$//')"
				[ -z "${all_scans}" ] && all_scans="none"
				budgeted_scan="false"
				if [ -f "${budgeted_scan_flag}" ]; then
					budgeted_scan="true"
				fi
				budget_ms="$(grep -A3 "\"${id}\"" "${FIX}/budgets.json" | grep '"p95_ms"' | sed 's/.*: *\([0-9]*\).*/\1/')"
				[ -z "${budget_ms}" ] && budget_ms=0
				pass="true"
				if awk -v p95="${p95}" -v budget="${budget_ms}" 'BEGIN { exit (p95 <= budget) ? 0 : 1 }' && [ "${budgeted_scan}" = "false" ]; then
					pass="true"
				else
					pass="false"
				fi
				[ "${first}" -eq 1 ] || echo '    ,'
				first=0
				echo '    {'
				echo '      "id": "'"${id}"'",'
				echo '      "p50_ms": '"${p50}"','
				echo '      "p95_ms": '"${p95}"','
				echo '      "seq_scans": "'"${all_scans}"'",'
				echo '      "budgeted_seq_scan": '"${budgeted_scan}"','
				echo '      "budget_ms": '"${budget_ms}"','
				echo '      "pass": '"${pass}"
				printf '    }'
			fi
		done
		echo ''
		echo '  ]'
		echo '}'
	} >"${output_json}"
}
# shellcheck disable=SC1091
. "${FIX}/self-test.sh"