#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    ai-skills.sh                                                              #
#                                                                              #
#    Prove the workspace-skills migration (P5b-2): closed to the public roles, #
#    append-only audit, replayable, a slug is free again after an archive.     #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES  (models/osionos-ai-skills-migration.sql)
#   1  the migration applies twice (two tables, the skill_pins column, 2 triggers)
#   2  anon and authenticated can neither select nor insert, on both tables (C43)
#   3  ai_skill_audit refuses UPDATE, DELETE and TRUNCATE, even for the owner (C40)
#   4  the partial unique index: a duplicate active slug is refused, the slug is
#      free again once the first skill is archived
#   5  the caps are CHECKs: a 6001-character body and a bad slug are refused (C47)
#   6  service_role can read and write the skill and append to the audit
#
# ISOLATION
#   One throwaway container: ai-skills-pg, --network none, no port, no volume.
#   Removed on every exit path.
#
# Usage:  [SKILLS_MIGRATION=<file>] sh scripts/verify/ai-skills.sh
# Exit:   0 every check passed · 1 a check, the fixture or the image failed
#
# shellcheck disable=SC2317,SC2329
# The functions are reached through the loop in main() and the trap.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MODELS="${REPO}/models"
STANDIN="${REPO}/infrastructure/docker/osionos/ai-db-init/00-standin.sql"
SKILLS="${SKILLS_MIGRATION:-${MODELS}/osionos-ai-skills-migration.sql}"
CTN="ai-skills-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-skills.XXXXXX")"
passed=0
failed=0
DETAIL=""

WS=11111111-1111-1111-1111-111111111111
USR=33333333-3333-3333-3333-333333333333
S1=44444444-4444-4444-4444-444444444441
S2=44444444-4444-4444-4444-444444444442

note() { printf '[ai-skills] %s\n' "$*" >&2; }
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

skill_sql() { # slug, body-expression
	printf "INSERT INTO public.ai_skills (id, workspace_id, slug, name, description, body, created_by, updated_by) VALUES ('%s', '%s', '%s', 'n', 'd', %s, '%s', '%s');" "$3" "${WS}" "$1" "$2" "${USR}" "${USR}"
}

check_1() {
	# Second apply of the migration.
	apply_file "${SKILLS}" || return 1
	n="$(q "SELECT count(*) FROM pg_class WHERE relname IN ('ai_skills','ai_skill_audit') AND relkind = 'r';")"
	col="$(q "SELECT count(*) FROM information_schema.columns WHERE table_name = 'ai_runs' AND column_name = 'skill_pins';")"
	trg="$(q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.ai_skill_audit'::regclass AND NOT tgisinternal;")"
	[ "${n}" = "2" ] && [ "${col}" = "1" ] && [ "${trg}" = "2" ] && return 0
	DETAIL="tables=${n} skill_pins=${col} triggers=${trg}, expected 2/1/2"
	return 1
}

check_2() {
	for role in anon authenticated; do
		for stmt in "SELECT 1 FROM public.ai_skills" "SELECT 1 FROM public.ai_skill_audit" \
			"INSERT INTO public.ai_skills (workspace_id, slug, name, description, body, created_by, updated_by) VALUES ('${WS}', 'zz', 'n', 'd', 'b', '${USR}', '${USR}')" \
			"INSERT INTO public.ai_skill_audit (skill_id, workspace_id, version, action, actor_id) VALUES ('${S1}', '${WS}', 1, 'create', '${USR}')"; do
			refused "SET ROLE ${role}; ${stmt};" || {
				DETAIL="${role} was not refused: ${stmt}"
				return 1
			}
		done
	done
	return 0
}

check_3() {
	run_sql "SET ROLE service_role;
$(skill_sql audit-one "'b'" "${S1}")
INSERT INTO public.ai_skill_audit (skill_id, workspace_id, version, action, actor_id, after)
VALUES ('${S1}', '${WS}', 1, 'create', '${USR}', '{\"slug\":\"audit-one\"}');" || {
		DETAIL="seed failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	for stmt in "UPDATE public.ai_skill_audit SET version = 9" "DELETE FROM public.ai_skill_audit" "TRUNCATE public.ai_skill_audit"; do
		refused "${stmt};" || return 1
	done
	left="$(q "SELECT count(*) FROM public.ai_skill_audit;")"
	[ "${left}" = "1" ] && return 0
	DETAIL="audit holds ${left} rows after the refused writes, expected 1"
	return 1
}

check_4() {
	refused "$(skill_sql audit-one "'b'" "${S2}")" || {
		DETAIL="a duplicate active slug was accepted"
		return 1
	}
	run_sql "UPDATE public.ai_skills SET archived_at = now() WHERE id = '${S1}';
$(skill_sql audit-one "'b'" "${S2}")" && return 0
	DETAIL="slug not free after archive: $(head -1 "${WORK}/sql.err")"
	return 1
}

check_5() {
	refused "$(skill_sql cap-body "repeat('x', 6001)" 44444444-4444-4444-4444-444444444443)" || return 1
	refused "$(skill_sql 'Bad_Slug' "'b'" 44444444-4444-4444-4444-444444444444)" || return 1
	run_sql "$(skill_sql cap-ok "repeat('x', 6000)" 44444444-4444-4444-4444-444444444445)" && return 0
	DETAIL="a 6000-character body was refused: $(head -1 "${WORK}/sql.err")"
	return 1
}

check_6() {
	run_sql "SET ROLE service_role;
UPDATE public.ai_skills SET version = version + 1 WHERE id = '${S2}';
INSERT INTO public.ai_skill_audit (skill_id, workspace_id, version, action, actor_id)
VALUES ('${S2}', '${WS}', 2, 'update', '${USR}');
SELECT count(*) FROM public.ai_skills;" && return 0
	DETAIL="service_role refused: $(head -1 "${WORK}/sql.err")"
	return 1
}

main() {
	start_pg
	note "postgres up in ${CTN}; migration ${SKILLS}"
	apply_file "${STANDIN}" || exit 1
	apply_file "${MODELS}/osionos-ai-migration.sql" || exit 1
	# First apply here, second in check_1: the replay is the idempotence proof.
	apply_file "${SKILLS}" || exit 1
	for fn in check_1 check_2 check_3 check_4 check_5 check_6; do
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
