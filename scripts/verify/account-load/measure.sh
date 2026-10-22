#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    measure.sh                                                                #
#                                                                              #
#    Query measurement and reporting for account-load.                         #
#                                                                              #
# **************************************************************************** #
#
# WHY: Separated to keep each file ≤300 lines.
# Handles: EXPLAIN ANALYZE runs, percentile computation, seq-scan detection,
# pass/fail determination, JSON output.
#
# Usage: sourced by account-load.sh.
# Ponytail: small, no deps beyond POSIX sh + awk + python3.
# Compute p50 and p95 using nearest-rank method on sorted numeric values.
# Input: file with one float (ms) per line from EXPLAIN JSON "Execution Time".
# Output: "p50 p95" with 2 decimal places.
# Nearest-rank: p = sorted[ceil(q/100 * n) - 1] (1-indexed).
percentiles() {
	awk '
		{ a[NR] = $1 }
		END {
			if (NR == 0) { print "0.00 0.00"; exit }
			# sort numerically
			for (i = 1; i <= NR; i++) {
				for (j = i + 1; j <= NR; j++) {
					if (a[i] > a[j]) { t = a[i]; a[i] = a[j]; a[j] = t }
				}
			}
			# nearest-rank: ceil(q/100 * n)
			p50_idx = int(0.50 * NR) + (0.50 * NR > int(0.50 * NR) ? 1 : 0)
			p95_idx = int(0.95 * NR) + (0.95 * NR > int(0.95 * NR) ? 1 : 0)
			if (p50_idx < 1) p50_idx = 1
			if (p50_idx > NR) p50_idx = NR
			if (p95_idx < 1) p95_idx = 1
			if (p95_idx > NR) p95_idx = NR
			printf "%.2f %.2f\n", a[p50_idx], a[p95_idx]
		}' "$1"
}
# Extract all relation names that have a Seq Scan or Parallel Seq Scan in the plan.
# Input: plan JSON (single line or multi-line, from EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON))
# Output: comma-separated list of relation names, or "none"
all_seq_scans() {
	# Use python for reliable JSON parsing, skipping psql header lines and pretty-print "+" suffixes
	echo "$1" | python3 -c "
import sys, json
def find_seq_scans(obj, scans):
    if isinstance(obj, dict):
        if obj.get('Node Type') in ('Seq Scan', 'Parallel Seq Scan'):
            rel = obj.get('Relation Name')
            if rel:
                scans.append(rel)
        for v in obj.values():
            find_seq_scans(v, scans)
    elif isinstance(obj, list):
        for item in obj:
            find_seq_scans(item, scans)
try:
    # Read all input, skip psql header lines and strip pretty-print '+' suffixes
    lines = sys.stdin.read().strip().split('\n')
    json_lines = [l.rstrip(' +') for l in lines if l.strip() and not l.strip().startswith('-') and 'QUERY PLAN' not in l and not all(c == '-' for c in l.strip())]
    json_str = '\n'.join(json_lines)
    # Find the matching closing bracket for the opening bracket to handle any trailing data
    depth = 0
    end_idx = 0
    for i, ch in enumerate(json_str):
        if ch == '[' or ch == '{':
            depth += 1
        elif ch == ']' or ch == '}':
            depth -= 1
            if depth == 0:
                end_idx = i + 1
                break
    json_str = json_str[:end_idx]
    data = json.loads(json_str)
    scans = []
    find_seq_scans(data, scans)
    if scans:
        print(','.join(sorted(set(scans))))
    else:
        print('none')
except Exception as e:
    print('parse_error', file=sys.stderr)
    print('parse_error')
" 2>/dev/null || echo "parse_error"
}
# Check if a plan JSON contains a Seq Scan on any of the given tables.
# Returns 0 if found, 1 otherwise.
has_seq_scan_on() {
	plan_json="$1"
	shift
	# Use python to parse JSON properly
	echo "$plan_json" | python3 -c "
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
    lines = sys.stdin.read().strip().split('\n')
    json_lines = [l.rstrip(' +') for l in lines if l.strip() and not l.strip().startswith('-') and 'QUERY PLAN' not in l and not all(c == '-' for c in l.strip())]
    json_str = '\n'.join(json_lines)
    depth = 0
    end_idx = 0
    for i, ch in enumerate(json_str):
        if ch == '[' or ch == '{':
            depth += 1
        elif ch == ']' or ch == '}':
            depth -= 1
            if depth == 0:
                end_idx = i + 1
                break
    json_str = json_str[:end_idx]
    data = json.loads(json_str)
    target_tables = set(sys.argv[1:])
    if find_seq_scan_on(data, target_tables):
        sys.exit(0)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
" "$@" 2>/dev/null
}
# Run a single query RUNS times, collect times and seq-scan info.
# Inputs: query_file, runs, budget_ms, seq_scan_tables (space-separated)
# Outputs: writes times to times_file, seq_scans to seq_scans_file, budgeted scans to budgeted_flag
measure_query() {
	query_file="$1"
	runs="$2"
	budget_ms="$3"
	seq_scan_tables="$4"
	times_file="$5"
	seq_scans_file="$6"
	budgeted_flag="$7"
	# Clear output files
	: >"${times_file}"
	: >"${seq_scans_file}"
	: >"${budgeted_flag}"
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
			if has_seq_scan_on "${plan_json}" "${seq_scan_tables}"; then
				echo "budgeted" >>"${budgeted_flag}"
			fi
		fi
	done
}
# Determine pass/fail and print result line.
# Inputs: id, p50, p95, seq_scans_file, budget_ms, budgeted_scan_flag
# Returns: 0 for pass, 1 for fail
evaluate_query() {
	id="$1"
	p50="$2"
	p95="$3"
	seq_scans_file="$4"
	budget_ms="$5"
	budgeted_scan_flag="$6"
	# Aggregate all unique seq scans across runs
	all_scans="$(sort -u "${seq_scans_file}" | grep -v '^none$' | tr '\n' ',' | sed 's/,$//')"
	[ -z "${all_scans}" ] && all_scans="none"
	# Check if any run had a budgeted table seq scan (file exists and is non-empty)
	budgeted_scan="no"
	if [ -s "${budgeted_scan_flag}" ]; then
		budgeted_scan="yes"
	fi
	# Self-check: p95 must not be < p50
	if awk -v p50="${p50}" -v p95="${p95}" 'BEGIN { exit (p95 < p50) ? 0 : 1 }'; then
		note "SELF-CHECK FAILED: ${id} p95=${p95} < p50=${p50}"
		return 1
	fi
	# Pass if p95 <= budget AND no budgeted seq scan
	if awk -v p95="${p95}" -v budget="${budget_ms}" 'BEGIN { exit (p95 <= budget) ? 0 : 1 }' && [ "${budgeted_scan}" = "no" ]; then
		pass_query "${id}" "${p50}" "${p95}" "${all_scans}" "${budget_ms}"
		return 0
	else
		fail_query "${id}" "${p50}" "${p95}" "${all_scans}" "${budget_ms}"
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