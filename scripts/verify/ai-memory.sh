#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    ai-memory.sh                                                              #
#                                                                              #
#    Prove the user-memories migration (P5d-1): closed to the public roles,    #
#    append-only audit, body cap, erasure through ai_erase_user.               #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES  (models/osionos-ai-user-memory-migration.sql)
#   a  anon and authenticated can neither select nor insert, on both tables (C43)
#   b  an ai_memory_audit row cannot be updated or deleted (C40)
#   c  the body CHECK refuses 0 and 301 characters and accepts 300 (C47)
#   d  ai_erase_user removes the user's memories and audit rows, keeps another's
#   e  ai_runs.memory_pins exists, and the migration replays
#   f  the file sorts after osionos-ai-migration.sql, which creates ai_runs: the
#      models runner applies osionos-ai-*.sql in its alphabetical pass, so a
#      name that sorts first fails on a fresh database
#
# ISOLATION
#   One throwaway container: ai-memory-pg, --network none, no port, no volume.
#   Removed on every exit path.
#
# Usage:  [MEMORY_MIGRATION=<file>] sh scripts/verify/ai-memory.sh
# Exit:   0 every check passed · 1 a check, the fixture or the image failed
#
# shellcheck disable=SC2317,SC2329
# The functions are reached through the loop in main() and the trap.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MODELS="${REPO}/models"
MEM="${MEMORY_MIGRATION:-${MODELS}/osionos-ai-user-memory-migration.sql}"
CTN="ai-memory-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-memory.XXXXXX")"
passed=0
failed=0
DETAIL=""

WS=11111111-1111-1111-1111-111111111111
USR=33333333-3333-3333-3333-333333333333
OTHER=55555555-5555-5555-5555-555555555555
M1=44444444-4444-4444-4444-444444444441
M2=44444444-4444-4444-4444-444444444442
M3=44444444-4444-4444-4444-444444444443

note() { printf '[ai-memory] %s\n' "$*" >&2; }
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

# refused — runs the statement and succeeds only when postgres REFUSES it; the
# reason is kept in DETAIL when it does not.
refused() {
	if run_sql "$1"; then
		DETAIL="accepted: $1"
		return 1
	fi
	return 0
}

mem_sql() { # id, user, body-expression
	printf "INSERT INTO public.ai_memories (id, user_id, workspace_id, body, status) VALUES ('%s', '%s', '%s', %s, 'proposed');" "$1" "$2" "${WS}" "$3"
}

audit_sql() { # memory, actor
	printf "INSERT INTO public.ai_memory_audit (memory_id, actor_id, action, after) VALUES ('%s', '%s', 'propose', '{}');" "$1" "$2"
}

check_a() {
	for role in anon authenticated; do
		for stmt in "SELECT 1 FROM public.ai_memories" "SELECT 1 FROM public.ai_memory_audit" \
			"$(mem_sql "${M1}" "${USR}" "'b'")" "$(audit_sql "${M1}" "${USR}")"; do
			refused "SET ROLE ${role}; ${stmt}" || {
				DETAIL="${role} was not refused: ${stmt}"
				return 1
			}
		done
	done
	return 0
}

check_b() {
	run_sql "SET ROLE service_role;
$(mem_sql "${M1}" "${USR}" "'b'")
$(audit_sql "${M1}" "${USR}")" || {
		DETAIL="seed failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	for stmt in "UPDATE public.ai_memory_audit SET action = 'edit'" "DELETE FROM public.ai_memory_audit" "TRUNCATE public.ai_memory_audit"; do
		refused "${stmt};" || return 1
	done
	left="$(q "SELECT count(*) FROM public.ai_memory_audit;")"
	[ "${left}" = "1" ] && return 0
	DETAIL="audit holds ${left} rows after the refused writes, expected 1"
	return 1
}

check_c() {
	refused "$(mem_sql "${M2}" "${USR}" "''")" || return 1
	refused "$(mem_sql "${M2}" "${USR}" "repeat('x', 301)")" || return 1
	run_sql "$(mem_sql "${M2}" "${USR}" "repeat('x', 300)")" && return 0
	DETAIL="a 300-character body was refused: $(head -1 "${WORK}/sql.err")"
	return 1
}

check_d() {
	run_sql "$(mem_sql "${M3}" "${OTHER}" "'other'")
$(audit_sql "${M3}" "${OTHER}")
$(audit_sql "${M2}" "${USR}")" || {
		DETAIL="seed failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	run_sql "SELECT public.ai_erase_user('${USR}');" || {
		DETAIL="ai_erase_user failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	mine="$(q "SELECT (SELECT count(*) FROM public.ai_memories WHERE user_id = '${USR}') + (SELECT count(*) FROM public.ai_memory_audit WHERE memory_id IN ('${M1}','${M2}'));")"
	theirs="$(q "SELECT (SELECT count(*) FROM public.ai_memories WHERE user_id = '${OTHER}') + (SELECT count(*) FROM public.ai_memory_audit WHERE memory_id = '${M3}');")"
	[ "${mine}" = "0" ] && [ "${theirs}" = "2" ] && return 0
	DETAIL="user rows left=${mine} (want 0), other rows=${theirs} (want 2)"
	return 1
}

check_e() {
	apply_file "${MEM}" || return 1
	col="$(q "SELECT count(*) FROM information_schema.columns WHERE table_name = 'ai_runs' AND column_name = 'memory_pins';")"
	trg="$(q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.ai_memory_audit'::regclass AND NOT tgisinternal;")"
	[ "${col}" = "1" ] && [ "${trg}" = "2" ] && return 0
	DETAIL="memory_pins=${col} triggers=${trg}, expected 1/2"
	return 1
}

check_f() {
	base="$(basename "${MEM}")"
	last="$(printf '%s\n' osionos-ai-migration.sql "${base}" | LC_ALL=C sort | tail -1)"
	[ "${last}" = "${base}" ] && [ "${base}" != osionos-ai-migration.sql ] && return 0
	DETAIL="${base} sorts before osionos-ai-migration.sql"
	return 1
}

main() {
	start_pg
	note "postgres up in ${CTN}; migration ${MEM}"
	# The real prerequisite tables, not the stand-in: ai_erase_user lives in the
	# events file, which triggers on them.
	run_sql "DO \$\$ BEGIN
		IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
		IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
		IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
	END \$\$;" || exit 1
	# ai_erase_user lives in the events file, which captures from these tables.
	for base in osionos-bridge-migration.sql osionos-chat-migration.sql \
		osionos-social-migration.sql osionos-engagement-migration.sql \
		osionos-comments-migration.sql osionos-favorites-migration.sql \
		osionos-feed-engagement-migration.sql; do
		apply_file "${MODELS}/${base}" || exit 1
	done
	apply_file "${MODELS}/osionos-ai-migration.sql" || exit 1
	apply_file "${MODELS}/osionos-user-events-migration.sql" || exit 1
	# First apply here, second in check_e: the replay is the idempotence proof.
	apply_file "${MEM}" || exit 1
	for fn in check_a check_b check_c check_d check_e check_f; do
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
