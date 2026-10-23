#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    ai-builders.sh                                                            #
#                                                                              #
#    Prove the builders migration (P6 C155): ai_plan_items closed to the public #
#    roles, the `partial` status, replayable.                                  #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES  (models/osionos-ai-builders-migration.sql)
#   a  the migration applies twice without error (idempotent)
#   b  anon and authenticated cannot read ai_plan_items (C43)
#   c  an ai_approvals row can be set to 'partial'
#   d  deleting the approval deletes its items
#   e  a second live approval with the same (run_id, tool, args_sha256) is
#      refused while one is 'partial'
#
# ISOLATION
#   One throwaway container: ai-builders-pg, --network none, no port, no volume.
#   Removed on every exit path.
#
# Usage:  [BUILDERS_MIGRATION=<file>] sh scripts/verify/ai-builders.sh
# Exit:   0 every check passed · 1 a check, the fixture or the image failed
#
# shellcheck disable=SC2317,SC2329
# The functions are reached through the loop in main() and the trap.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MODELS="${REPO}/models"
STANDIN="${REPO}/infrastructure/docker/osionos/ai-db-init/00-standin.sql"
MIG="${BUILDERS_MIGRATION:-${MODELS}/osionos-ai-builders-migration.sql}"
CTN="ai-builders-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-builders.XXXXXX")"
passed=0
failed=0
DETAIL=""

WS=11111111-1111-1111-1111-111111111111
USR=33333333-3333-3333-3333-333333333333
CONV=55555555-5555-5555-5555-555555555555
RUN=66666666-6666-6666-6666-666666666666
AP1=77777777-7777-7777-7777-777777777771
AP2=77777777-7777-7777-7777-777777777772

note() { printf '[ai-builders] %s\n' "$*" >&2; }
pass() { passed=$((passed + 1)); printf 'PASS: %s %s\n' "$1" "$2"; }
fail() { failed=$((failed + 1)); printf 'FAIL: %s %s\n' "$1" "$2"; }

teardown() {
	docker rm -f "${CTN}" >/dev/null 2>&1 || true
	rm -rf "${WORK}"
}
trap teardown EXIT INT TERM

psql_q() { docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt; }
run_sql() { printf '%s\n' "$1" | psql_q >"${WORK}/sql.out" 2>"${WORK}/sql.err"; }
q() { printf '%s\n' "$1" | psql_q 2>/dev/null || true; }

apply_file() {
	if docker exec -i "${CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
		<"$1" >"${WORK}/apply.log" 2>&1; then
		return 0
	fi
	note "psql rejected $(basename "$1")"
	sed 's/^/  | /' "${WORK}/apply.log" >&2
	return 1
}

start_pg() {
	command -v docker >/dev/null 2>&1 || {
		note "docker is required"
		exit 2
	}
	docker image inspect "${PG_IMAGE}" >/dev/null 2>&1 || docker pull "${PG_IMAGE}" >/dev/null 2>&1 || {
		printf 'FAIL: image %s\n' "${PG_IMAGE}"
		exit 1
	}
	docker run -d --name "${CTN}" --network none -e POSTGRES_HOST_AUTH_METHOD=trust \
		"${PG_IMAGE}" >/dev/null || {
		note "the container did not start"
		exit 1
	}
	i=0
	while [ "${i}" -lt 60 ]; do
		docker exec "${CTN}" pg_isready -U postgres -d postgres >/dev/null 2>&1 && return 0
		i=$((i + 1))
		sleep 1
	done
	note "postgres never became ready"
	exit 1
}

# refused: succeeds only when postgres REFUSES the statement.
refused() {
	if run_sql "$1"; then
		DETAIL="accepted: $1"
		return 1
	fi
	return 0
}

approval_sql() { # id, status
	printf "INSERT INTO public.ai_approvals (id, run_id, conversation_id, owner_id, workspace_id, tool, args, args_sha256, status, expires_at) VALUES ('%s', '%s', '%s', '%s', '%s', 'build_plan', '{}', 'sha-1', '%s', now() + interval '1 day');" "$1" "${RUN}" "${CONV}" "${USR}" "${WS}" "$2"
}

check_a() {
	apply_file "${MIG}" || return 1
	n="$(q "SELECT count(*) FROM pg_class WHERE relname = 'ai_plan_items' AND relkind = 'r';")"
	[ "${n}" = "1" ] && return 0
	DETAIL="ai_plan_items tables=${n}, expected 1"
	return 1
}

check_b() {
	for role in anon authenticated; do
		for stmt in "SELECT 1 FROM public.ai_plan_items" \
			"INSERT INTO public.ai_plan_items (approval_id, item_key, kind, position) VALUES ('${AP1}', 'k', 'page', 0)"; do
			refused "SET ROLE ${role}; ${stmt};" || {
				DETAIL="${role} was not refused: ${stmt}"
				return 1
			}
		done
	done
	return 0
}

check_c() {
	run_sql "$(approval_sql "${AP1}" pending)
UPDATE public.ai_approvals SET status = 'partial' WHERE id = '${AP1}';" && return 0
	DETAIL="partial refused: $(head -1 "${WORK}/sql.err")"
	return 1
}

check_d() {
	run_sql "INSERT INTO public.ai_plan_items (approval_id, item_key, kind, position) VALUES ('${AP1}', 'k1', 'page', 0), ('${AP1}', 'k2', 'database', 1);" || {
		DETAIL="items refused: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	run_sql "DELETE FROM public.ai_approvals WHERE id = '${AP1}';" || return 1
	left="$(q "SELECT count(*) FROM public.ai_plan_items;")"
	[ "${left}" = "0" ] && return 0
	DETAIL="${left} items left after the approval was deleted, expected 0"
	return 1
}

check_e() {
	run_sql "$(approval_sql "${AP1}" partial)" || {
		DETAIL="seed failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	refused "$(approval_sql "${AP2}" pending)" || {
		DETAIL="a second live approval was accepted while one is partial"
		return 1
	}
	return 0
}

main() {
	start_pg
	note "postgres up in ${CTN}; migration ${MIG}"
	apply_file "${STANDIN}" || exit 1
	apply_file "${MODELS}/osionos-ai-migration.sql" || exit 1
	apply_file "${MIG}" || exit 1
	run_sql "INSERT INTO public.ai_conversations (id, owner_id, workspace_id) VALUES ('${CONV}', '${USR}', '${WS}');
INSERT INTO public.ai_runs (id, conversation_id, owner_id, status, model) VALUES ('${RUN}', '${CONV}', '${USR}', 'succeeded', 'm');" || {
		note "fixture failed: $(head -1 "${WORK}/sql.err")"
		exit 1
	}
	for fn in check_a check_b check_c check_d check_e; do
		DETAIL=""
		if "${fn}"; then
			pass "${fn}" "ok"
		else
			fail "${fn}" "${DETAIL:-failed}"
		fi
	done
	printf 'PASS %s / FAIL %s\n' "${passed}" "${failed}"
	[ "${failed}" -eq 0 ] || exit 1
	exit 0
}

main "$@"
