# shellcheck shell=sh
# Sourced by scripts/verify/discussions.sh: d3 accept/reject, d4 refusals, d5 supersede/rebase.
# shellcheck disable=SC2154

P1="33333333-0000-4000-8000-000000000001"
P2="33333333-0000-4000-8000-000000000002"
P3="33333333-0000-4000-8000-000000000003"
S_TOP="55555555-0000-4000-8000-000000000001"
S_NESTED="55555555-0000-4000-8000-000000000002"
S_CELL="55555555-0000-4000-8000-000000000003"
S_REJECT="55555555-0000-4000-8000-000000000004"

# d3 — accept splices the block wherever it sits; reject only records the verdict.
check_accept_reject() {
	seed_page "${P1}" '[{"id":"t1","type":"paragraph","content":"a 😀 quick fox"},
	  {"id":"tg","type":"toggle","content":"head","children":[{"id":"n1","type":"paragraph","content":"nested old text"}]},
	  {"id":"lay","type":"layout","layoutCells":[{"blocks":[]},{"blocks":[{"id":"cell","type":"heading_2","content":"cell title"}]}]},
	  {"id":"code1","type":"code","content":"let x"}]'
	suggest "${S_TOP}" "${P1}" t1 4 9 quick 'a 😀 ' ' fox' slow
	suggest "${S_NESTED}" "${P1}" n1 7 10 old 'nested ' ' text' new
	suggest "${S_CELL}" "${P1}" cell 5 10 title 'cell ' '' name
	ok=0
	v0="$(version_of "${P1}")"
	out="$(decide "${S_TOP}" accepted)" || return 1
	check d3 "accept answers ok" true "$(printf '%s' "${out}" | jq -r .ok)" || ok=1
	check d3 "the astral block is spliced in code points" "a 😀 slow fox" "$(block_text "${P1}" t1)" || ok=1
	check d3 "the version moves by one" "$((v0 + 1))" "$(version_of "${P1}")" || ok=1
	check d3 "the answer carries the version" "$((v0 + 1))" "$(printf '%s' "${out}" | jq -r .version)" || ok=1
	check d3 "the answer carries the full content" 4 "$(printf '%s' "${out}" | jq '.content | length')" || ok=1
	decide "${S_NESTED}" accepted >/dev/null || return 1
	check d3 "a child block is spliced" "nested new text" "$(block_text "${P1}" n1)" || ok=1
	decide "${S_CELL}" accepted >/dev/null || return 1
	check d3 "a layout-cell block is spliced" "cell name" "$(block_text "${P1}" cell)" || ok=1
	check d3 "the decider and time are recorded" "accepted ${U1} true" \
		"$(q "SELECT status || ' ' || decided_by || ' ' || (decided_at IS NOT NULL) FROM public.osionos_page_comments WHERE id = '${S_TOP}'")" || ok=1

	suggest "${S_REJECT}" "${P1}" t1 9 12 fox 'a 😀 slow ' '' cat
	v1="$(version_of "${P1}")"
	before="$(q "SELECT md5(content::text) FROM public.osionos_pages WHERE id = '${P1}'")"
	out="$(decide "${S_REJECT}" rejected)" || return 1
	check d3 "reject answers rejected" "true rejected" "$(printf '%s' "${out}" | jq -r '"\(.ok) \(.status)"')" || ok=1
	check d3 "reject leaves the content alone" "${before}" "$(q "SELECT md5(content::text) FROM public.osionos_pages WHERE id = '${P1}'")" || ok=1
	check d3 "reject leaves the version alone" "${v1}" "$(version_of "${P1}")" || ok=1
	return "${ok}"
}

# expect_refusal <label> <reason> <decide args...> — the answer's reason, and no write.
expect_refusal() {
	label="$1"
	reason="$2"
	shift 2
	page_before="$(q "SELECT md5(string_agg(id::text || version::text || content::text, ',' ORDER BY id)) FROM public.osionos_pages")"
	rows_before="$(q "SELECT md5(string_agg(id || status || coalesce(anchor::text, ''), ',' ORDER BY id)) FROM public.osionos_page_comments")"
	out="$(decide "$@")" || { printf '  FAIL d4 %s: the decide raised\n' "${label}"; return 1; }
	check d4 "${label}" "false ${reason}" "$(printf '%s' "${out}" | jq -r '"\(.ok) \(.reason)"')" || return 1
	check d4 "${label} writes no page" "${page_before}" \
		"$(q "SELECT md5(string_agg(id::text || version::text || content::text, ',' ORDER BY id)) FROM public.osionos_pages")" || return 1
	check d4 "${label} writes no comment" "${rows_before}" \
		"$(q "SELECT md5(string_agg(id || status || coalesce(anchor::text, ''), ',' ORDER BY id)) FROM public.osionos_page_comments")"
}

# d4 — every refusal answers its reason and changes nothing.
check_refusals() {
	seed_page "${P2}" '[{"id":"r1","type":"paragraph","content":"refuse this text"},
	  {"id":"rc","type":"code","content":"refuse code"}]'
	s_changed="55555555-0000-4000-8000-000000000011"
	s_code="55555555-0000-4000-8000-000000000012"
	s_ghost="55555555-0000-4000-8000-000000000013"
	s_edited="55555555-0000-4000-8000-000000000014"
	s_arch="55555555-0000-4000-8000-000000000015"
	suggest "${s_changed}" "${P2}" r1 7 11 this 'refuse ' ' text' that
	suggest "${s_code}" "${P2}" rc 7 11 code 'refuse ' '' x
	suggest "${s_ghost}" "${P2}" gone 0 3 abc '' '' x
	suggest "${s_edited}" "${P2}" r1 0 3 zzz '' '' x
	ok=0
	expect_refusal "a missing id" missing "66666666-0000-4000-8000-000000000000" accepted || ok=1
	expect_refusal "a decided suggestion" decided "${S_TOP}" accepted || ok=1
	expect_refusal "a stale stamp" changed "${s_changed}" accepted "2000-01-01T00:00:00Z" || ok=1
	expect_refusal "a code block" unsupported "${s_code}" accepted || ok=1
	expect_refusal "a deleted block" stale "${s_ghost}" accepted || ok=1
	expect_refusal "an edited quote" stale "${s_edited}" accepted || ok=1
	seed_page "33333333-0000-4000-8000-000000000012" '[{"id":"a1","type":"paragraph","content":"archived text"}]'
	suggest "${s_arch}" "33333333-0000-4000-8000-000000000012" a1 0 8 archived '' ' text' x
	q "UPDATE public.osionos_pages SET archived_at = now() WHERE id = '33333333-0000-4000-8000-000000000012'" >/dev/null
	expect_refusal "an archived page" archived "${s_arch}" accepted || ok=1
	check d4 "an unknown verdict" 22023 "$(sqlstate_of "SELECT public.osionos_decide_suggestion('${s_changed}', '${U1}', 'maybe')")" || ok=1
	check d4 "no decider" 22023 "$(sqlstate_of "SELECT public.osionos_decide_suggestion('${s_changed}', NULL, 'accepted')")" || ok=1
	return "${ok}"
}

anchor_of() { q "SELECT anchor::text FROM public.osionos_page_comments WHERE id = '$1'" | jq -cS .; }

# The quote an anchor names reads at its offsets in the block.
reads_at_offsets() {
	q "SELECT substr(p.content #>> (public.osionos_block_path(p.content, '$3') || ARRAY['content']),
	              (c.anchor ->> 'start')::int + 1, (c.anchor ->> 'end')::int - (c.anchor ->> 'start')::int)
	          = c.anchor ->> 'quote'
	     FROM public.osionos_pages p, public.osionos_page_comments c
	    WHERE p.id = '$2' AND c.id = '$1'"
}

# d5 — accepting one suggestion supersedes the ones it overlaps and moves the rest.
check_supersede_rebase() {
	seed_page "${P3}" '[{"id":"b1","type":"paragraph","content":"one two three four"}]'
	a="55555555-0000-4000-8000-000000000021"
	b="55555555-0000-4000-8000-000000000022"
	c="55555555-0000-4000-8000-000000000023"
	d="55555555-0000-4000-8000-000000000024"
	suggest "${a}" "${P3}" b1 4 7 two 'one ' ' three four' 2
	suggest "${b}" "${P3}" b1 4 13 'two three' 'one ' ' four' 'II III'
	suggest "${c}" "${P3}" b1 14 18 four 'one two three ' '' 4
	suggest "${d}" "${P3}" b1 0 3 one '' ' two three four' 1
	ok=0
	out="$(decide "${a}" accepted)" || return 1
	check d5 "the overlapping one is superseded" "[\"${b}\"]" "$(printf '%s' "${out}" | jq -c .supersededIds)" || ok=1
	check d5 "the others are rebased" "[\"${c}\",\"${d}\"]" "$(printf '%s' "${out}" | jq -c '.rebasedIds | sort')" || ok=1
	check d5 "superseded records the decider" "superseded ${U1}" "$(q "SELECT status || ' ' || decided_by FROM public.osionos_page_comments WHERE id = '${b}'")" || ok=1
	check d5 "a later one shifts by the length change" '{"end":16,"prefix":"one 2 three ","quote":"four","start":12,"suffix":""}' "$(anchor_of "${c}")" || ok=1
	check d5 "an earlier one keeps its offsets, with fresh context" '{"end":3,"prefix":"","quote":"one","start":0,"suffix":" 2 three four"}' "$(anchor_of "${d}")" || ok=1
	check d5 "the rebased quote reads at its offsets" t "$(reads_at_offsets "${c}" "${P3}" b1)" || ok=1
	decide "${c}" accepted >/dev/null || return 1
	decide "${d}" accepted >/dev/null || return 1
	check d5 "the rebased ones still apply" "1 2 three 4" "$(block_text "${P3}" b1)" || ok=1
	return "${ok}"
}
