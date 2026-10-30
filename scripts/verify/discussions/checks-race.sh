# shellcheck shell=sh
# Sourced by scripts/verify/discussions.sh: d6 a killed decide, d7 an edit racing
# an accept, d8 50 concurrent accepts and the writes a held decide must not block.
# Caveat: "concurrent" is enforced, not hoped for: every racer is held behind one
# page lock and the check waits until the server reports them all waiting.
# shellcheck disable=SC2154

P4="33333333-0000-4000-8000-000000000004"
P5="33333333-0000-4000-8000-000000000005"
P6="33333333-0000-4000-8000-000000000006"

# bg_sql <app-name> <sql> <file-stem> — a session in the background, named so it can be found.
bg_sql() {
	printf '%s\n' "$2" | docker exec -i -e PGAPPNAME="$1" "${CTN}" \
		psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt >"$3.out" 2>"$3.err" &
}

# wait_until <sql returning t> — polls for 20 s.
wait_until() {
	i=0
	until [ "$(q "$1")" = t ]; do
		i=$((i + 1))
		[ "${i}" -lt 200 ] || return 1
		sleep 0.1
	done
}

sleeping() { wait_until "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '$1' AND wait_event = 'PgSleep')"; }

# d6 — a decide whose session dies before COMMIT leaves nothing behind (S2).
check_killed_decide() {
	seed_page "${P4}" '[{"id":"k1","type":"paragraph","content":"kill me now"}]'
	s="55555555-0000-4000-8000-000000000031"
	suggest "${s}" "${P4}" k1 5 7 me 'kill ' ' now' you
	v0="$(version_of "${P4}")"
	bg_sql disc-kill "BEGIN; SELECT public.osionos_decide_suggestion('${s}', '${U1}', 'accepted'); SELECT pg_sleep(30); COMMIT;" "${WORK}/kill"
	pid=$!
	sleeping disc-kill || { printf '  FAIL d6 the decide never reached its sleep\n'; return 1; }
	q "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'disc-kill'" >/dev/null
	wait "${pid}" || true
	ok=0
	check d6 "the suggestion is still open" open "$(status_of "${s}")" || ok=1
	check d6 "the block text is unchanged" "kill me now" "$(block_text "${P4}" k1)" || ok=1
	check d6 "the version is unchanged" "${v0}" "$(version_of "${P4}")" || ok=1
	check d6 "a retry still applies" "kill you now" "$(decide "${s}" accepted >/dev/null && block_text "${P4}" k1)" || ok=1
	return "${ok}"
}

# d7 — the author edits the proposal while it is being accepted (S3, C14).
check_edit_race() {
	seed_page "${P5}" '[{"id":"e1","type":"paragraph","content":"edit race here"},{"id":"e2","type":"paragraph","content":"stamp check"}]'
	s="55555555-0000-4000-8000-000000000041"
	t="55555555-0000-4000-8000-000000000042"
	suggest "${s}" "${P5}" e1 5 9 race 'edit ' ' here' run
	bg_sql disc-edit "BEGIN; UPDATE public.osionos_page_comments SET suggestion = '{\"insert\":\"sprint\"}' WHERE id = '${s}'; SELECT pg_sleep(2); COMMIT;" "${WORK}/edit"
	pid=$!
	sleeping disc-edit || { printf '  FAIL d7 the edit never reached its sleep\n'; return 1; }
	out="$(decide "${s}" accepted)" || return 1
	wait "${pid}" || { printf '  FAIL d7 the racing edit failed: %s\n' "$(cat "${WORK}/edit.err")"; return 1; }
	ok=0
	check d7 "the accept waited for the edit" true "$(printf '%s' "${out}" | jq -r .ok)" || ok=1
	check d7 "the applied text is the stored insert" "edit sprint here" "$(block_text "${P5}" e1)" || ok=1

	suggest "${t}" "${P5}" e2 6 11 check 'stamp ' '' test
	seen="$(q "SELECT updated_at FROM public.osionos_page_comments WHERE id = '${t}'")"
	q "UPDATE public.osionos_page_comments SET suggestion = '{\"insert\":\"proof\"}' WHERE id = '${t}'" >/dev/null
	check d7 "an accepter who saw the old text is refused" "false changed" \
		"$(decide "${t}" accepted "${seen}" | jq -r '"\(.ok) \(.reason)"')" || ok=1
	check d7 "the refused accept wrote nothing" "stamp check" "$(block_text "${P5}" e2)" || ok=1
	fresh="$(q "SELECT updated_at FROM public.osionos_page_comments WHERE id = '${t}'")"
	check d7 "with the fresh stamp it applies" "stamp proof" "$(decide "${t}" accepted "${fresh}" >/dev/null && block_text "${P5}" e2)" || ok=1
	return "${ok}"
}

# d8 — 50 overlapping proposals accepted at once: one wins, 49 are superseded,
# nobody deadlocks; a reply, a reaction and a comment never wait on a held decide.
check_concurrent_accepts() {
	seed_page "${P6}" '[{"id":"c1","type":"paragraph","content":"the shared target words"},{"id":"c2","type":"paragraph","content":"held text here"}]'
	values=""
	n=1
	while [ "${n}" -le 50 ]; do
		values="${values}${values:+,}('77777777-0000-4000-8000-$(printf '%012d' "${n}")', '${P6}', 'c1', '${U2}', '', 'suggestion',
		  '{\"start\":4,\"end\":10,\"quote\":\"shared\",\"prefix\":\"the \",\"suffix\":\" target words\"}', '{\"insert\":\"s${n}\"}')"
		n=$((n + 1))
	done
	q "INSERT INTO public.osionos_page_comments (id, page_id, block_id, author_id, content, kind, anchor, suggestion) VALUES ${values}" >/dev/null || return 1
	bg_sql disc-gate "BEGIN; SELECT 1 FROM public.osionos_pages WHERE id = '${P6}' FOR NO KEY UPDATE; SELECT pg_sleep(4); COMMIT;" "${WORK}/gate"
	gate=$!
	sleeping disc-gate || { printf '  FAIL d8 the gate never held the page\n'; return 1; }
	pids=""
	n=1
	while [ "${n}" -le 50 ]; do
		bg_sql disc-race "SELECT public.osionos_decide_suggestion('77777777-0000-4000-8000-$(printf '%012d' "${n}")', '${U1}', 'accepted');" "${WORK}/race${n}"
		pids="${pids} $!"
		n=$((n + 1))
	done
	ok=0
	wait_until "SELECT count(*) >= 50 FROM pg_stat_activity WHERE application_name = 'disc-race' AND wait_event_type = 'Lock'" ||
		{ printf '  FAIL d8 fewer than 50 accepts were ever waiting together\n'; ok=1; }
	wait "${gate}" || true
	errors=0
	for pid in ${pids}; do wait "${pid}" || errors=$((errors + 1)); done
	check d8 "every accept returned without an error" 0 "${errors}" || { cat "${WORK}"/race*.err | sort | uniq -c | head -5; ok=1; }
	check d8 "exactly one accepted, 49 superseded" "accepted 1,superseded 49" \
		"$(q "SELECT string_agg(status || ' ' || n, ',' ORDER BY status) FROM (SELECT status, count(*) n FROM public.osionos_page_comments WHERE page_id = '${P6}' AND block_id = 'c1' GROUP BY status) s")" || ok=1
	check d8 "the losers answered decided" 49 "$(cat "${WORK}"/race*.out | jq -s '[.[] | select(.reason == "decided")] | length')" || ok=1
	check d8 "the text is the winner's insert" t \
		"$(q "SELECT block = 'the ' || (c.suggestion ->> 'insert') || ' target words' FROM public.osionos_page_comments c,
		      LATERAL (SELECT content #>> '{0,content}' AS block FROM public.osionos_pages WHERE id = '${P6}') p
		      WHERE c.page_id = '${P6}' AND c.status = 'accepted'")" || ok=1

	h="55555555-0000-4000-8000-000000000051"
	suggest "${h}" "${P6}" c2 0 4 held '' ' text here' kept
	bg_sql disc-held "BEGIN; SELECT public.osionos_decide_suggestion('${h}', '${U1}', 'accepted'); SELECT pg_sleep(3); COMMIT;" "${WORK}/held"
	held=$!
	sleeping disc-held || { printf '  FAIL d8 the held decide never reached its sleep\n'; return 1; }
	check d8 "a reply to the suggestion under decision" OK \
		"$(sqlstate_of "SET lock_timeout = '50ms'; INSERT INTO public.osionos_page_comments (page_id, author_id, content, parent_id) VALUES ('${P6}', '${U3}', 'why?', '${h}')")" || ok=1
	check d8 "a reaction to it" OK \
		"$(sqlstate_of "SET lock_timeout = '50ms'; INSERT INTO public.osionos_page_comment_reactions (comment_id, user_id, emoji) VALUES ('${h}', '${U3}', '👀')")" || ok=1
	check d8 "a comment on the page" OK \
		"$(sqlstate_of "SET lock_timeout = '50ms'; INSERT INTO public.osionos_page_comments (page_id, block_id, author_id, content) VALUES ('${P6}', 'c2', '${U3}', 'note')")" || ok=1
	wait "${held}" || { printf '  FAIL d8 the held decide failed: %s\n' "$(cat "${WORK}/held.err")"; ok=1; }
	return "${ok}"
}
