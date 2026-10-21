#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    page-version.sh                                                           #
#                                                                              #
#    Prove the page content version and the atomic append                      #
#    (models/osionos-page-version-migration.sql) on a throwaway database.      #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES
#   c1  a title / archived_at / properties update leaves version alone; a
#       content update adds exactly 1 (C15: the version is a CONTENT version).
#   c2  two concurrent `update … where id = $1 and version = $2` at the same
#       version: exactly one row is updated.
#   c3  osionos_page_append from two concurrent sessions: both blocks are
#       present, the version is +2, nothing is lost.
#   c4  the same idempotency key twice leaves ONE copy of the blocks; two
#       different keys leave two (C21).
#   c5  p_after_block_id puts the blocks right after that top-level block; an
#       unknown id appends at the end; a non-array / id-less / empty input
#       raises.
#   c6  re-running the whole migration is a no-op (no drift in the column, the
#       trigger, the function, the ACL or the stored versions).
#   c7  anon and authenticated cannot execute the function; service_role can.
#   c8  U1 + U4 through a throwaway PostgREST: a conditional PATCH answers
#       200 [] with Prefer: return=representation and 204 with return=minimal;
#       POST /rpc/osionos_page_append works for the service role.
#   c9  the revert proof: drop the content predicate from the trigger (bump on
#       EVERY update) and c1 FAILS; the trigger is then restored.
#
# ISOLATION
#   Throwaway containers only, on a network this script creates and removes:
#   ai-pv-net, ai-pv-pg (pgvector/pgvector:0.8.0-pg16) and ai-pv-pgrst
#   (postgrest/postgrest). The live mini-baas-*, track-binocle-*, ai-dev-*,
#   ai-eval-* and ai-gpu-* containers are never read, written or stopped: this
#   script only ever names the ai-pv-* ones.
#
# THE FIXTURE
#   scripts/verify/models-grants.sh and models-first-run.sh drive the real
#   runner against the grobase stack, which needs the apps/grobase submodule
#   (not initialised here). This script reuses their roles fixture
#   (scripts/verify/models-grants/roles.sql) and applies the same migrations
#   the runner applies FIRST (bridge, page-search) plus the file under test
#   and the service-role-only sweep that closes the osionos_* relations.
#
# Usage:  sh scripts/verify/page-version.sh [--keep]
#           --keep   leave the containers and the network up afterwards
#
# Env:    PG_IMAGE      (default pgvector/pgvector:0.8.0-pg16)
#         PGRST_IMAGE   (default postgrest/postgrest:v12.2.3)
#         PGRST_PORT    (default 33199, bound to 127.0.0.1)
#
# Exit:   0 every check passed · 1 a check failed · 2 docker is missing
#
# Ponytail: the trigger, the version and the append function are the whole
#   subject; nothing else of the model layer is exercised here.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MODELS="${REPO}/models"
FIX="${REPO}/scripts/verify/models-grants"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
PGRST_IMAGE="${PGRST_IMAGE:-postgrest/postgrest:v12.2.3}"
PGRST_PORT="${PGRST_PORT:-33199}"
NET="ai-pv-net"
# An explicit subnet: the 172.16-172.31 default pool is full on this machine (31
# other networks live there), and this script must not touch any of them.
PV_SUBNET="${PV_SUBNET:-10.88.7.0/24}"
PG_CTN="ai-pv-pg"
PGRST_CTN="ai-pv-pgrst"
JWT_SECRET="ai-pv-verify-secret-0123456789abcdefghij"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/page-version.XXXXXX")"
passed=0
failed=0

note() { printf '[page-version] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s %s\n' "$1" "$2"; }

teardown() {
	[ "${KEEP}" -eq 1 ] && { note "--keep: ${PG_CTN} / ${PGRST_CTN} / ${NET} left up"; return 0; }
	docker rm -f "${PGRST_CTN}" >/dev/null 2>&1 || true
	docker rm -f "${PG_CTN}" >/dev/null 2>&1 || true
	docker network rm "${NET}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

# --- psql helpers ------------------------------------------------------------

# psql in the throwaway container; -qAt = quiet, unaligned, tuples only.
psql_q() {
	docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt
}

# q <sql> — run one statement, print its rows.
q() {
	printf '%s\n' "$1" | psql_q
}

# qf <file> — run a file, print its rows.
qf() {
	docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt <"$1"
}

# apply <file> — psql a file with ON_ERROR_STOP; the stderr is echoed on failure.
apply() {
	if docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <"$1" \
		>"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

# must_raise <sql> — the statement must fail; prints the psql error.
must_raise() {
	err="${WORK}/raise.err"
	if printf '%s\n' "$1" | docker exec -i "${PG_CTN}" psql -U postgres -d postgres \
		-v ON_ERROR_STOP=1 -qAt >"${WORK}/raise.out" 2>"${err}"; then
		return 1
	fi
	grep -m1 'ERROR:' "${err}" || head -1 "${err}"
	return 0
}

# --- fixture -----------------------------------------------------------------

start_pg() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"; exit 2
	}
	docker network create --subnet "${PV_SUBNET}" "${NET}" >/dev/null
	docker run -d --name "${PG_CTN}" --network "${NET}" \
		-e POSTGRES_HOST_AUTH_METHOD=trust "${PG_IMAGE}" >/dev/null
	i=0
	while [ "${i}" -lt 60 ]; do
		if docker exec "${PG_CTN}" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	note "postgres never became ready"
	exit 1
}

apply_fixture() {
	apply "${FIX}/roles.sql" || exit 1
	apply "${MODELS}/osionos-bridge-migration.sql" || exit 1
	apply "${MODELS}/osionos-page-search-migration.sql" || exit 1
	apply "${MODELS}/osionos-page-version-migration.sql" || exit 1
	# The sweep the runner runs LAST (ORDERED_LAST): it must reach the new
	# osionos_page_append_keys table.
	apply "${MODELS}/osionos-service-role-only-migration.sql" || exit 1
}

# The pages every check works on. P1 version semantics, P2 the conditional
# update race, P3 the append race, P4 idempotency, P5 positioning.
seed() {
	q "
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug)
VALUES ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'verify', 'verify');
INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title, content) VALUES
 ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'p1', '[]'::jsonb),
 ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'p2', '[]'::jsonb),
 ('aaaaaaaa-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'p3', '[{\"id\":\"orig\",\"type\":\"text\",\"content\":\"o\"}]'::jsonb),
 ('aaaaaaaa-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'p4', '[]'::jsonb),
 ('aaaaaaaa-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'p5', '[{\"id\":\"b1\",\"type\":\"text\",\"content\":\"1\"},{\"id\":\"b2\",\"type\":\"text\",\"content\":\"2\"},{\"id\":\"b3\",\"type\":\"text\",\"content\":\"3\"}]'::jsonb);
" >/dev/null
}

P1="aaaaaaaa-0000-0000-0000-000000000001"
P2="aaaaaaaa-0000-0000-0000-000000000002"
P3="aaaaaaaa-0000-0000-0000-000000000003"
P4="aaaaaaaa-0000-0000-0000-000000000004"
P5="aaaaaaaa-0000-0000-0000-000000000005"

version_of() {
	q "SELECT version FROM public.osionos_pages WHERE id = '$1'"
}

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

# --- c6: the migration is re-runnable ----------------------------------------

snapshot() {
	q "
SELECT 'column|' || column_name || '|' || data_type || '|' || is_nullable || '|' || column_default
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'osionos_pages' AND column_name = 'version';
SELECT 'trigger|' || tgname || '|' || pg_get_triggerdef(oid)
  FROM pg_trigger
 WHERE tgrelid = 'public.osionos_pages'::regclass AND NOT tgisinternal ORDER BY tgname;
SELECT 'func|' || md5(prosrc) FROM pg_proc
 WHERE oid = 'public.osionos_page_append(uuid,jsonb,text,text)'::regprocedure;
SELECT 'priv|' || rolname || '|' || has_function_privilege(rolname, 'public.osionos_page_append(uuid,jsonb,text,text)', 'EXECUTE')
  FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') ORDER BY rolname;
SELECT 'tblpriv|' || rolname || '|' || has_table_privilege(rolname, 'public.osionos_page_append_keys', 'SELECT,INSERT,UPDATE,DELETE')
  FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') ORDER BY rolname;
SELECT 'rows|' || id || '|' || version FROM public.osionos_pages ORDER BY id;
"
}

check_idempotent_apply() {
	snapshot >"${WORK}/snap1.out"
	apply "${MODELS}/osionos-page-version-migration.sql" || return 1
	apply "${MODELS}/osionos-page-version-migration.sql" || return 1
	snapshot >"${WORK}/snap2.out"
	if diff -u "${WORK}/snap1.out" "${WORK}/snap2.out" >"${WORK}/snap.diff" 2>&1; then
		printf 'PASS c6 idempotent-apply  re-running the migration twice changed no column, trigger, function, ACL or stored version\n'
	else
		printf 'FAIL c6 idempotent-apply  the re-run drifted:\n'
		sed 's/^/  | /' "${WORK}/snap.diff" >&2
		return 1
	fi
	trg="$(q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.osionos_pages'::regclass AND tgname = 'osionos_pages_version_trg'")"
	if [ "${trg}" = "1" ]; then
		printf 'PASS c6 one-trigger       exactly one osionos_pages_version_trg on osionos_pages\n'
	else
		printf 'FAIL c6 one-trigger       %s version triggers on osionos_pages (expected 1)\n' "${trg}"
		return 1
	fi
	return 0
}

# --- c7: the ACL -------------------------------------------------------------

# probe <role> <sql> — the statement must be refused with SQLSTATE 42501.
probe_denied() {
	err="${WORK}/probe-$1.err"
	printf '%s\n' '\set VERBOSITY sqlstate' 'BEGIN;' "SET LOCAL ROLE $1;" "$2;" 'ROLLBACK;' |
		docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		>"${WORK}/probe-$1.out" 2>"${err}" && rc=0 || rc=$?
	codes="$(sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' "${err}" | sort -u | tr '\n' ' ')"
	if [ "${rc}" -ne 0 ] && [ "${codes}" = "42501 " ]; then
		return 0
	fi
	return 1
}

check_acl() {
	append_call="SELECT * FROM public.osionos_page_append('${P4}', '[{\"id\":\"acl\",\"type\":\"text\",\"content\":\"a\"}]'::jsonb, NULL, 'acl-1')"
	if probe_denied anon "${append_call}"; then
		printf 'PASS c7 anon-denied       anon cannot execute the function (42501)\n'
	else
		printf 'FAIL c7 anon-denied       anon was NOT refused\n'
		return 1
	fi
	if probe_denied authenticated "${append_call}"; then
		printf 'PASS c7 authenticated-denied authenticated cannot execute the function (42501)\n'
	else
		printf 'FAIL c7 authenticated-denied authenticated was NOT refused\n'
		return 1
	fi
	out="$(q "BEGIN; SET LOCAL ROLE service_role; ${append_call}; COMMIT;" 2>&1 || true)"
	if printf '%s' "${out}" | grep -q 'acl'; then
		printf 'PASS c7 service-role      service_role CAN execute the function\n'
	else
		printf 'FAIL c7 service-role      service_role could NOT execute the function: %s\n' "${out}"
		return 1
	fi
	tbl="$(q "SELECT count(*) FROM pg_roles r WHERE r.rolname IN ('anon','authenticated') AND has_table_privilege(r.rolname, 'public.osionos_page_append_keys', 'SELECT,INSERT,UPDATE,DELETE')")"
	if [ "${tbl}" = "0" ]; then
		printf 'PASS c7 keys-table        anon and authenticated hold no privilege on osionos_page_append_keys\n'
	else
		printf 'FAIL c7 keys-table        %s role(s) still hold a privilege on the keys table\n' "${tbl}"
		return 1
	fi
	return 0
}

# --- c8: PostgREST (U1 + U4) -------------------------------------------------

mint_jwt() {
	JWT_SECRET="${JWT_SECRET}" python3 -c '
import base64, hashlib, hmac, json, os, sys, time
role = sys.argv[1]
secret = os.environ["JWT_SECRET"].encode()
def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=")
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
now = int(time.time())
pay = b64(json.dumps({"role": role, "iat": now, "exp": now + 3600}, separators=(",", ":")).encode())
sig = b64(hmac.new(secret, head + b"." + pay, hashlib.sha256).digest())
print((head + b"." + pay + b"." + sig).decode())
' "$1"
}

start_postgrest() {
	docker run -d --name "${PGRST_CTN}" --network "${NET}" \
		-p "127.0.0.1:${PGRST_PORT}:3000" \
		-e PGRST_DB_URI="postgresql://authenticator@${PG_CTN}:5432/postgres" \
		-e PGRST_DB_SCHEMAS=public \
		-e PGRST_DB_ANON_ROLE=anon \
		-e PGRST_JWT_SECRET="${JWT_SECRET}" \
		-e PGRST_SERVER_PORT=3000 \
		"${PGRST_IMAGE}" >/dev/null
	i=0
	while [ "${i}" -lt 60 ]; do
		if curl -sS -o /dev/null "http://127.0.0.1:${PGRST_PORT}/" 2>/dev/null; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	note "postgrest never answered"
	docker logs "${PGRST_CTN}" >&2 || true
	return 1
}

check_postgrest() {
	start_postgrest || return 1
	# A bare PostgREST serves the REST API at "/" — the grobase stack puts Kong in
	# front of it and strips the /rest/v1 prefix, so the path here is the one the
	# bridge uses minus that prefix.
	base="http://127.0.0.1:${PGRST_PORT}"
	svc="$(mint_jwt service_role)"
	anon="$(mint_jwt anon)"

	# U1: a conditional PATCH that matches no row. return=representation must
	# answer 200 with [], return=minimal must answer 204.
	curl -sS -o "${WORK}/u1-rep.body" -D "${WORK}/u1-rep.head" \
		-X PATCH "${base}/osionos_pages?id=eq.${P2}&version=eq.999" \
		-H "apikey: ${svc}" -H "Authorization: Bearer ${svc}" \
		-H "Prefer: return=representation" -H "Content-Type: application/json" \
		-d '{"title":"probe"}'
	rep_code="$(awk 'NR==1 {print $2}' "${WORK}/u1-rep.head")"
	rep_body="$(tr -d '\n' <"${WORK}/u1-rep.body")"
	printf '[U1] PATCH osionos_pages?id=eq.%s&version=eq.999 (Prefer: return=representation)\n' "${P2}" >&2
	sed 's/^/[U1] /' "${WORK}/u1-rep.head" >&2
	printf '[U1] body: %s\n' "${rep_body}" >&2

	curl -sS -o "${WORK}/u1-min.body" -D "${WORK}/u1-min.head" \
		-X PATCH "${base}/osionos_pages?id=eq.${P2}&version=eq.999" \
		-H "apikey: ${svc}" -H "Authorization: Bearer ${svc}" \
		-H "Prefer: return=minimal" -H "Content-Type: application/json" \
		-d '{"title":"probe"}'
	min_code="$(awk 'NR==1 {print $2}' "${WORK}/u1-min.head")"
	printf '[U1] PATCH osionos_pages?id=eq.%s&version=eq.999 (Prefer: return=minimal)\n' "${P2}" >&2
	sed 's/^/[U1] /' "${WORK}/u1-min.head" >&2
	printf '[U1] body: %s\n' "$(tr -d '\n' <"${WORK}/u1-min.body")" >&2

	if [ "${rep_code}" = "200" ] && [ "${rep_body}" = "[]" ]; then
		printf 'PASS c8 u1-representation  the conditional PATCH answered 200 []\n'
	else
		printf 'FAIL c8 u1-representation  the conditional PATCH answered %s %s (expected 200 [])\n' "${rep_code}" "${rep_body}"
		return 1
	fi
	if [ "${min_code}" = "204" ]; then
		printf 'PASS c8 u1-minimal        the same PATCH with return=minimal answered 204\n'
	else
		printf 'FAIL c8 u1-minimal        the same PATCH with return=minimal answered %s (expected 204)\n' "${min_code}"
		return 1
	fi

	# U4: the append over RPC, as the service role.
	curl -sS -o "${WORK}/u4.body" -D "${WORK}/u4.head" \
		-X POST "${base}/rpc/osionos_page_append" \
		-H "apikey: ${svc}" -H "Authorization: Bearer ${svc}" \
		-H "Content-Type: application/json" \
		-d "{\"p_page_id\":\"${P5}\",\"p_blocks\":[{\"id\":\"rpc-1\",\"type\":\"text\",\"content\":\"R\"}],\"p_after_block_id\":null,\"p_idempotency_key\":\"rpc-key-1\"}"
	u4_code="$(awk 'NR==1 {print $2}' "${WORK}/u4.head")"
	u4_body="$(tr -d '\n' <"${WORK}/u4.body")"
	printf '[U4] POST /rpc/osionos_page_append (service_role)\n' >&2
	sed 's/^/[U4] /' "${WORK}/u4.head" >&2
	printf '[U4] body: %s\n' "${u4_body}" >&2
	if [ "${u4_code}" = "200" ] && printf '%s' "${u4_body}" | grep -q 'rpc-1'; then
		printf 'PASS c8 u4-rpc             POST /rpc/osionos_page_append answered 200 with the appended block\n'
	else
		printf 'FAIL c8 u4-rpc             POST /rpc/osionos_page_append answered %s %s\n' "${u4_code}" "${u4_body}"
		return 1
	fi

	# The same call as anon must be refused.
	curl -sS -o "${WORK}/anon.body" -D "${WORK}/anon.head" \
		-X POST "${base}/rpc/osionos_page_append" \
		-H "apikey: ${anon}" -H "Authorization: Bearer ${anon}" \
		-H "Content-Type: application/json" \
		-d "{\"p_page_id\":\"${P5}\",\"p_blocks\":[{\"id\":\"rpc-anon\"}],\"p_after_block_id\":null,\"p_idempotency_key\":\"rpc-key-anon\"}"
	anon_code="$(awk 'NR==1 {print $2}' "${WORK}/anon.head")"
	printf '[ACL] POST /rpc/osionos_page_append (anon)\n' >&2
	sed 's/^/[ACL] /' "${WORK}/anon.head" >&2
	printf '[ACL] body: %s\n' "$(tr -d '\n' <"${WORK}/anon.body")" >&2
	case "${anon_code}" in
	401 | 403 | 404) printf 'PASS c8 anon-rpc          anon was refused with %s\n' "${anon_code}" ;;
	*) printf 'FAIL c8 anon-rpc          anon was NOT refused (answered %s)\n' "${anon_code}"; return 1 ;;
	esac
	return 0
}

# --- c9: the revert proof ----------------------------------------------------

check_revert_proof() {
	# The broken trigger: bump on EVERY update, the content predicate gone.
	q "
CREATE OR REPLACE FUNCTION public.osionos_page_bump_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS \$\$
BEGIN
  NEW.version := OLD.version + 1;
  RETURN NEW;
END \$\$;
" >/dev/null
	if check_metadata >"${WORK}/revert.out" 2>&1; then
		printf 'FAIL c9 revert-proof       c1 PASSED with the content predicate removed — the predicate is not what the check reads\n'
		sed 's/^/  | /' "${WORK}/revert.out" >&2
		apply "${MODELS}/osionos-page-version-migration.sql" || true
		return 1
	fi
	printf '[revert-proof] the content predicate is gone from the trigger (bump on every update):\n' >&2
	sed 's/^/[revert-proof] /' "${WORK}/revert.out" >&2
	# Restore: the migration file is the source of truth.
	apply "${MODELS}/osionos-page-version-migration.sql" || return 1
	if check_metadata >"${WORK}/restored.out" 2>&1; then
		printf '[revert-proof] the migration file is applied again, and c1 passes:\n' >&2
		sed 's/^/[revert-proof] /' "${WORK}/restored.out" >&2
		printf 'PASS c9 revert-proof       with the predicate gone c1 FAILED; restoring the file made it PASS again\n'
	else
		printf 'FAIL c9 revert-proof       c1 still fails after restoring the migration file:\n'
		sed 's/^/  | /' "${WORK}/restored.out" >&2
		return 1
	fi
	return 0
}

# --- main --------------------------------------------------------------------

main() {
	start_pg
	note "postgres up (${PG_CTN}, image ${PG_IMAGE})"
	apply_fixture
	note "fixture applied (roles, bridge, page-search, page-version, service-role-only)"
	seed

	check_metadata && pass c1 "version semantics" || fail c1 "version semantics"
	check_conditional_race && pass c2 "conditional update race" || fail c2 "conditional update race"
	check_append_race && pass c3 "concurrent appends" || fail c3 "concurrent appends"
	check_idempotency && pass c4 "idempotency" || fail c4 "idempotency"
	check_position && pass c5 "position and validation" || fail c5 "position and validation"
	check_idempotent_apply && pass c6 "idempotent apply" || fail c6 "idempotent apply"
	check_acl && pass c7 "acl" || fail c7 "acl"
	check_postgrest && pass c8 "postgrest u1/u4" || fail c8 "postgrest u1/u4"
	check_revert_proof && pass c9 "revert proof" || fail c9 "revert proof"

	printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
	[ "${failed}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
