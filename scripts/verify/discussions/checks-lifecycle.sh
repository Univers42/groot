# shellcheck shell=sh
# Sourced by scripts/verify/discussions.sh: d9 delete guard and cascades, d10
# moderation and events, d11 erasure, d12 acl, d13 idempotence and rollback.
# shellcheck disable=SC2154

P7="33333333-0000-4000-8000-000000000007"
P8="33333333-0000-4000-8000-000000000008"
P10="33333333-0000-4000-8000-000000000010"
WS2="22222222-0000-4000-8000-000000000002"

# comment <id> <page> <author> [parent]
comment() {
	parent=NULL
	[ -z "${4:-}" ] || parent="'$4'"
	q "INSERT INTO public.osionos_page_comments (id, page_id, block_id, author_id, content, parent_id)
	   VALUES ('$1', '$2', 'b', '$3', 'text', ${parent})" >/dev/null
}

# discussion_on <page> <stem> — a root with a reply, a decided suggestion and a reaction.
discussion_on() {
	seed_page "$1" '[{"id":"b","type":"paragraph","content":"cascade body"}]'
	comment "$2-0000-4000-8000-000000000001" "$1" "${U2}"
	comment "$2-0000-4000-8000-000000000002" "$1" "${U3}" "$2-0000-4000-8000-000000000001"
	suggest "$2-0000-4000-8000-000000000003" "$1" b 0 7 cascade '' ' body' x
	decide "$2-0000-4000-8000-000000000003" rejected >/dev/null
	q "INSERT INTO public.osionos_page_comment_reactions (comment_id, user_id, emoji)
	   VALUES ('$2-0000-4000-8000-000000000003', '${U3}', '🎉')" >/dev/null
}

# d9 — the delete guard (S4) and the cascades that must still pass it (C13).
check_delete_and_cascades() {
	discussion_on "${P7}" 88888888
	ok=0
	check d9 "a root with a reply is not deleted" 23503 \
		"$(sqlstate_of "DELETE FROM public.osionos_page_comments WHERE id = '88888888-0000-4000-8000-000000000001'")" || ok=1
	check d9 "a decided suggestion is history" 23503 \
		"$(sqlstate_of "DELETE FROM public.osionos_page_comments WHERE id = '88888888-0000-4000-8000-000000000003'")" || ok=1
	check d9 "an accepted suggestion is history" 23503 \
		"$(sqlstate_of "DELETE FROM public.osionos_page_comments WHERE id = '${S_TOP}'")" || ok=1
	check d9 "a leaf reply deletes" OK \
		"$(sqlstate_of "DELETE FROM public.osionos_page_comments WHERE id = '88888888-0000-4000-8000-000000000002'")" || ok=1
	check d9 "then its root deletes" OK \
		"$(sqlstate_of "DELETE FROM public.osionos_page_comments WHERE id = '88888888-0000-4000-8000-000000000001'")" || ok=1

	discussion_on "${P8}" 99999999
	check d9 "deleting the page takes its discussions" OK "$(sqlstate_of "DELETE FROM public.osionos_pages WHERE id = '${P8}'")" || ok=1
	check d9 "nothing is left of them" 0 "$(q "SELECT count(*) FROM public.osionos_page_comments WHERE page_id = '${P8}'")" || ok=1
	q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${WS2}', '${U1}', 'gone', 'gone')" >/dev/null
	discussion_on "33333333-0000-4000-8000-000000000009" 9999aaaa
	q "UPDATE public.osionos_pages SET workspace_id = '${WS2}' WHERE id = '33333333-0000-4000-8000-000000000009'" >/dev/null
	check d9 "deleting the workspace takes them too" OK "$(sqlstate_of "DELETE FROM public.osionos_workspaces WHERE id = '${WS2}'")" || ok=1
	check d9 "and their reactions" 0 "$(q "SELECT count(*) FROM public.osionos_page_comment_reactions WHERE comment_id = '9999aaaa-0000-4000-8000-000000000003'")" || ok=1
	return "${ok}"
}

job_of() { q "SELECT coalesce(max(content_sha256 || ' ' || attempts), 'none') FROM public.ai_jobs WHERE subject_kind = 'page_comment' AND subject_id = '$1'"; }
comment_events() { q "SELECT count(*) FROM public.ai_events WHERE item_id = '${P10}' AND event = 'comment'"; }

# d10 — the proposed text is moderated like a comment body (S8); only a root
# comment is an interest signal.
check_moderation_events() {
	seed_page "${P10}" '[{"id":"m1","type":"paragraph","content":"moderate this"}]'
	m="55555555-0000-4000-8000-000000000061"
	ok=0
	events0="$(comment_events)"
	suggest "${m}" "${P10}" m1 9 13 this 'moderate ' '' that
	first="$(job_of "${m}")"
	[ "${first}" != none ] || { printf '  FAIL d10 a suggestion on a public page queued no moderation\n'; ok=1; }
	q "UPDATE public.ai_jobs SET attempts = 3 WHERE subject_kind = 'page_comment' AND subject_id = '${m}'" >/dev/null
	q "UPDATE public.osionos_page_comments SET suggestion = '{\"insert\":\"something rude\"}' WHERE id = '${m}'" >/dev/null
	second="$(job_of "${m}")"
	check d10 "a PATCH of the insert re-queues with a new hash" "different 0" \
		"$([ "${first%% *}" != "${second%% *}" ] && echo different || echo same) ${second##* }" || ok=1
	q "UPDATE public.ai_jobs SET attempts = 3 WHERE subject_kind = 'page_comment' AND subject_id = '${m}'" >/dev/null
	decide "${m}" rejected >/dev/null
	check d10 "a verdict does not re-queue" "${second%% *} 3" "$(job_of "${m}")" || ok=1
	check d10 "a suggestion is no comment event" "${events0}" "$(comment_events)" || ok=1
	comment "55555555-0000-4000-8000-000000000062" "${P10}" "${U3}"
	root_events="$(comment_events)"
	check d10 "a root comment is one" "$((events0 + 1))" "${root_events}" || ok=1
	comment "55555555-0000-4000-8000-000000000063" "${P10}" "${U2}" "55555555-0000-4000-8000-000000000062"
	check d10 "a reply is not" "${root_events}" "$(comment_events)" || ok=1
	return "${ok}"
}

# d11 — two users who reacted with the same emoji are erased one after the other (S7).
check_erasure() {
	target="88888888-0000-4000-8000-000000000003"
	decided="55555555-0000-4000-8000-000000000071"
	suggest "${decided}" "${P7}" b 8 12 body 'cascade ' '' text
	q "SELECT public.osionos_decide_suggestion('${decided}', '${U3}', 'rejected');
	   INSERT INTO public.osionos_page_comment_reactions (comment_id, user_id, emoji)
	   VALUES ('${target}', '${U2}', '🎉') ON CONFLICT DO NOTHING;
	   INSERT INTO public.osionos_account_deletion_requests (user_id, requested_at, scheduled_for)
	   VALUES ('${U2}', now() - interval '16 days', now() - interval '1 hour'),
	          ('${U3}', now() - interval '16 days', now() - interval '1 hour');" >/dev/null || return 1
	ok=0
	check d11 "the first eraser has a reaction to lose" 1 "$(q "SELECT count(*) FROM public.osionos_page_comment_reactions WHERE user_id = '${U2}' AND comment_id = '${target}'")" || ok=1
	check d11 "erase the first" OK "$(sqlstate_of "SELECT public.osionos_account_erase('${U2}')")" || { cat "${WORK}/st.err"; ok=1; }
	check d11 "erase the second (no 23505)" OK "$(sqlstate_of "SELECT public.osionos_account_erase('${U3}')")" || { cat "${WORK}/st.err"; ok=1; }
	check d11 "their reactions are gone" 0 "$(q "SELECT count(*) FROM public.osionos_page_comment_reactions WHERE user_id IN ('${U2}', '${U3}')")" || ok=1
	check d11 "the decider is a tombstone" t "$(q "SELECT decided_by = public.osionos_account_tombstone() FROM public.osionos_page_comments WHERE id = '${decided}'")" || ok=1
	check d11 "no comment names them" 0 "$(q "SELECT count(*) FROM public.osionos_page_comments WHERE '${U2}' IN (author_id, decided_by) OR '${U3}' IN (author_id, decided_by)")" || ok=1
	return "${ok}"
}

# d12 — only the bridge (service_role) decides or reads reactions.
check_acl() {
	ok=0
	for role in anon authenticated; do
		check d12 "${role} cannot decide" 42501 \
			"$(sqlstate_of "SET ROLE ${role}; SELECT public.osionos_decide_suggestion('${S_TOP}', '${U1}', 'rejected')")" || ok=1
		check d12 "${role} cannot read reactions" 42501 \
			"$(sqlstate_of "SET ROLE ${role}; SELECT count(*) FROM public.osionos_page_comment_reactions")" || ok=1
	done
	check d12 "service_role decides" OK \
		"$(sqlstate_of "SET ROLE service_role; SELECT public.osionos_decide_suggestion('${S_TOP}', '${U1}', 'rejected')")" || ok=1
	return "${ok}"
}

# What the discussions migration owns, by name (column positions move on a re-add).
snapshot() {
	q "SELECT md5(string_agg(x, E'\n' ORDER BY x)) FROM (
	     SELECT 'col ' || attname || ' ' || format_type(atttypid, atttypmod) || ' ' || attnotnull
	       FROM pg_attribute WHERE attrelid = 'public.osionos_page_comments'::regclass AND attnum > 0 AND NOT attisdropped
	     UNION ALL SELECT 'con ' || conname || ' ' || pg_get_constraintdef(oid) || ' ' || convalidated
	       FROM pg_constraint WHERE conrelid IN ('public.osionos_page_comments'::regclass, 'public.osionos_page_comment_reactions'::regclass)
	     UNION ALL SELECT 'trg ' || tgname || ' ' || pg_get_triggerdef(oid)
	       FROM pg_trigger WHERE tgrelid = 'public.osionos_page_comments'::regclass AND NOT tgisinternal
	     UNION ALL SELECT 'idx ' || indexrelid::regclass || ' ' || pg_get_indexdef(indexrelid)
	       FROM pg_index WHERE indrelid = 'public.osionos_page_comments'::regclass
	     UNION ALL SELECT 'fn ' || p.oid::regprocedure || ' ' || md5(pg_get_functiondef(p.oid)) || ' ' || coalesce(p.proacl::text, '')
	       FROM pg_proc p WHERE p.proname ~ '^(osionos_(suggestion|suggestions|block_path|decide_suggestion|page_comments_guard)|ai_(jobs_enqueue|events_capture)_page_comments)'
	     UNION ALL SELECT 'acl ' || coalesce(relacl::text, '') || ' ' || relrowsecurity
	       FROM pg_class WHERE oid = 'public.osionos_page_comment_reactions'::regclass) s(x)"
}

# d13 — the migration twice is a no-op; the rollbacks leave plain comments working;
# a re-apply restores exactly what was there (S14).
check_idempotent_and_rollback() {
	ok=0
	first="$(snapshot)"
	apply "${MODELS}/osionos-discussions-migration.sql" || return 1
	check d13 "a second apply changes nothing" "${first}" "$(snapshot)" || ok=1
	apply "${MODELS}/rollback/osionos-ugc-moderation-rollback.sql" || return 1
	apply "${MODELS}/rollback/osionos-discussions-rollback.sql" || return 1
	apply "${MODELS}/rollback/osionos-discussions-rollback.sql" || { printf '  FAIL d13 the rollback is not idempotent\n'; return 1; }
	check d13 "the columns are gone" 0 \
		"$(q "SELECT count(*) FROM pg_attribute WHERE attrelid = 'public.osionos_page_comments'::regclass AND attname IN ('parent_id', 'kind', 'anchor', 'suggestion', 'status') AND NOT attisdropped")" || ok=1
	check d13 "the reactions table is gone" "" "$(q "SELECT to_regclass('public.osionos_page_comment_reactions')")" || ok=1
	check d13 "a plain comment still inserts" OK \
		"$(sqlstate_of "INSERT INTO public.osionos_page_comments (page_id, block_id, author_id, content) VALUES ('${P10}', 'm1', '${U1}', 'after rollback')")" || ok=1
	check d13 "and still counts as a comment event" 1 \
		"$(q "SELECT count(*) FROM public.ai_events WHERE item_id = '${P10}' AND event = 'comment' AND user_id = '${U1}'")" || ok=1
	check d13 "a plain comment with replies' rows deletes" OK \
		"$(sqlstate_of "DELETE FROM public.osionos_page_comments WHERE page_id = '${P7}'")" || ok=1
	apply "${MODELS}/osionos-discussions-migration.sql" || return 1
	apply "${MODELS}/osionos-ugc-moderation-migration.sql" || return 1
	check d13 "a re-apply restores the same objects" "${first}" "$(snapshot)" || ok=1
	return "${ok}"
}
