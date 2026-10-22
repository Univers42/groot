#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    social-scale.sh                                                           #
#                                                                              #
#    Prove the colleague-edges trigger, the one-time backfill, the feed       #
#    counts function, and the lock order the migration takes.                  #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   models/osionos-social-scale-migration.sql writes a colleague edge when a
#   member joins a workspace, backfills the pairs that predate the trigger, and
#   answers the four feed numbers in one call. None of that is visible in the
#   catalog: a trigger that never fires, a backfill that runs twice, an edge
#   that skips the blocked pairs, a join that fails because the edge insert
#   failed — each of them leaves a schema that looks right and behaves wrong.
#   So this script runs the behaviour, not the DDL.
#
# WHAT IT RUNS
#   A throwaway grobase postgres (--rm --network none) -> 001 -> 012 -> shim
#   -> the real runner with a models directory the social-scale file is MISSING
#   from (so the fixture below is written before the trigger exists) -> the
#   fixtures -> the social-scale file applied for the FIRST time (the backfill
#   runs) -> the same file applied again (the replay) -> the behaviours ->
#   20 rounds of a join racing a replay of the file.
#
#   The behaviours, one line each:
#     b1  the trigger exists, on osionos_workspace_members, under its own name
#     b2  a third member joins a workspace of two: two edges, requester = the
#         joiner, status accepted, source colleague, no intro_message, and a
#         responded_at
#     b3  a 201-member workspace: the join writes NO edge
#     b4  a blocked pair still gets its edge, and the bridge's block-aware
#         read (bridge-social.mjs:110-116) hides it
#     b5  a failing edge insert (a temporary CHECK) leaves the join committed
#         and the warning on the log
#     b6  the backfill on the first apply inserts the expected rows, with the
#         bridge's orientation, and the replay inserts nothing
#     b7  osionos_feed_page_counts answers the four numbers
#     b8  a broken trigger is loud: an error outside the four caught SQLSTATEs
#         aborts the join
#     race  20 rounds of a join against a replay of the file: no deadlock
#
# THE RESULT
#   RESULT: <n> checks passed, <m> failed, <r> runs, <d> deadlocks (40P01),
#           <t> lock timeouts (55P03)
#   Exit 0 when every check passed and no round deadlocked, 1 otherwise.
#
# Caveat: the file's own lock_timeout is 5 s, so a writer that holds a lock
#   for longer than that makes the REPLAY abort with 55P03 — a failed boot
#   until the next one, not a deadlock. The timeout is reported apart from the
#   deadlocks, because a timeout is a budget and a deadlock is a bug.
#
# Caveat: one round is one attempt at the race. A deadlock that needs a
#   particular interleaving may not show up in 20 rounds; the round count is
#   the evidence, not a proof of absence.
#
# ISOLATION
#   A throwaway container with a $$ name and a cleanup trap. The live
#   mini-baas / osionos containers are never read, written or stopped.
#
# Ponytail: the container skeleton is mirrored from scripts/verify/account-lock-race.sh
#   (P1-1 reserved it for P1-2s to extend); no shared helper exists yet, so
#   this file copies the 30 lines it needs instead of editing that one.
#
# Usage:  [GROBASE_PG_IMAGE=…] [MODELS_DIR=…] [ROUNDS=20] sh scripts/verify/social-scale.sh
# Exit:  0 every check passed · 1 a check or a deadlock failed · 2 docker missing
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="${REPO}/scripts/verify"
RUNNER="${REPO}/scripts/apply-models-migrations.sh"
GROBASE_INIT="${REPO}/apps/grobase/scripts/migrations/postgresql/001_initial_schema.sql"
GROBASE_REALTIME="${REPO}/apps/grobase/scripts/migrations/postgresql/012_realtime_triggers_all_tables.sql"
MODELS_DIR="${MODELS_DIR:-${REPO}/models}"
SOCIAL_FILE="${MODELS_DIR}/osionos-social-scale-migration.sql"
IMAGE="${GROBASE_PG_IMAGE:-ghcr.io/univers42/grobase-postgres:latest}"
READY_TIMEOUT=60
PG_USER=postgres
PG_DB=postgres
ROUNDS="${ROUNDS:-20}"

CTN=''
WORK=''
passed=0
failed=0
deadlocks=0
timeouts=0

# The fixtures. The ids are fixed so a failure is reproducible.
WS3='0a5a0000-0000-4000-8000-000000000001'
A='0a5a0000-0000-4000-8000-000000000101'
B='0a5a0000-0000-4000-8000-000000000102'
C='0a5a0000-0000-4000-8000-000000000103'
WSTIE='0a5a0000-0000-4000-8000-000000000002'
D='0a5a0000-0000-4000-8000-000000000201'
E='0a5a0000-0000-4000-8000-000000000202'
WS2='0a5a0000-0000-4000-8000-000000000003'
F='0a5a0000-0000-4000-8000-000000000301'
G='0a5a0000-0000-4000-8000-000000000302'
WS1='0a5a0000-0000-4000-8000-000000000004'
H='0a5a0000-0000-4000-8000-000000000401'
I='0a5a0000-0000-4000-8000-000000000402'
WS201='0a5a0000-0000-4000-8000-000000000005'
LOUD='0a5a0000-0000-4000-8000-000000000403'
OWNER='0a5a0000-0000-4000-8000-0000000000ff'

note() { printf '[social-scale] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)) && printf 'PASS %s %s\n' "$1" "${2:-}"; }
fail() { failed=$((failed + 1)) && printf 'FAIL %s %s\n' "$1" "${2:-}"; }
finish() {
	printf 'RESULT: %s checks passed, %s failed, %s runs, %s deadlocks (40P01), %s lock timeouts (55P03)\n' \
		"${passed}" "${failed}" "${ROUNDS}" "${deadlocks}" "${timeouts}"
	exit "$1"
}
cleanup() {
	if [ -n "${CTN}" ]; then
		docker rm -f "${CTN}" >/dev/null 2>&1 || true
	fi
	CTN=''
	rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

psql_stdin() {
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q
}
# One value, unaligned: the first column of the first row.
scalar() {
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q -At -c "$1"
}
apply() {
	if psql_stdin <"$1" >"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}
wait_ready() {
	i=0
	while [ "${i}" -lt "${READY_TIMEOUT}" ]; do
		if docker exec "${CTN}" pg_isready -h 127.0.0.1 -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}
# check_eq <id> <label> <expected> <actual>
check_eq() {
	if [ "$3" = "$4" ]; then
		pass "$1" "$2 = $3"
	else
		fail "$1" "$2 = ${4:-nothing} — expected $3"
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# The fixture: written BEFORE the trigger exists, so the backfill is the only
# thing that can pair these members.
# ─────────────────────────────────────────────────────────────────────────────
fixtures() {
	scalar "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES
		('${WS3}', '${OWNER}', 'ws3', 'p05-ws3'),
		('${WSTIE}', '${OWNER}', 'wstie', 'p05-wstie'),
		('${WS2}', '${OWNER}', 'ws2', 'p05-ws2'),
		('${WS1}', '${OWNER}', 'ws1', 'p05-ws1'),
		('${WS201}', '${OWNER}', 'ws201', 'p05-ws201')
		ON CONFLICT (id) DO NOTHING" >/dev/null
	# ws3: A joins first, B second (a day later), C joins after the trigger.
	scalar "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, created_at) VALUES
		('${WS3}', '${A}', 'owner', '2026-01-01 00:00:00+00'),
		('${WS3}', '${B}', 'editor', '2026-01-02 00:00:00+00')" >/dev/null
	# wstie: D and E join at the same instant — the tie is broken by the greater
	# user_id, so E is the requester.
	scalar "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, created_at) VALUES
		('${WSTIE}', '${D}', 'owner', '2026-01-03 00:00:00+00'),
		('${WSTIE}', '${E}', 'editor', '2026-01-03 00:00:00+00')" >/dev/null
	# ws2: F and G, for the blocked pair.
	scalar "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, created_at) VALUES
		('${WS2}', '${F}', 'owner', '2026-01-04 00:00:00+00'),
		('${WS2}', '${G}', 'editor', '2026-01-05 00:00:00+00')" >/dev/null
	# ws1: H alone — the join of I is the one whose edge insert must fail.
	scalar "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, created_at) VALUES
		('${WS1}', '${H}', 'owner', '2026-01-06 00:00:00+00')" >/dev/null
	# ws201: 201 members. The backfill skips it (more than 200) and the trigger
	# skips it too, so it must hold no edge at all.
	scalar "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role)
		SELECT '${WS201}', gen_random_uuid(), 'viewer' FROM generate_series(1, 201)" >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# b1 — the trigger, by name and by table
# ─────────────────────────────────────────────────────────────────────────────
check_trigger() {
	n="$(scalar "SELECT count(*) FROM pg_trigger
		WHERE tgrelid = 'public.osionos_workspace_members'::regclass
		  AND tgname = 'osionos_workspace_members_colleague_edges_trg'
		  AND NOT tgisinternal")"
	check_eq b1 trigger_count 1 "${n}"
}

# ─────────────────────────────────────────────────────────────────────────────
# b2 — the third member joins a workspace of two: two edges, the bridge's shape
# ─────────────────────────────────────────────────────────────────────────────
check_join() {
	scalar "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, created_at)
		VALUES ('${WS3}', '${C}', 'viewer', '2026-01-07 00:00:00+00')" >/dev/null
	n="$(scalar "SELECT count(*) FROM public.osionos_connections
		WHERE requester_id = '${C}' AND addressee_id IN ('${A}', '${B}')")"
	check_eq b2 join_edges 2 "${n}"
	n="$(scalar "SELECT count(*) FROM public.osionos_connections
		WHERE requester_id = '${C}' AND status = 'accepted' AND source = 'colleague'
		  AND intro_message IS NULL AND responded_at IS NOT NULL
		  AND addressee_id IN ('${A}', '${B}')")"
	check_eq b2 join_edges_shape 2 "${n}"
	# No edge to self, ever.
	n="$(scalar "SELECT count(*) FROM public.osionos_connections WHERE requester_id = addressee_id")"
	check_eq b2 no_self_edge 0 "${n}"
}

# ─────────────────────────────────────────────────────────────────────────────
# b3 — a 201-member workspace: the join writes no edge
# ─────────────────────────────────────────────────────────────────────────────
check_large_workspace() {
	before="$(scalar "SELECT count(*) FROM public.osionos_connections WHERE requester_id IN
		(SELECT user_id FROM public.osionos_workspace_members WHERE workspace_id = '${WS201}')
		OR addressee_id IN
		(SELECT user_id FROM public.osionos_workspace_members WHERE workspace_id = '${WS201}')")"
	scalar "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role)
		VALUES ('${WS201}', gen_random_uuid(), 'viewer')" >/dev/null
	after="$(scalar "SELECT count(*) FROM public.osionos_connections WHERE requester_id IN
		(SELECT user_id FROM public.osionos_workspace_members WHERE workspace_id = '${WS201}')
		OR addressee_id IN
		(SELECT user_id FROM public.osionos_workspace_members WHERE workspace_id = '${WS201}')")"
	check_eq b3 large_workspace_edges 0 "${after}"
	check_eq b3 large_workspace_unchanged "${before}" "${after}"
}

# ─────────────────────────────────────────────────────────────────────────────
# b4 — a blocked pair gets its edge; the bridge's read hides it
# ─────────────────────────────────────────────────────────────────────────────
check_blocked_pair() {
	scalar "INSERT INTO public.osionos_user_blocks (blocker_id, blocked_id, reason)
		VALUES ('${F}', '${G}', 'p05 fixture')" >/dev/null
	n="$(scalar "SELECT count(*) FROM public.osionos_connections
		WHERE (requester_id = '${F}' AND addressee_id = '${G}')
		   OR (requester_id = '${G}' AND addressee_id = '${F}')")"
	check_eq b4 blocked_pair_has_edge 1 "${n}"
	# The bridge's read: the caller's edges minus the peers a block hides
	# (bridge-social.mjs:110-116, the symmetric block of bridge-social-core.mjs).
	n="$(scalar "SELECT count(*) FROM public.osionos_connections c
		WHERE (c.requester_id = '${F}' OR c.addressee_id = '${F}')
		  AND NOT EXISTS (
			SELECT 1 FROM public.osionos_user_blocks b
			 WHERE (b.blocker_id = '${F}' AND b.blocked_id = CASE WHEN c.requester_id = '${F}'
				THEN c.addressee_id ELSE c.requester_id END)
			    OR (b.blocked_id = '${F}' AND b.blocker_id = CASE WHEN c.requester_id = '${F}'
				THEN c.addressee_id ELSE c.requester_id END))")"
	check_eq b4 blocked_pair_hidden_at_read 0 "${n}"
}

# ─────────────────────────────────────────────────────────────────────────────
# b5 — a failing edge insert leaves the join committed, with a warning
# ─────────────────────────────────────────────────────────────────────────────
check_failing_insert() {
	scalar "ALTER TABLE public.osionos_connections
		ADD CONSTRAINT p05_tmp_no_colleague CHECK (source <> 'colleague') NOT VALID" >/dev/null
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		>"${WORK}/warn.log" 2>&1 <<SQL
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role)
VALUES ('${WS1}', '${I}', 'viewer');
SQL
	rc=$?
	scalar "ALTER TABLE public.osionos_connections DROP CONSTRAINT IF EXISTS p05_tmp_no_colleague" >/dev/null
	check_eq b5 join_committed 0 "${rc}"
	n="$(scalar "SELECT count(*) FROM public.osionos_workspace_members WHERE workspace_id = '${WS1}' AND user_id = '${I}'")"
	check_eq b5 member_joined 1 "${n}"
	n="$(scalar "SELECT count(*) FROM public.osionos_connections WHERE requester_id = '${I}'")"
	check_eq b5 no_edge_written 0 "${n}"
	if grep -q "WARNING" "${WORK}/warn.log" && grep -q "${WS1}" "${WORK}/warn.log"; then
		pass b5 warning_named_the_workspace
	else
		fail b5 warning_named_the_workspace "no warning naming ${WS1} on the log"
		sed 's/^/  | /' "${WORK}/warn.log" >&2
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# b6 — the backfill: the first apply pairs, the replay pairs nothing
# ─────────────────────────────────────────────────────────────────────────────
check_backfill() {
	# The first apply: the trigger is created and the backfill runs. Three
	# pairs are missing — (A,B), (D,E) and (F,G). The 201-member workspace is
	# skipped, and ws1 holds a single member.
	if docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		>"${WORK}/first-apply.log" 2>&1 <"${SOCIAL_FILE}"
	then
		rc=0
	else
		rc=$?
	fi
	check_eq b6 first_apply_ok 0 "${rc}"
	if [ "${rc}" -ne 0 ]; then
		sed 's/^/  | /' "${WORK}/first-apply.log" >&2
	fi
	if grep -q 'backfill inserted 3 colleague edge' "${WORK}/first-apply.log"; then
		pass b6 "backfill_count = 3"
	else
		fail b6 backfill_count "$(grep -o 'backfill inserted [0-9]* colleague edge(s)' "${WORK}/first-apply.log" || echo 'no notice')"
	fi
	# The orientation: the requester is the member who joined later, and a tie
	# is broken by the greater user_id.
	n="$(scalar "SELECT count(*) FROM public.osionos_connections
		WHERE (requester_id = '${B}' AND addressee_id = '${A}')
		   OR (requester_id = '${E}' AND addressee_id = '${D}')
		   OR (requester_id = '${G}' AND addressee_id = '${F}')")"
	check_eq b6 backfill_orientation 3 "${n}"
	# The replay: the guard sees the trigger and skips the backfill.
	before="$(scalar "SELECT count(*) FROM public.osionos_connections")"
	if docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		>"${WORK}/replay.log" 2>&1 <"${SOCIAL_FILE}"
	then
		rc=0
	else
		rc=$?
	fi
	after="$(scalar "SELECT count(*) FROM public.osionos_connections")"
	if [ "${rc}" -eq 0 ]; then
		pass b6 replay_ok = 0
	else
		fail b6 "replay_ok — the replay failed: $(grep -m1 -E 'ERROR|FATAL' "${WORK}/replay.log" | cut -c1-140)"
		sed 's/^/  | /' "${WORK}/replay.log" >&2
	fi
	check_eq b6 replay_inserted_nothing "${before}" "${after}"
	if grep -q 'backfill inserted' "${WORK}/replay.log"; then
		fail b6 replay_ran_no_backfill "the backfill ran again on the replay"
	else
		pass b6 replay_ran_no_backfill
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# b7 — the feed numbers, in one call
# ─────────────────────────────────────────────────────────────────────────────
check_feed_counts() {
	page='30bc93c6-e5fb-81fc-8947-80d053feff40'
	viewer='0a5a0000-0000-4000-8000-000000000501'
	other='0a5a0000-0000-4000-8000-000000000502'
	scalar "INSERT INTO public.osionos_feed_likes (page_id, user_id) VALUES
		('${page}', '${viewer}'), ('${page}', '${other}')" >/dev/null
	scalar "INSERT INTO public.osionos_feed_comments (page_id, author_id, content)
		VALUES ('${page}', '${viewer}', 'one')" >/dev/null
	scalar "INSERT INTO public.osionos_feed_shares (page_id, user_id, target) VALUES
		('${page}', '${viewer}', 'link'), ('${page}', '${other}', 'profile'),
		('${page}', '${viewer}', 'dm')" >/dev/null
	n="$(scalar "SELECT likes || '|' || liked_by_viewer || '|' || comments || '|' || shares
		FROM public.osionos_feed_page_counts('${page}', '${viewer}')")"
	check_eq b7 counts_for_the_viewer '2|true|1|3' "${n}"
	n="$(scalar "SELECT likes || '|' || liked_by_viewer || '|' || comments || '|' || shares
		FROM public.osionos_feed_page_counts('${page}', '${other}')")"
	check_eq b7 counts_for_another_user '2|true|1|3' "${n}"
	n="$(scalar "SELECT likes || '|' || liked_by_viewer || '|' || comments || '|' || shares
		FROM public.osionos_feed_page_counts('${page}', '0a5a0000-0000-4000-8000-0000000005ff')")"
	check_eq b7 counts_for_a_stranger '2|false|1|3' "${n}"
	# The function is service_role's alone.
	n="$(scalar "SELECT count(*) FROM pg_proc p
		WHERE p.oid = to_regprocedure('public.osionos_feed_page_counts(uuid, uuid)')
		  AND has_function_privilege('service_role', p.oid, 'EXECUTE')
		  AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
		  AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')")"
	check_eq b7 service_role_only 1 "${n}"
}

# ─────────────────────────────────────────────────────────────────────────────
# b8 — a broken trigger must be loud: an error outside the four caught
#      SQLSTATEs aborts the join instead of being swallowed
# ─────────────────────────────────────────────────────────────────────────────
check_loud_trigger() {
	# The trigger is SECURITY INVOKER, so it runs with the joiner's rights.
	# service_role loses the INSERT on osionos_connections for the length of
	# the transaction, so the trigger's insert fails with 42501 — which is NOT
	# one of the four SQLSTATEs the exception block catches. The join must
	# therefore fail, and the transaction rolls back (which restores the
	# grant). An exception block that caught everything would swallow the
	# failure and the join would commit without its edges.
	if docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		>"${WORK}/loud.log" 2>&1 <<SQL
\set VERBOSITY sqlstate
BEGIN;
REVOKE INSERT ON public.osionos_connections FROM service_role;
SET LOCAL ROLE service_role;
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role)
VALUES ('${WS1}', '${LOUD}', 'viewer');
COMMIT;
SQL
	then
		rc=0
	else
		rc=$?
	fi
	if [ "${rc}" -ne 0 ]; then
		pass b8 loud_trigger_aborts_the_join
	else
		fail b8 loud_trigger_aborts_the_join "the join committed although the edge insert failed"
	fi
	n="$(scalar "SELECT count(*) FROM public.osionos_workspace_members WHERE workspace_id = '${WS1}' AND user_id = '${LOUD}'")"
	check_eq b8 no_member_row 0 "${n}"
	if grep -q '42501' "${WORK}/loud.log"; then
		pass b8 sqlstate_42501
	else
		fail b8 sqlstate_42501 "the log does not name 42501"
		sed 's/^/  | /' "${WORK}/loud.log" >&2
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# the race: a join against a replay of the file
# ─────────────────────────────────────────────────────────────────────────────
round() {
	n="$1"
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		<"${SOCIAL_FILE}" >"${WORK}/replay-${n}.out" 2>"${WORK}/replay-${n}.err" &
	replay_pid=$!
	docker exec -i "${CTN}" psql -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -q \
		>"${WORK}/join-${n}.out" 2>"${WORK}/join-${n}.err" <<SQL &
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role)
VALUES ('${WS1}', gen_random_uuid(), 'viewer');
SQL
	join_pid=$!
	wait "${replay_pid}" || true
	wait "${join_pid}" || true
	for f in "${WORK}/replay-${n}.err" "${WORK}/join-${n}.err"; do
		if grep -q '40P01\|deadlock detected' "${f}" 2>/dev/null; then
			deadlocks=$((deadlocks + 1))
			note "round ${n}: DEADLOCK in $(basename "${f}")"
			sed 's/^/  | /' "${f}" >&2
		fi
		if grep -q '55P03\|lock timeout' "${f}" 2>/dev/null; then
			timeouts=$((timeouts + 1))
			note "round ${n}: LOCK TIMEOUT in $(basename "${f}")"
			sed 's/^/  | /' "${f}" >&2
		fi
	done
}

main() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"
		exit 2
	}
	[ -f "${RUNNER}" ] || {
		note "no ${RUNNER}"
		exit 2
	}
	[ -f "${SOCIAL_FILE}" ] || {
		note "no ${SOCIAL_FILE}"
		exit 2
	}
	docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
		note "the image ${IMAGE} is not here — pull it first"
		exit 2
	}
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/social-scale.XXXXXX")"
	CTN="social-scale-$$"
	docker run --rm --network none --name "${CTN}" -e POSTGRES_HOST_AUTH_METHOD=trust \
		-d "${IMAGE}" >/dev/null 2>&1 || {
		note "${IMAGE} did not start"
		exit 2
	}
	wait_ready || {
		note "pg_isready never answered in ${READY_TIMEOUT}s"
		exit 2
	}
	apply "${FIX}/models-grants/roles.sql" || exit 2
	grep -v '^#' "${GROBASE_INIT}" >"${WORK}/001.sql" || exit 2
	apply "${WORK}/001.sql" || exit 2
	grep -v '^#' "${GROBASE_REALTIME}" >"${WORK}/012.sql" || exit 2
	apply "${WORK}/012.sql" || exit 2
	apply "${FIX}/models-grants/shim.sql" || exit 2
	# The base schema, WITHOUT the social-scale file: the fixtures below must be
	# written before the trigger exists, or the backfill would have nothing to
	# do.
	cp -r "${MODELS_DIR}" "${WORK}/models-base"
	rm -f "${WORK}/models-base/osionos-social-scale-migration.sql"
	PG_CONTAINER="${CTN}" MODELS_DIR="${WORK}/models-base" sh "${RUNNER}" >"${WORK}/runner.log" 2>&1 || {
		note "the runner failed"
		sed 's/^/  | /' "${WORK}/runner.log" >&2
		exit 2
	}
	fixtures || exit 2
	check_backfill
	check_trigger
	check_join
	check_large_workspace
	check_blocked_pair
	check_failing_insert
	check_loud_trigger
	check_feed_counts
	i=0
	while [ "${i}" -lt "${ROUNDS}" ]; do
		i=$((i + 1))
		round "${i}"
	done
	if [ "${deadlocks}" -ne 0 ]; then
		failed=$((failed + 1))
	fi
	[ "${failed}" -eq 0 ] || finish 1
	finish 0
}

main "$@"
