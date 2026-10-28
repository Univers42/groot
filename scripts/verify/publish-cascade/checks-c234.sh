# shellcheck shell=sh

# publish-cascade/checks-c234.sh — c2 owner change, c3 workspace change,
# c4 the members row: each removes the owner's snapshot with the hold.
#
# Sourced by scripts/verify/publish-cascade.sh, which calls these checks: the
# linter reads one file at a time and calls them unreachable.
# shellcheck disable=SC2317,SC2329

check_c2() {
	# The ownership transfer (or the erasure's transfer of a shared page to the
	# workspace's new owner): one UPDATE on osionos_pages and the snapshot is gone,
	# whatever DELETE grants the caller holds (the function is SECURITY DEFINER;
	# c8 pins that nobody else may call it directly).
	q "UPDATE public.osionos_pages SET owner_id = '${B}' WHERE id = '${PA3}'" >/dev/null
	n="$(pub_row "${PA3}")"
	if [ "${n}" = "0" ]; then
		printf 'PASS c2 owner-change   the page is owned by B and its snapshot is gone\n'
	else
		printf 'FAIL c2 owner-change   %s snapshot row(s) survived the owner change\n' "${n}"
		return 1
	fi
}

check_c3() {
	# The workspace move: the owner may hold no members row in the destination.
	expect_v_in="$(pub_row "${PBV}")"
	q "UPDATE public.osionos_pages SET workspace_id = '${V}' WHERE id = '${PA4}'" >/dev/null
	n="$(pub_row "${PA4}")"
	if [ "${n}" = "0" ]; then
		printf 'PASS c3 workspace-move the page moved to V and its snapshot is gone\n'
	else
		printf 'FAIL c3 workspace-move %s snapshot row(s) survived the workspace change\n' "${n}"
		return 1
	fi
	if [ "${expect_v_in}" = "1" ]; then
		printf 'PASS c3 move-scope     only the MOVED page was touched (%s untouched)\n' "${PBV}"
	else
		printf 'FAIL c3 move-scope     the workspace change removed %s published row(s) of %s\n' "${expect_v_in}" "${PBV}"
		return 1
	fi
}

check_c4() {
	# Baseline: PA2 still published (c1 proved the saves keep it), PC9 is B's
	# page in W, PBW is B's page in W, PBV is A's page in V.
	rows0="$(pub_row "${PA2}")"
	if [ "${rows0}" != "1" ]; then
		printf 'FAIL c4 baseline       %s published row(s) for %s (expected 1)\n' "${rows0}" "${PA2}"
		return 1
	fi

	# A role change is not a loss of the hold (a demotion to viewer still holds).
	q "UPDATE public.osionos_workspace_members SET role = 'viewer' WHERE workspace_id = '${W}' AND user_id = '${A}'" >/dev/null
	n="$(pub_row "${PA2}")"
	if [ "${n}" = "1" ]; then
		printf 'PASS c4 role-change    editor -> viewer removed nothing\n'
	else
		printf 'FAIL c4 role-change    editor -> viewer removed the snapshot (%s rows)\n' "${n}"
		return 1
	fi

	# The delete: A stops holding W; ONLY A's published pages in W go.
	expect_b_w="$(pub_row "${PBW}")"
	expect_b_c9="$(pub_row "${PC9}")"
	expect_a_v="$(pub_row "${PBV}")"
	q "DELETE FROM public.osionos_workspace_members WHERE workspace_id = '${W}' AND user_id = '${A}'" >/dev/null
	n="$(pub_row "${PA2}")"
	if [ "${n}" = "0" ]; then
		printf 'PASS c4 members-delete the owner loses W and the snapshot is gone\n'
	else
		printf 'FAIL c4 members-delete %s snapshot row(s) survived the removal from the workspace\n' "${n}"
		return 1
	fi
	if [ "${expect_a_v}" = "1" ] && [ "$(pub_row "${PBV}")" = "1" ]; then
		printf 'PASS c4 other-workspace the same owner page in V is untouched\n'
	else
		printf 'FAIL c4 other-workspace %s -> %s: the removal reached beyond W\n' "${expect_a_v}" "$(pub_row "${PBV}")"
		return 1
	fi
	if [ "${expect_b_w}" = "1" ] && [ "$(pub_row "${PBW}")" = "1" ]; then
		printf 'PASS c4 other-member   an other member page in W is untouched\n'
	else
		printf 'FAIL c4 other-member   %s -> %s: the removal over-reached into another member\n' "${expect_b_w}" "$(pub_row "${PBW}")"
		return 1
	fi
	if [ "${expect_b_c9}" = "1" ] && [ "$(pub_row "${PC9}")" = "1" ]; then
		printf 'PASS c4 file-page      the reserved c9 page (owner B) is untouched\n'
	else
		printf 'FAIL c4 file-page      %s -> %s: the removal over-reached\n' "${expect_b_c9}" "$(pub_row "${PC9}")"
		return 1
	fi
	return 0
}
