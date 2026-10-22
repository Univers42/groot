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
	if ! echo "$canned_json" | has_seq_scan_on user_profiles 2>/dev/null; then
		note "SELF-TEST FAILED: has_seq_scan_on missed user_profiles in canned JSON"
		return 1
	fi
	# Test 2: has_seq_scan_on should find osionos_bridge_identities
	if ! echo "$canned_json" | has_seq_scan_on osionos_bridge_identities 2>/dev/null; then
		note "SELF-TEST FAILED: has_seq_scan_on missed osionos_bridge_identities in canned JSON"
		return 1
	fi
	# Test 3: has_seq_scan_on should find users
	if ! echo "$canned_json" | has_seq_scan_on users 2>/dev/null; then
		note "SELF-TEST FAILED: has_seq_scan_on missed users in canned JSON"
		return 1
	fi
	# Test 4: has_seq_scan_on should NOT find a non-existent table
	if echo "$canned_json" | has_seq_scan_on nonexistent_table 2>/dev/null; then
		note "SELF-TEST FAILED: has_seq_scan_on false positive on nonexistent_table"
		return 1
	fi
	note "Self-test passed: has_seq_scan_on correctly detects Seq Scan on budgeted tables"
	return 0
}