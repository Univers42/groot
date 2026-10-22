#!/bin/sh
# **************************************************************************** #
# self-test.sh — Self-test for has_seq_scan_on breach detection
# WHY: Extracted from measure.sh to keep each file ≤300 lines.
# Runs a canned EXPLAIN JSON through has_seq_scan_on and asserts it detects
# Seq Scans on budgeted tables. Exits 1 on failure.
# **************************************************************************** #
# Usage: sourced by measure.sh; provides self_test_has_seq_scan_on()
self_test_has_seq_scan_on() {
	# Canned EXPLAIN JSON simulating a query on a view that does Seq Scan on base tables
	canned_json='[
  {
    "Plan": {
      "Node Type": "Hash Join",
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Relation Name": "user_profiles",
          "Alias": "up"
        },
        {
          "Node Type": "Seq Scan",
          "Relation Name": "osionos_bridge_identities",
          "Alias": "bi"
        },
        {
          "Node Type": "Seq Scan",
          "Relation Name": "users",
          "Alias": "u"
        }
      ]
    }
  }
]'
	# Test 1: has_seq_scan_on should find user_profiles
	if ! echo "$canned_json" | plan_scan seqon user_profiles 2>/dev/null; then
		note "SELF-TEST FAILED: plan_scan seqon missed user_profiles in canned JSON"
		return 1
	fi
	# Test 2: has_seq_scan_on should find osionos_bridge_identities
	if ! echo "$canned_json" | plan_scan seqon osionos_bridge_identities 2>/dev/null; then
		note "SELF-TEST FAILED: plan_scan seqon missed osionos_bridge_identities in canned JSON"
		return 1
	fi
	# Test 3: has_seq_scan_on should find users
	if ! echo "$canned_json" | plan_scan seqon users 2>/dev/null; then
		note "SELF-TEST FAILED: plan_scan seqon missed users in canned JSON"
		return 1
	fi
	# Test 4: has_seq_scan_on should NOT find a non-existent table
	if echo "$canned_json" | plan_scan seqon nonexistent_table 2>/dev/null; then
		note "SELF-TEST FAILED: plan_scan seqon false positive on nonexistent_table"
		return 1
	fi
	note "Self-test passed: has_seq_scan_on correctly detects Seq Scan on budgeted tables"
	return 0
}
# Self-test for missing_node_types: the plan must hold a node of each
# required "Node Type", and a plan without one has to be reported.
self_test_missing_node_types() {
	canned_json='[
  {
    "Plan": {
      "Node Type": "Bitmap Heap Scan",
      "Plans": [
        {
          "Node Type": "BitmapOr",
          "Plans": [
            {
              "Node Type": "Bitmap Index Scan",
              "Index Name": "osionos_profiles_display_name_trgm_idx"
            }
          ]
        }
      ]
    }
  }
]'
	# Test 1: the node type that is there is not reported missing
	missing="$(echo "$canned_json" | plan_scan nodes "Bitmap Index Scan")"
	if [ -n "$missing" ]; then
		note "SELF-TEST FAILED: plan_scan nodes reported '${missing}' missing in a plan that has it"
		return 1
	fi
	# Test 2: the node type that is not there is reported
	missing="$(echo "$canned_json" | plan_scan nodes "Bitmap Index Scan|Index Only Scan")"
	if [ "$missing" != "Index Only Scan" ]; then
		note "SELF-TEST FAILED: plan_scan nodes reported '${missing}' instead of 'Index Only Scan'"
		return 1
	fi
	# Test 3: a plan that cannot be parsed fails closed — every type missing
	missing="$(echo 'not a plan' | plan_scan nodes "Bitmap Index Scan")"
	if [ "$missing" != "Bitmap Index Scan" ]; then
		note "SELF-TEST FAILED: plan_scan nodes did not fail closed on an unreadable plan"
		return 1
	fi
	note "Self-test passed: missing_node_types reports the plan node types a query must have"
	return 0
}
# Self-test for the failed-run path: a query that errors must come back
# FAILED, not PASSED on an empty measurement (percentiles() prints 0.00 for
# an empty file, and 0.00 passes every budget).
# The query runs against the throwaway database the harness has already
# brought up.
self_test_error_query_fails() {
	work="$(mktemp -d "${TMPDIR:-/tmp}/acct-load-selftest.XXXXXX")"
	bad_query="${work}/bad.sql"
	printf 'SELECT nosuchcolumn FROM public.osionos_profiles;\n' >"${bad_query}"
	measure_query "${bad_query}" 1 150 "" "" \
		"${work}/times.txt" "${work}/scans.txt" "${work}/flag.txt" \
		"${work}/missing.txt" "${work}/errors.txt"
	# The verdict: a query with no measurement has a failure detail
	detail="$(query_error_detail "${work}/times.txt" "${work}/errors.txt")"
	if [ -z "${detail}" ]; then
		note "SELF-TEST FAILED: a query that errors came back with no failure detail"
		rm -rf "${work}"
		return 1
	fi
	# The error is on the FAIL line, and it is the first line of it
	case "${detail}" in
		*"ERROR:"*) ;;
		*)
			note "SELF-TEST FAILED: the failure detail carries no ERROR line: ${detail}"
			rm -rf "${work}"
			return 1
			;;
	esac
	rm -rf "${work}"
	note "Self-test passed: a query that errors comes back failed"
	return 0
}