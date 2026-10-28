# shellcheck shell=sh

# publish-cascade/checks-c56.sh — c5 the workspace delete (the table's own ON
# DELETE CASCADE, pinned) and c6 the account erasure.
#
# Sourced by scripts/verify/publish-cascade.sh, which calls these checks: the
# linter reads one file at a time and calls them unreachable.
# shellcheck disable=SC2317,SC2329

check_c5() {
	expect_a="$(pub_row "${PMD1}")"
	expect_b="$(pub_row "${PMD2}")"
	# PKMD pins the CASCADE: its owner K holds no members row in MD, so no
	# members trigger can remove it — only osionos_published_pages' own
	# osionos_pages ON DELETE CASCADE can.
	expect_cascade="$(pub_row "${PKMD}")"
	q "DELETE FROM public.osionos_workspaces WHERE id = '${MD}'" >/dev/null
	if [ "${expect_a}" = "1" ] && [ "$(pub_row "${PMD1}")" = "0" ]; then
		printf 'PASS c5 page-a         the owner A page went with the workspace\n'
	else
		printf 'FAIL c5 page-a         %s -> %s\n' "${expect_a}" "$(pub_row "${PMD1}")"
		return 1
	fi
	if [ "${expect_b}" = "1" ] && [ "$(pub_row "${PMD2}")" = "0" ]; then
		printf 'PASS c5 page-b         the owner B page went with the workspace\n'
	else
		printf 'FAIL c5 page-b         %s -> %s\n' "${expect_b}" "$(pub_row "${PMD2}")"
		return 1
	fi
	if [ "${expect_cascade}" = "1" ] && [ "$(pub_row "${PKMD}")" = "0" ]; then
		printf 'PASS c5 cascade        the members row (its owner holds nothing in MD) died with the pages cascade\n'
	else
		printf 'FAIL c5 cascade        %s -> %s\n' "${expect_cascade}" "$(pub_row "${PKMD}")"
		return 1
	fi
}

check_c6() {
	# The erasure stage in the runner's ORDER (ORDERED_LAST tail): foundation
	# (the account role + osionos_account_uid), account-profiles (the deletion
	# requests table the erase locks), then the erasure itself. The service-role
	# sweep already ran in the fixture; the runner puts it AFTER the erasure, so
	# a failure here that reaches the requests table is a FAIL with the psql
	# error — never a silent skip.
	apply "${MODELS}/osionos-account-foundation-migration.sql" || return 1
	apply "${MODELS}/osionos-account-profiles-migration.sql" || return 1
	apply "${MODELS}/osionos-account-erasure-migration.sql" || return 1

	q "INSERT INTO auth.users (id, email) VALUES ('${E}', 'erase-verify@example.invalid'), ('${K}', 'keeper-verify@example.invalid');" >/dev/null
	q "INSERT INTO public.osionos_account_deletion_requests (user_id, requested_at, scheduled_for)
	   VALUES ('${E}', now() - interval '16 days', now() - interval '1 hour');" >/dev/null

	err="${WORK}/erase.err"
	if ! out="$(printf '%s\n' "SELECT public.osionos_account_erase('${E}');" |
		docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt 2>"${err}")"; then
		printf '[c6] psql rejected the erase call:\n' >&2
		sed 's/^/  | /' "${err}" >&2
		return 1
	fi
	disp="$(printf '%s' "${out}" | grep -o '"dispositions":[^}]*' || true)"
	note "erase summary: ${disp:-no output}"

	# PEV1 is private: the erase deletes the page, and its snapshot goes with
	# it (the pages cascade). PEV2 is shared: the erase TRANSFERS the page to
	# the promoted owner K, and the unhold trigger removes the snapshot (the
	# data map's own delete of osionos_published_pages.owner_id covers any
	# remaining row). PKW is keeper's own page: it must survive.
	out1="$(pub_row "${PEV1}")"
	out2="$(pub_row "${PEV2}")"
	outk="$(pub_row "${PKW}")"
	if [ "${out1}" = "0" ]; then
		printf 'PASS c6 private-page   the deleted private page took its snapshot with it\n'
	else
		printf 'FAIL c6 private-page   %s snapshot row(s) remained for the erased owner private page\n' "${out1}"
		return 1
	fi
	if [ "${out2}" = "0" ]; then
		printf 'PASS c6 shared-page    the transferred shared page lost its snapshot\n'
	else
		printf 'FAIL c6 shared-page    %s snapshot row(s) remained for the erased owner shared page\n' "${out2}"
		return 1
	fi
	if [ "${outk}" = "1" ]; then
		printf 'PASS c6 keeper-page    the keeper page survived the erase (no over-reach)\n'
	else
		printf 'FAIL c6 keeper-page    %s snapshot row(s) for the keeper page (expected 1)\n' "${outk}"
		return 1
	fi
	return 0
}
