# page-version/checks-db.sh — the checks that only need psql: the version
# semantics, the two concurrent races, the idempotency, the position (c1–c5).
#
# Sourced by scripts/verify/page-version.sh, which calls these checks: the
# linter reads one file at a time and calls them unreachable.
# shellcheck disable=SC2317,SC2329

# --- c1: the version is a CONTENT version ------------------------------------

# The check reads DELTAS, not absolute versions, so it can be run twice on the
# same page (the revert proof runs it again). The content it writes is unique
# per run, so the content delta is 1 every time.
RUN=0
check_metadata() {
	RUN=$((RUN + 1))
	v0="$(version_of "${P1}")"
	q "UPDATE public.osionos_pages SET title = 'renamed' WHERE id = '${P1}'" >/dev/null
	v1="$(version_of "${P1}")"
	q "UPDATE public.osionos_pages SET archived_at = now() WHERE id = '${P1}'" >/dev/null
	v2="$(version_of "${P1}")"
	q "UPDATE public.osionos_pages SET properties = '[{\"id\":\"k\"}]'::jsonb WHERE id = '${P1}'" >/dev/null
	v3="$(version_of "${P1}")"
	q "UPDATE public.osionos_pages SET content = '[{\"id\":\"c1-${RUN}\",\"type\":\"text\",\"content\":\"x-${RUN}\"}]'::jsonb WHERE id = '${P1}'" >/dev/null
	v4="$(version_of "${P1}")"

	d1=$((v1 - v0)); d2=$((v2 - v1)); d3=$((v3 - v2)); d4=$((v4 - v3))
	if [ "${d1}" = "0" ] && [ "${d2}" = "0" ] && [ "${d3}" = "0" ]; then
		printf 'PASS c1 metadata-update    title/archived_at/properties left the version alone (deltas %s/%s/%s, version %s)\n' "${d1}" "${d2}" "${d3}" "${v3}"
	else
		printf 'FAIL c1 metadata-update    a metadata update moved the version (deltas title=%s archive=%s properties=%s; version %s -> %s)\n' "${d1}" "${d2}" "${d3}" "${v0}" "${v3}"
		return 1
	fi
	if [ "${d4}" = "1" ]; then
		printf 'PASS c1 content-update     a content update moved the version by exactly 1 (%s -> %s)\n' "${v3}" "${v4}"
	else
		printf 'FAIL c1 content-update     a content update moved the version by %s (expected 1; %s -> %s)\n' "${d4}" "${v3}" "${v4}"
		return 1
	fi
	return 0
}

# --- c2: two concurrent conditional updates ----------------------------------

check_conditional_race() {
	cat >"${WORK}/race.sql" <<SQL
WITH u AS (
  UPDATE public.osionos_pages SET content = '[{"id":"race-a","type":"text","content":"a"}]'::jsonb
   WHERE id = '${P2}' AND version = 0 RETURNING 1
) SELECT count(*) FROM u;
SQL
	docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt <"${WORK}/race.sql" \
		>"${WORK}/race-a.out" 2>&1 &
	pa=$!
	docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt <"${WORK}/race.sql" \
		>"${WORK}/race-b.out" 2>&1 &
	pb=$!
	wait "${pa}"
	wait "${pb}"
	a="$(tail -1 "${WORK}/race-a.out")"
	b="$(tail -1 "${WORK}/race-b.out")"
	sum=$((a + b))
	v="$(version_of "${P2}")"
	if [ "${sum}" = "1" ]; then
		printf 'PASS c2 conditional-race   two concurrent updates at version 0: exactly one row updated (a=%s b=%s)\n' "${a}" "${b}"
	else
		printf 'FAIL c2 conditional-race   two concurrent updates at version 0: %s rows updated (a=%s b=%s)\n' "${sum}" "${a}" "${b}"
		return 1
	fi
	if [ "${v}" = "1" ]; then
		printf 'PASS c2 version-after-race the surviving write left the version at 1\n'
	else
		printf 'FAIL c2 version-after-race the version is %s (expected 1)\n' "${v}"
		return 1
	fi
	return 0
}

# --- c3: two concurrent appends ----------------------------------------------

check_append_race() {
	# A holds the row lock until it commits, so B really overlaps with A.
	cat >"${WORK}/append-a.sql" <<SQL
BEGIN;
SELECT public.osionos_page_append('${P3}', '[{"id":"blk-a","type":"text","content":"A"}]'::jsonb, NULL, 'key-a');
SELECT pg_sleep(3);
COMMIT;
SQL
	cat >"${WORK}/append-b.sql" <<SQL
SELECT public.osionos_page_append('${P3}', '[{"id":"blk-b","type":"text","content":"B"}]'::jsonb, NULL, 'key-b');
SQL
	docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt <"${WORK}/append-a.sql" \
		>"${WORK}/append-a.out" 2>&1 &
	pa=$!
	sleep 1
	t0="$(date +%s)"
	docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt <"${WORK}/append-b.sql" \
		>"${WORK}/append-b.out" 2>&1
	t1="$(date +%s)"
	wait "${pa}"
	waited=$((t1 - t0))
	blocks="$(q "SELECT jsonb_array_length(content) FROM public.osionos_pages WHERE id = '${P3}'")"
	v="$(version_of "${P3}")"
	has_a="$(q "SELECT count(*) FROM public.osionos_pages p, jsonb_array_elements(p.content) b WHERE p.id = '${P3}' AND b ->> 'id' = 'blk-a'")"
	has_b="$(q "SELECT count(*) FROM public.osionos_pages p, jsonb_array_elements(p.content) b WHERE p.id = '${P3}' AND b ->> 'id' = 'blk-b'")"
	has_orig="$(q "SELECT count(*) FROM public.osionos_pages p, jsonb_array_elements(p.content) b WHERE p.id = '${P3}' AND b ->> 'id' = 'orig'")"
	if [ "${blocks}" = "3" ] && [ "${has_a}" = "1" ] && [ "${has_b}" = "1" ] && [ "${has_orig}" = "1" ]; then
		printf 'PASS c3 append-race        both concurrent appends landed: %s blocks (orig + blk-a + blk-b), nothing lost\n' "${blocks}"
	else
		printf 'FAIL c3 append-race        blocks=%s orig=%s blk-a=%s blk-b=%s (expected 3/1/1/1)\n' "${blocks}" "${has_orig}" "${has_a}" "${has_b}"
		return 1
	fi
	if [ "${v}" = "2" ]; then
		printf 'PASS c3 append-race-version the version is 2 after two appends\n'
	else
		printf 'FAIL c3 append-race-version the version is %s (expected 2)\n' "${v}"
		return 1
	fi
	if [ "${waited}" -ge 2 ]; then
		printf 'PASS c3 append-race-overlap the second append waited %ss for the lock the first one held (they overlapped)\n' "${waited}"
	else
		printf 'FAIL c3 append-race-overlap the second append did not wait (0s) — the two calls never overlapped\n'
		return 1
	fi
	return 0
}

# --- c4: idempotency ---------------------------------------------------------

check_idempotency() {
	q "SELECT * FROM public.osionos_page_append('${P4}', '[{\"id\":\"dup\",\"type\":\"text\",\"content\":\"d\"}]'::jsonb, NULL, 'key-1')" >"${WORK}/idem-first.out"
	v1="$(version_of "${P4}")"
	n1="$(q "SELECT count(*) FROM public.osionos_pages p, jsonb_array_elements(p.content) b WHERE p.id = '${P4}' AND b ->> 'id' = 'dup'")"
	first_ver="$(cut -d'|' -f1 <"${WORK}/idem-first.out")"
	# The same key again: the stored version and the CURRENT content, no append.
	q "SELECT * FROM public.osionos_page_append('${P4}', '[{\"id\":\"dup\",\"type\":\"text\",\"content\":\"d\"}]'::jsonb, NULL, 'key-1')" >"${WORK}/idem-repeat.out"
	rep_ver="$(cut -d'|' -f1 <"${WORK}/idem-repeat.out")"
	v2="$(version_of "${P4}")"
	n2="$(q "SELECT count(*) FROM public.osionos_pages p, jsonb_array_elements(p.content) b WHERE p.id = '${P4}' AND b ->> 'id' = 'dup'")"
	# A different key: a second copy.
	q "SELECT public.osionos_page_append('${P4}', '[{\"id\":\"dup\",\"type\":\"text\",\"content\":\"d\"}]'::jsonb, NULL, 'key-2')" >/dev/null
	v3="$(version_of "${P4}")"
	n3="$(q "SELECT count(*) FROM public.osionos_pages p, jsonb_array_elements(p.content) b WHERE p.id = '${P4}' AND b ->> 'id' = 'dup'")"
	if [ "${n1}" = "1" ] && [ "${n2}" = "1" ] && [ "${v1}" = "1" ] && [ "${v2}" = "1" ]; then
		printf 'PASS c4 same-key          the same idempotency key twice left ONE copy of the blocks (version stayed %s)\n' "${v2}"
	else
		printf 'FAIL c4 same-key          copies after 1st=%s after 2nd=%s, versions %s/%s (expected 1/1 and 1/1)\n' "${n1}" "${n2}" "${v1}" "${v2}"
		return 1
	fi
	if [ "${rep_ver}" = "${first_ver}" ]; then
		printf 'PASS c4 same-key-version  the repeat answered the stored version %s (the first call answered %s)\n' "${rep_ver}" "${first_ver}"
	else
		printf 'FAIL c4 same-key-version  the repeat answered version %s, the first call answered %s\n' "${rep_ver}" "${first_ver}"
		return 1
	fi
	if [ "${n3}" = "2" ] && [ "${v3}" = "2" ]; then
		printf 'PASS c4 different-key     two different keys left TWO copies of the blocks (version %s)\n' "${v3}"
	else
		printf 'FAIL c4 different-key     copies=%s version=%s (expected 2 and 2)\n' "${n3}" "${v3}"
		return 1
	fi
	return 0
}

# --- c5: position and validation ---------------------------------------------

check_position() {
	q "SELECT public.osionos_page_append('${P5}', '[{\"id\":\"new1\",\"type\":\"text\",\"content\":\"n\"}]'::jsonb, 'b1', 'pos-1')" >/dev/null
	ids1="$(q "SELECT string_agg(b ->> 'id', ',' ORDER BY o) FROM public.osionos_pages p, jsonb_array_elements(p.content) WITH ORDINALITY AS x(b, o) WHERE p.id = '${P5}'")"
	q "SELECT public.osionos_page_append('${P5}', '[{\"id\":\"new2\",\"type\":\"text\",\"content\":\"n\"}]'::jsonb, 'nope', 'pos-2')" >/dev/null
	ids2="$(q "SELECT string_agg(b ->> 'id', ',' ORDER BY o) FROM public.osionos_pages p, jsonb_array_elements(p.content) WITH ORDINALITY AS x(b, o) WHERE p.id = '${P5}'")"
	if [ "${ids1}" = "b1,new1,b2,b3" ]; then
		printf 'PASS c5 after-block       the blocks landed right after b1 (%s)\n' "${ids1}"
	else
		printf 'FAIL c5 after-block       the order is %s (expected b1,new1,b2,b3)\n' "${ids1}"
		return 1
	fi
	if [ "${ids2}" = "b1,new1,b2,b3,new2" ]; then
		printf 'PASS c5 unknown-id       an unknown id appended at the end (%s)\n' "${ids2}"
	else
		printf 'FAIL c5 unknown-id       the order is %s (expected b1,new1,b2,b3,new2)\n' "${ids2}"
		return 1
	fi
	if e="$(must_raise "SELECT public.osionos_page_append('${P5}', '{\"id\":\"x\"}'::jsonb, NULL, 'bad-1')")"; then
		printf 'PASS c5 non-array-raises  a non-array p_blocks raised: %s\n' "${e}"
	else
		printf 'FAIL c5 non-array-raises  a non-array p_blocks did NOT raise\n'
		return 1
	fi
	if e="$(must_raise "SELECT public.osionos_page_append('${P5}', '[{\"type\":\"text\"}]'::jsonb, NULL, 'bad-2')")"; then
		printf 'PASS c5 id-less-raises    an id-less block raised: %s\n' "${e}"
	else
		printf 'FAIL c5 id-less-raises    an id-less block did NOT raise\n'
		return 1
	fi
	if e="$(must_raise "SELECT public.osionos_page_append('${P5}', '[]'::jsonb, NULL, 'bad-3')")"; then
		printf 'PASS c5 empty-raises      an empty p_blocks raised: %s\n' "${e}"
	else
		printf 'FAIL c5 empty-raises      an empty p_blocks did NOT raise\n'
		return 1
	fi
	return 0
}
