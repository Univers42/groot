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
#
# The checks live in scripts/verify/page-version/ and are SOURCED below, not
# inlined. The linter reads one file at a time, so it cannot see that the page
# ids and the secret set here are used by the check files, nor that the
# helpers here are called by them: it calls them unused, unreachable or
# unfollowable. Those three codes are off in this file for that reason alone.
# shellcheck disable=SC2034,SC2317,SC2329,SC1091
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${REPO}/scripts/verify"
MODELS="${REPO}/models"
FIX="${DIR}/models-grants"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
PGRST_IMAGE="${PGRST_IMAGE:-postgrest/postgrest:v12.2.3}"
PGRST_PORT="${PGRST_PORT:-33199}"
NET="ai-pv-net"
# An explicit subnet: the 172.16-172.31 default pool is full on this machine (31
# other networks live there), and this script must not touch any of them.
PV_SUBNET="${PV_SUBNET:-10.88.7.0/24}"
PG_CTN="ai-pv-pg"
PGRST_CTN="ai-pv-pgrst"
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

# --- the checks, split by concern ---------------------------------------------

# The checks live next to this script, one file per concern; they are sourced
# here because they share the fixture, the counters and the psql helpers above.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=page-version/checks-db.sh
. "${DIR}/page-version/checks-db.sh"
# shellcheck source=page-version/checks-migration.sh
. "${DIR}/page-version/checks-migration.sh"
# shellcheck source=page-version/checks-rest.sh
. "${DIR}/page-version/checks-rest.sh"

# --- main --------------------------------------------------------------------

main() {
	start_pg
	note "postgres up (${PG_CTN}, image ${PG_IMAGE})"
	apply_fixture
	note "fixture applied (roles, bridge, page-search, page-version, service-role-only)"
	seed

	# A check prints its own PASS/FAIL lines and returns 0 when it holds; the
	# counter line below is the summary of the whole check.
	if check_metadata; then
		pass c1 "version semantics"
	else
		fail c1 "version semantics"
	fi
	if check_conditional_race; then
		pass c2 "conditional update race"
	else
		fail c2 "conditional update race"
	fi
	if check_append_race; then
		pass c3 "concurrent appends"
	else
		fail c3 "concurrent appends"
	fi
	if check_idempotency; then
		pass c4 "idempotency"
	else
		fail c4 "idempotency"
	fi
	if check_position; then
		pass c5 "position and validation"
	else
		fail c5 "position and validation"
	fi
	if check_idempotent_apply; then
		pass c6 "idempotent apply"
	else
		fail c6 "idempotent apply"
	fi
	if check_acl; then
		pass c7 "acl"
	else
		fail c7 "acl"
	fi
	if check_postgrest; then
		pass c8 "postgrest u1/u4"
	else
		fail c8 "postgrest u1/u4"
	fi
	if check_revert_proof; then
		pass c9 "revert proof"
	else
		fail c9 "revert proof"
	fi

	printf 'RESULT: %s passed, %s failed\n' "${passed}" "${failed}"
	[ "${failed}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
