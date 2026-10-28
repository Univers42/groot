#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    member-attributes.sh                                                      #
#                                                                              #
#    Prove the member attributes table                                         #
#    (models/osionos-member-attributes-migration.sql) on a throwaway database. #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES
#   a1  an attribute row inserts for a workspace member; a user with no members
#       row is refused with 23503 by the composite foreign key (C645: a guest
#       has no members row, so the FK alone keeps guests attribute-free).
#   a2  deleting the members row deletes that member's attributes and nobody
#       else's (the cascade invariant, C643: rows die with the membership).
#   a3  deleting the workspace deletes all of its attribute rows, and the other
#       workspace's rows are untouched.
#   a4  the key CHECK refuses 'Dept', '1x', 'a-b' and a 33-character key; the
#       value CHECK refuses '', ' x', 'a:b' and a 65-character value (23514).
#   a5  a second value for the same (workspace, user, key) is a primary-key
#       conflict (23505): one value per key per member, so the bridge upserts.
#   a6  anon and authenticated hold none of the four privileges on the table,
#       service_role holds all four.
#   a7  re-running the migration is a no-op: the same constraints, the same rows.
#
# ISOLATION
#   Throwaway containers only: ai-ma-pg (pgvector/pgvector:0.8.0-pg16), started
#   and removed by this script's trap alone; the live mini-baas-*, track-binocle-*,
#   ai-dev-*, ai-eval-* and ai-gpu-* containers are never read, written or
#   stopped. No port, no second container and no stack, so no network is created
#   either: every statement runs through docker exec.
#
# THE FIXTURE
#   scripts/verify/models-grants/roles.sql, then the pre-1e407614 default
#   privileges anon and authenticated used to get on every new public table —
#   without them a6 would pass for the wrong reason, because postgres grants a
#   fresh table to nobody — then models/osionos-bridge-migration.sql (the
#   workspaces and workspace_members this table's foreign key targets) and the
#   file under test.
#
# Usage:  sh scripts/verify/member-attributes.sh [--keep]
#           --keep   leave the container up afterwards
#
# Env:    PG_IMAGE   (default pgvector/pgvector:0.8.0-pg16)
#
# Exit:   0 every check passed · 1 a check failed · 2 docker is missing
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${REPO}/scripts/verify"
MODELS="${REPO}/models"
FIX="${DIR}/models-grants"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
PG_CTN="ai-ma-pg"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/member-attributes.XXXXXX")"
passed=0
failed=0

note() { printf '[member-attributes] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s %s\n' "$1" "$2"; }

teardown() {
	[ "${KEEP}" -eq 1 ] && { note "--keep: ${PG_CTN} left up"; return 0; }
	docker rm -f "${PG_CTN}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

# --- psql helpers ------------------------------------------------------------

# psql in the throwaway container; -qAt = quiet, unaligned, tuples only.
psql_q() {
	docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt
}

# q <sql> — run one statement, print its rows; its exit status is psql's.
q() {
	printf '%s\n' "$1" | psql_q
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

# state_of <sql> — the SQLSTATE the statement was refused with; empty when it was
# accepted. psql only prints the state with VERBOSITY sqlstate.
state_of() {
	err="${WORK}/state.err"
	if printf '%s\n' '\set VERBOSITY sqlstate' "$1" | psql_q >/dev/null 2>"${err}"; then
		printf ''
		return 0
	fi
	sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' "${err}" | head -1
}

# repeat <char> <n> — a key or a value long enough to be refused on length alone.
repeat() {
	i=0
	s=""
	while [ "${i}" -lt "$2" ]; do
		s="${s}$1"
		i=$((i + 1))
	done
	printf '%s' "${s}"
}

# --- fixture -----------------------------------------------------------------

start_pg() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"; exit 2
	}
	docker run -d --name "${PG_CTN}" -e POSTGRES_HOST_AUTH_METHOD=trust "${PG_IMAGE}" >/dev/null
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
	# The pre-1e407614 default privileges: anon and authenticated get everything on
	# every table created from here on. The migration's own REVOKE has to close
	# them, or a6 would pass for the wrong reason.
	printf 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;\n' |
		psql_q >/dev/null || {
		note "the default privileges failed"
		exit 1
	}
	apply "${MODELS}/osionos-bridge-migration.sql" || exit 1
	apply "${MODELS}/osionos-member-attributes-migration.sql" || exit 1
}

# W1 keeps two members through a2; W2 dies with its workspace in a3; G has no
# members row anywhere (a1's non-member); GV is W1's guest (role viewer) for a8.
W1="11111111-1111-4111-8111-111111111111"
W2="33333333-3333-4333-8333-333333333333"
M1="22222222-2222-4222-8222-222222222221"
M2="22222222-2222-4222-8222-222222222222"
M3="22222222-2222-4222-8222-222222222223"
G="22222222-2222-4222-8222-222222222224"
GV="22222222-2222-4222-8222-222222222225"

seed() {
	q "
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES
 ('${W1}', '${M1}', 'w1', 'w1-attr'),
 ('${W2}', '${M3}', 'w2', 'w2-attr');
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES
 ('${W1}', '${M1}', 'admin', ARRAY['read']),
 ('${W1}', '${M2}', 'editor', ARRAY['read']),
 ('${W2}', '${M3}', 'admin', ARRAY['read']);
INSERT INTO public.osionos_member_attributes (workspace_id, user_id, key, value, set_by) VALUES
 ('${W1}', '${M1}', 'department', 'legal', '${M1}'),
 ('${W1}', '${M2}', 'department', 'finance', '${M1}'),
 ('${W1}', '${M2}', 'clearance', '2', '${M1}'),
 ('${W2}', '${M3}', 'department', 'legal', '${M3}');
" >/dev/null || {
		note "the seed failed"
		exit 1
	}
}

# attrs_of <workspace> <user> — how many attribute rows that member carries.
attrs_of() {
	q "SELECT count(*) FROM public.osionos_member_attributes WHERE workspace_id = '$1' AND user_id = '$2'"
}

# --- the checks --------------------------------------------------------------

# a1: a member's row lands; a user with no members row is refused by the FK.
check_a1() {
	if ! q "INSERT INTO public.osionos_member_attributes (workspace_id, user_id, key, value, set_by)
	        VALUES ('${W1}', '${M1}', 'clearance', '3', '${M1}');"; then
		printf 'FAIL a1 member-insert     a member attribute row was refused\n' >&2
		return 1
	fi
	state="$(state_of "INSERT INTO public.osionos_member_attributes (workspace_id, user_id, key, value, set_by)
	        VALUES ('${W1}', '${G}', 'department', 'legal', '${M1}');")"
	if [ "${state}" != "23503" ]; then
		printf 'FAIL a1 non-member        expected 23503, got %s\n' "${state:-accepted}" >&2
		return 1
	fi
	return 0
}

# a2: the members row goes, its attributes go with it, the other member's stay.
check_a2() {
	q "DELETE FROM public.osionos_workspace_members WHERE workspace_id = '${W1}' AND user_id = '${M1}';" >/dev/null
	gone="$(attrs_of "${W1}" "${M1}")"
	kept="$(attrs_of "${W1}" "${M2}")"
	if [ "${gone}" != "0" ]; then
		printf 'FAIL a2 cascade           expected 0 rows for the removed member, got %s\n' "${gone}" >&2
		return 1
	fi
	if [ "${kept}" != "2" ]; then
		printf 'FAIL a2 sibling           expected 2 rows for the other member, got %s\n' "${kept}" >&2
		return 1
	fi
	return 0
}

# a3: the workspace goes, its attribute rows go with it, W1's stay.
check_a3() {
	q "DELETE FROM public.osionos_workspaces WHERE id = '${W2}';" >/dev/null
	gone="$(q "SELECT count(*) FROM public.osionos_member_attributes WHERE workspace_id = '${W2}'")"
	kept="$(attrs_of "${W1}" "${M2}")"
	if [ "${gone}" != "0" ]; then
		printf 'FAIL a3 workspace         expected 0 rows in the deleted workspace, got %s\n' "${gone}" >&2
		return 1
	fi
	if [ "${kept}" != "2" ]; then
		printf 'FAIL a3 other-workspace   expected 2 rows in W1, got %s\n' "${kept}" >&2
		return 1
	fi
	return 0
}

# a4: both CHECKs refuse their bad input with 23514, each on length, shape or ':'
# alone (the rest of each row is valid).
check_a4() {
	key33="$(repeat a 33)"
	val65="$(repeat a 65)"
	for bad_key in "'Dept'" "'1x'" "'a-b'" "'${key33}'"; do
		state="$(state_of "INSERT INTO public.osionos_member_attributes (workspace_id, user_id, key, value, set_by)
		        VALUES ('${W1}', '${M2}', ${bad_key}, 'x', '${M1}');")"
		if [ "${state}" != "23514" ]; then
			printf 'FAIL a4 key %s expected 23514, got %s\n' "${bad_key}" "${state:-accepted}" >&2
			return 1
		fi
	done
	for bad_value in "''" "' x'" "'a:b'" "'${val65}'"; do
		# A key M2 does not carry, so no primary-key conflict can be what refuses
		# the row: the value CHECK is the only refuser here.
		state="$(state_of "INSERT INTO public.osionos_member_attributes (workspace_id, user_id, key, value, set_by)
		        VALUES ('${W1}', '${M2}', 'level', ${bad_value}, '${M1}');")"
		if [ "${state}" != "23514" ]; then
			printf 'FAIL a4 value %s expected 23514, got %s\n' "${bad_value}" "${state:-accepted}" >&2
			return 1
		fi
	done
	return 0
}

# a5: one value per key per member — the PK, not a unique index, is what the
# bridge's upsert rides on.
check_a5() {
	state="$(state_of "INSERT INTO public.osionos_member_attributes (workspace_id, user_id, key, value, set_by)
	        VALUES ('${W1}', '${M2}', 'department', 'other', '${M1}');")"
	if [ "${state}" != "23505" ]; then
		printf 'FAIL a5 second-value      expected 23505, got %s\n' "${state:-accepted}" >&2
		return 1
	fi
	return 0
}

# a6: the whole security posture in four privileges per role.
check_a6() {
	for role in anon authenticated; do
		n="$(q "SELECT count(*) FROM (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) v(p)
		        WHERE has_table_privilege('${role}', 'public.osionos_member_attributes', v.p);")"
		if [ "${n}" != "0" ]; then
			printf 'FAIL a6 %s holds %s of the four privileges\n' "${role}" "${n}" >&2
			return 1
		fi
	done
	n="$(q "SELECT count(*) FROM (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) v(p)
	        WHERE has_table_privilege('service_role', 'public.osionos_member_attributes', v.p);")"
	if [ "${n}" != "4" ]; then
		printf 'FAIL a6 service_role      expected all four privileges, got %s\n' "${n}" >&2
		return 1
	fi
	return 0
}

# The shape the replay must leave untouched: every constraint on the table, and
# every row, each ordered so a reorder is a change.
constraints_of() {
	q "SELECT coalesce(string_agg(conname || ': ' || pg_get_constraintdef(oid), E'\n' ORDER BY conname), '')
	     FROM pg_constraint WHERE conrelid = 'public.osionos_member_attributes'::regclass"
}

rows_of() {
	q "SELECT coalesce(string_agg(workspace_id || '|' || user_id || '|' || key || '|' || value || '|' || set_by,
	                             E'\n' ORDER BY workspace_id, user_id, key), '')
	     FROM public.osionos_member_attributes"
}

# a7: replay the file: IF NOT EXISTS everywhere, so nothing is recreated and no
# row moves.
check_a7() {
	before_c="$(constraints_of)"
	before_r="$(rows_of)"
	[ -n "${before_r}" ] || {
		printf 'FAIL a7 pre-state         no rows to replay over\n' >&2
		return 1
	}
	if ! apply "${MODELS}/osionos-member-attributes-migration.sql"; then
		printf 'FAIL a7 replay            the second apply was rejected\n' >&2
		return 1
	fi
	after_c="$(constraints_of)"
	after_r="$(rows_of)"
	if [ "${after_c}" != "${before_c}" ]; then
		printf 'FAIL a7 constraints       the replay changed them\n%s\n' "${after_c}" >&2
		return 1
	fi
	if [ "${after_r}" != "${before_r}" ]; then
		printf 'FAIL a7 rows             the replay changed them\n' >&2
		return 1
	fi
	return 0
}

# a8 (C645): a guest is a members row with role viewer, so the FK admits it; the
# trigger refuses its attribute row (23514). A role change that is not a demotion
# keeps the rows; a demotion to viewer deletes them.
check_a8() {
	q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions)
	   VALUES ('${W1}', '${GV}', 'viewer', ARRAY['read']);" >/dev/null
	state="$(state_of "INSERT INTO public.osionos_member_attributes (workspace_id, user_id, key, value, set_by)
	        VALUES ('${W1}', '${GV}', 'department', 'legal', '${M2}');")"
	if [ "${state}" != "23514" ]; then
		printf 'FAIL a8 guest-insert      expected 23514, got %s\n' "${state:-accepted}" >&2
		return 1
	fi
	q "UPDATE public.osionos_workspace_members SET role = 'admin'
	    WHERE workspace_id = '${W1}' AND user_id = '${M2}';" >/dev/null
	kept="$(attrs_of "${W1}" "${M2}")"
	if [ "${kept}" != "2" ]; then
		printf 'FAIL a8 promotion         expected 2 rows kept, got %s\n' "${kept}" >&2
		return 1
	fi
	q "UPDATE public.osionos_workspace_members SET role = 'viewer'
	    WHERE workspace_id = '${W1}' AND user_id = '${M2}';" >/dev/null
	gone="$(attrs_of "${W1}" "${M2}")"
	if [ "${gone}" != "0" ]; then
		printf 'FAIL a8 demotion          expected 0 rows after demotion to viewer, got %s\n' "${gone}" >&2
		return 1
	fi
	return 0
}

# --- main --------------------------------------------------------------------

main() {
	start_pg
	note "postgres up (${PG_CTN}, image ${PG_IMAGE})"
	apply_fixture
	note "fixture applied (roles, default privileges, bridge, member-attributes)"
	seed

	if check_a1; then pass a1 "a member's row lands, a non-member is refused 23503"; else fail a1 "member row / non-member refusal"; fi
	if check_a2; then pass a2 "the members row's attributes die with it, the sibling's stay"; else fail a2 "cascade on member removal"; fi
	if check_a3; then pass a3 "the workspace's attribute rows die with it"; else fail a3 "cascade on workspace delete"; fi
	if check_a4; then pass a4 "key and value CHECKs refuse their bad input (23514)"; else fail a4 "key / value CHECKs"; fi
	if check_a5; then pass a5 "a second value for the same key is a PK conflict (23505)"; else fail a5 "one value per key per member"; fi
	if check_a6; then pass a6 "anon and authenticated hold nothing, service_role holds all four"; else fail a6 "privileges"; fi
	if check_a7; then pass a7 "the replay changes no constraint and no row"; else fail a7 "idempotent apply"; fi
	if check_a8; then pass a8 "a guest is refused 23514, a demotion to viewer clears the rows"; else fail a8 "guests carry no attributes"; fi

	printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
	[ "${failed}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
