# shellcheck shell=sh
# Sourced by scripts/verify/discussions.sh: d1 (the anchor fixture) and d2 (the CHECKs).
# shellcheck disable=SC2154

P0="33333333-0000-4000-8000-000000000000"

# d1 — every reanchor and rebase case of the fixture suggestionAnchor.ts is
# tested against, answered by the SQL. Zero cases is a FAIL, not a vacuous pass.
check_fixture() {
	fixture="$(cat "${ANCHOR_FIXTURE}")"
	sql="SELECT count(*)::text FROM jsonb_array_elements(:'fx'::jsonb -> 'reanchor')
	     UNION ALL SELECT count(*)::text FROM jsonb_array_elements(:'fx'::jsonb -> 'rebase')
	     UNION ALL SELECT coalesce(string_agg(i ->> 'name', ' | '), '')
	       FROM jsonb_array_elements(:'fx'::jsonb -> 'reanchor') i
	      WHERE public.osionos_suggestion_reanchor(i ->> 'source', i -> 'anchor')
	            IS DISTINCT FROM nullif(i -> 'expected', 'null'::jsonb)
	     UNION ALL SELECT coalesce(string_agg(i ->> 'name', ' | '), '')
	       FROM jsonb_array_elements(:'fx'::jsonb -> 'rebase') i
	      WHERE public.osionos_suggestion_apply(i ->> 'source', i -> 'accepted') <> i ->> 'nextSource'
	         OR public.osionos_suggestion_rebase(i -> 'other', i -> 'accepted', i ->> 'nextSource')
	            IS DISTINCT FROM nullif(i -> 'expected', 'null'::jsonb);"
	out="$(printf '%s\n' "${sql}" | psql_q -v fx="${fixture}")" || return 1
	reanchors="$(printf '%s\n' "${out}" | sed -n 1p)"
	rebases="$(printf '%s\n' "${out}" | sed -n 2p)"
	bad_reanchor="$(printf '%s\n' "${out}" | sed -n 3p)"
	bad_rebase="$(printf '%s\n' "${out}" | sed -n 4p)"
	ok=0
	if [ "${reanchors}" -eq 0 ] || [ "${rebases}" -eq 0 ]; then
		printf '  FAIL d1 the fixture has no cases\n'
		ok=1
	fi
	check d1 "${reanchors} reanchor cases agree" "" "${bad_reanchor}" || ok=1
	check d1 "${rebases} rebase cases agree" "" "${bad_rebase}" || ok=1
	return "${ok}"
}

# A suggestion insert on P0's block b0 with the given anchor and insert JSON.
suggestion_sql() {
	printf "INSERT INTO public.osionos_page_comments (page_id, block_id, author_id, content, kind, anchor, suggestion)
	        VALUES ('%s', 'b0', '%s', '', 'suggestion', '%s'::jsonb, '%s'::jsonb)" "${P0}" "${U2}" "$1" "$2"
}

# d2 — a malformed row is refused by a CHECK (23514), never by a cast error (22P02).
check_constraints() {
	seed_page "${P0}" '[{"id":"b0","type":"paragraph","content":"hello world"}]'
	good='{"start":0,"end":5,"quote":"hello","prefix":"","suffix":" world"}'
	ins='{"insert":"hi"}'
	root="44444444-0000-4000-8000-000000000001"
	reply="44444444-0000-4000-8000-000000000002"
	q "INSERT INTO public.osionos_page_comments (id, page_id, block_id, author_id, content)
	   VALUES ('${root}', '${P0}', 'b0', '${U2}', 'root');
	   INSERT INTO public.osionos_page_comments (id, page_id, author_id, content, parent_id)
	   VALUES ('${reply}', '${P0}', '${U3}', 'reply', '${root}');" >/dev/null || return 1
	long="$(printf '%08000d' 0)x"
	ok=0
	check d2 "a well-formed suggestion" OK "$(sqlstate_of "$(suggestion_sql "${good}" "${ins}")")" || ok=1
	check d2 "an unknown kind" 23514 "$(sqlstate_of "INSERT INTO public.osionos_page_comments (page_id, author_id, content, kind) VALUES ('${P0}', '${U2}', 'x', 'poll')")" || ok=1
	check d2 "a suggestion without an anchor" 23514 "$(sqlstate_of "INSERT INTO public.osionos_page_comments (page_id, block_id, author_id, content, kind, suggestion) VALUES ('${P0}', 'b0', '${U2}', '', 'suggestion', '${ins}')")" || ok=1
	check d2 "a quote that does not span end - start" 23514 "$(sqlstate_of "$(suggestion_sql '{"start":0,"end":4,"quote":"hello","prefix":"","suffix":""}' "${ins}")")" || ok=1
	check d2 "a string start (no cast error)" 23514 "$(sqlstate_of "$(suggestion_sql '{"start":"x","end":5,"quote":"hello"}' "${ins}")")" || ok=1
	check d2 "a fractional start" 23514 "$(sqlstate_of "$(suggestion_sql '{"start":0.5,"end":5.5,"quote":"hello"}' "${ins}")")" || ok=1
	check d2 "a negative start" 23514 "$(sqlstate_of "$(suggestion_sql '{"start":-1,"end":4,"quote":"hello"}' "${ins}")")" || ok=1
	check d2 "a 17-code-point prefix" 23514 "$(sqlstate_of "$(suggestion_sql '{"start":17,"end":22,"quote":"hello","prefix":"12345678901234567"}' "${ins}")")" || ok=1
	check d2 "an anchor that is an array" 23514 "$(sqlstate_of "$(suggestion_sql '[1,2]' "${ins}")")" || ok=1
	check d2 "an insert that is a number" 23514 "$(sqlstate_of "$(suggestion_sql "${good}" '{"insert":5}')")" || ok=1
	check d2 "an insert over 8000 bytes" 23514 "$(sqlstate_of "$(suggestion_sql "${good}" "{\"insert\":\"${long}\"}")")" || ok=1
	check d2 "a verdict without a decider" 23514 "$(sqlstate_of "INSERT INTO public.osionos_page_comments (page_id, block_id, author_id, content, kind, anchor, suggestion, status) VALUES ('${P0}', 'b0', '${U2}', '', 'suggestion', '${good}', '${ins}', 'accepted')")" || ok=1
	check d2 "a suggestion as a reply" 23514 "$(sqlstate_of "INSERT INTO public.osionos_page_comments (page_id, block_id, author_id, content, kind, anchor, suggestion, parent_id) VALUES ('${P0}', 'b0', '${U2}', '', 'suggestion', '${good}', '${ins}', '${root}')")" || ok=1
	check d2 "a reply to a reply" 23514 "$(sqlstate_of "INSERT INTO public.osionos_page_comments (page_id, author_id, content, parent_id) VALUES ('${P0}', '${U2}', 'x', '${reply}')")" || ok=1
	seed_page "33333333-0000-4000-8000-0000000000ff" '[]'
	check d2 "a reply on another page" 23514 "$(sqlstate_of "INSERT INTO public.osionos_page_comments (page_id, author_id, content, parent_id) VALUES ('33333333-0000-4000-8000-0000000000ff', '${U2}', 'x', '${root}')")" || ok=1
	check d2 "an empty reaction" 23514 "$(sqlstate_of "INSERT INTO public.osionos_page_comment_reactions (comment_id, user_id, emoji) VALUES ('${root}', '${U2}', '')")" || ok=1
	check d2 "a reaction" OK "$(sqlstate_of "INSERT INTO public.osionos_page_comment_reactions (comment_id, user_id, emoji) VALUES ('${root}', '${U2}', '👍')")" || ok=1
	return "${ok}"
}
