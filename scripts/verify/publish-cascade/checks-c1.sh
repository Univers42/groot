# shellcheck shell=sh

# publish-cascade/checks-c1.sh — c1: archiving a published page removes its
# snapshot; a content, title or icon update of another published page leaves
# the row and its published_at alone (the WHEN clause, not the hot saves).
#
# Sourced by scripts/verify/publish-cascade.sh, which calls this check: the
# linter reads one file at a time and calls it unreachable.
# shellcheck disable=SC2317,SC2329

# expect_gone <label> <page_id> — the page's published row must be absent.
expect_gone() {
	n="$(pub_row "$2")"
	if [ "${n}" = "0" ]; then
		printf 'PASS c1 %s   the snapshot row is gone (%s)\n' "$1" "$2"
	else
		printf 'FAIL c1 %s   %s published row(s) remain for %s\n' "$1" "${n}" "$2"
		return 1
	fi
}

check_c1() {
	# The negative half first: three saves of a still-published page must not
	# remove the row, and must not touch published_at either.
	before="$(published_at "${PA2}")"
	q "UPDATE public.osionos_pages SET content = '[{\"id\":\"c1\",\"type\":\"text\",\"content\":\"x\"}]'::jsonb WHERE id = '${PA2}'" >/dev/null
	n="$(pub_row "${PA2}")"
	if [ "${n}" = "1" ]; then
		printf 'PASS c1 content-save   a content update of a published page left the snapshot\n'
	else
		printf 'FAIL c1 content-save   a content update removed the snapshot (%s rows) — the trigger fires on saves\n' "${n}"
		return 1
	fi
	q "UPDATE public.osionos_pages SET title = 'update-me-renamed' WHERE id = '${PA2}'" >/dev/null
	n="$(pub_row "${PA2}")"
	if [ "${n}" = "1" ]; then
		printf 'PASS c1 title-save     a title update of a published page left the snapshot\n'
	else
		printf 'FAIL c1 title-save     a title update removed the snapshot (%s rows)\n' "${n}"
		return 1
	fi
	q "UPDATE public.osionos_pages SET icon = 'moon' WHERE id = '${PA2}'" >/dev/null
	n="$(pub_row "${PA2}")"
	after="$(published_at "${PA2}")"
	if [ "${n}" = "1" ]; then
		printf 'PASS c1 icon-save      an icon update of a published page left the snapshot\n'
	else
		printf 'FAIL c1 icon-save      an icon update removed the snapshot (%s rows)\n' "${n}"
		return 1
	fi
	if [ "${before}" != "-" ] && [ "${before}" = "${after}" ]; then
		printf 'PASS c1 published-at   the published_at stayed %s through the three saves\n' "${before}"
	else
		printf 'FAIL c1 published-at   published_at moved or was nicked (%s -> %s)\n' "${before}" "${after}"
		return 1
	fi

	# The positive half: the archive ends the hold.
	q "UPDATE public.osionos_pages SET archived_at = now() WHERE id = '${PA1}'" >/dev/null
	expect_gone archive "${PA1}"
}
