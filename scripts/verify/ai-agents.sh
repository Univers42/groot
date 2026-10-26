#!/bin/sh
# ai-agents.sh: prove the custom-agents migration (D3 A+C): ordered after the
# base AI migration, replayable, closed to the public roles, append-only audit,
# C337 CHECK, and the two-scope erasure.
#
# WHAT IT PROVES  (models/osionos-ai-runs-agents-migration.sql)
#   C311  the file sorts after osionos-ai-migration.sql under LC_ALL=C
#   C310  applies twice; the ai_runs CHECK is validated
#   C312  anon and authenticated can neither select nor insert (3 tables)
#   audit UPDATE, DELETE and TRUNCATE refused
#   C337  a run with custom_agent_id and a NULL version is refused
#   caps  an mcp_ tool in tools is refused
#   C338  ai_agents_erase_user: user agent gone, workspace agent kept with the
#         author tombstoned, audit scrubbed not deleted, pinned version parses
#   C314  the data map holds ai_agents (owner_id, created_by, updated_by),
#   -C316 ai_agents_audit (actor_id) and ai_workspace_agent_settings
#         (updated_by), none of them `keep`; and the PUBLIC ai_erase_user path
#         (osionos-user-events-migration.sql) leaves no uuid of the erased user
#         in any column or jsonb (before and after included) of the three
#         tables, in either scope, while the kept user's agent is byte-identical
#         (check_6; the account-erasure path is p5_agents_two_scope in
#         models-grants.sh)
#
# ISOLATION
#   One throwaway container: ai-agents-pg, --network none, no port, no volume.
#   Removed on every exit path.
#
# Usage:  [AGENTS_MIGRATION=<file>] sh scripts/verify/ai-agents.sh
# Exit:   0 every check passed, 1 a check, the fixture or the image failed
#
# shellcheck disable=SC2317,SC2329
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MODELS="${REPO}/models"
STANDIN="${REPO}/infrastructure/docker/osionos/ai-db-init/00-standin.sql"
AGENTS="${AGENTS_MIGRATION:-${MODELS}/osionos-ai-runs-agents-migration.sql}"
CTN="ai-agents-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-agents.XXXXXX")"
passed=0
failed=0
DETAIL=""

WS=11111111-1111-1111-1111-111111111111
USR=33333333-3333-3333-3333-333333333333
OTH=55555555-5555-5555-5555-555555555555
TOMB=00000000-0000-4000-8000-000000000000
A_USER=44444444-4444-4444-4444-444444444441
A_WS=44444444-4444-4444-4444-444444444442
RUN=66666666-6666-6666-6666-666666666666
U6=88888888-8888-4888-8888-888888888881
V6=88888888-8888-4888-8888-888888888882
W6=88888888-8888-4888-8888-888888888883
U6_AG=88888888-8888-4888-8888-888888888884
W6_A=88888888-8888-4888-8888-888888888885
W6_B=88888888-8888-4888-8888-888888888886
V6_AG=88888888-8888-4888-8888-888888888887

note() { printf '[ai-agents] %s\n' "$*" >&2; }
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

refused() {
	if run_sql "$1"; then
		DETAIL="accepted: $1"
		return 1
	fi
	return 0
}

agent_sql() { # id scope owner ws created_by
	printf "INSERT INTO public.ai_agents (id, scope, owner_id, workspace_id, name, instructions, created_by, updated_by) VALUES ('%s', '%s', %s, %s, 'n', 'i', '%s', '%s');" "$1" "$2" "$3" "$4" "$5" "$5"
}

check_1() {
	a="$(printf 'osionos-ai-migration.sql\nosionos-ai-runs-agents-migration.sql\n' | LC_ALL=C sort | tail -1)"
	[ "${a}" = "osionos-ai-runs-agents-migration.sql" ] || {
		DETAIL="agents file sorts before the base migration"
		return 1
	}
	apply_file "${AGENTS}" || return 1
	n="$(q "SELECT count(*) FROM pg_class WHERE relname IN ('ai_agents','ai_agents_audit','ai_workspace_agent_settings') AND relkind = 'r';")"
	v="$(q "SELECT convalidated FROM pg_constraint WHERE conname = 'ai_runs_custom_agent_check';")"
	[ "${n}" = "3" ] && [ "${v}" = "t" ] && return 0
	DETAIL="tables=${n} validated=${v}, expected 3/t"
	return 1
}

check_2() {
	for role in anon authenticated; do
		for t in ai_agents ai_agents_audit ai_workspace_agent_settings; do
			refused "SET ROLE ${role}; SELECT 1 FROM public.${t};" || {
				DETAIL="${role} read ${t}"
				return 1
			}
		done
		refused "SET ROLE ${role}; $(agent_sql "${A_USER}" user "'${USR}'" NULL "${USR}")" || return 1
	done
	return 0
}

check_3() {
	run_sql "SET ROLE service_role;
$(agent_sql "${A_USER}" user "'${USR}'" NULL "${USR}")
$(agent_sql "${A_WS}" workspace NULL "'${WS}'" "${USR}")
INSERT INTO public.ai_agents_audit (agent_id, version, action, actor_id, after)
VALUES ('${A_USER}', 1, 'create', '${USR}', '{\"owner_id\":\"${USR}\"}'),
       ('${A_WS}', 1, 'create', '${USR}', '{\"created_by\":\"${USR}\",\"instructions\":\"i\"}');" || {
		DETAIL="seed failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	for stmt in "UPDATE public.ai_agents_audit SET version = 9" "DELETE FROM public.ai_agents_audit" "TRUNCATE public.ai_agents_audit"; do
		refused "SET ROLE service_role; ${stmt};" || return 1
	done
	left="$(q "SELECT count(*) FROM public.ai_agents_audit;")"
	[ "${left}" = "2" ] && return 0
	DETAIL="audit holds ${left} rows, expected 2"
	return 1
}

check_4() {
	# The control insert proves the refusal below is the CHECK, not a missing column.
	run_sql "INSERT INTO public.ai_runs (id, owner_id, status, model, kind, custom_agent_id, custom_agent_version) VALUES ('${RUN}', '${USR}', 'running', 'm', 'image', '${A_WS}', 1);" || {
		DETAIL="control insert refused: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	if run_sql "INSERT INTO public.ai_runs (id, owner_id, status, model, kind, custom_agent_id, custom_agent_version) VALUES ('77777777-7777-7777-7777-777777777777', '${USR}', 'running', 'm', 'image', '${A_WS}', NULL);"; then
		DETAIL="C337: custom_agent_id with a NULL version was accepted"
		return 1
	fi
	grep -q ai_runs_custom_agent_check "${WORK}/sql.err" || {
		DETAIL="refused for another reason: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	refused "INSERT INTO public.ai_agents (scope, owner_id, name, instructions, tools, created_by, updated_by) VALUES ('user', '${USR}', 'n', 'i', ARRAY['mcp_x'], '${USR}', '${USR}');" || {
		DETAIL="an mcp_ tool was accepted"
		return 1
	}
	return 0
}

check_5() {
	n="$(q "SELECT public.ai_agents_erase_user('${USR}');")"
	u="$(q "SELECT count(*) FROM public.ai_agents WHERE id = '${A_USER}';")"
	w="$(q "SELECT count(*) FROM public.ai_agents WHERE id = '${A_WS}' AND created_by = '${TOMB}' AND updated_by = '${TOMB}';")"
	ua="$(q "SELECT count(*) FROM public.ai_agents_audit WHERE agent_id = '${A_USER}';")"
	wa="$(q "SELECT count(*) FROM public.ai_agents_audit WHERE agent_id = '${A_WS}' AND actor_id = '${TOMB}' AND (after->>'created_by') = '${TOMB}' AND (after->>'instructions') = 'i';")"
	left="$(q "SELECT count(*) FROM public.ai_agents_audit WHERE after::text LIKE '%${USR}%' OR actor_id = '${USR}';")"
	[ "${n}" = "1" ] && [ "${u}" = "0" ] && [ "${w}" = "1" ] && [ "${ua}" = "0" ] && [ "${wa}" = "1" ] && [ "${left}" = "0" ] && return 0
	DETAIL="erased=${n} userAgent=${u} wsAgentTombstoned=${w} userAudit=${ua} wsAuditScrubbed=${wa} uuidLeft=${left}"
	return 1
}

# check_6 — C314-C316 through the public path, ai_erase_user. U6 is erased, V6
# kept, one workspace W6. Rows: U6's user agent (create+update audit); a
# workspace agent created by U6 and updated by V6; one created by V6 and
# updated by U6; settings of W6 by U6; V6's own user agent.
# Caveat: ai_erase_user is applied from its own text extracted out of the
# migration over a one-column ai_events stand-in; a change to how that file
# lays the function out (a second `END $$;` inside it) breaks the extraction,
# which fails loudly rather than passing.
# Caveat: the data-map rows are grepped as text from the account-erasure
# migration, whose seed this script does not apply (it needs the account
# plane); a row moved into another statement would still count.
check_6() {
	# The whole file needs the seven feed/page/connection tables its capture
	# triggers sit on; only the function is under test, so its own text is
	# extracted (first CREATE of ai_erase_user to the next `END $$;`) over a
	# one-column ai_events.
	{
		printf 'CREATE TABLE IF NOT EXISTS public.ai_events (user_id uuid);\n'
		sed -n '/^CREATE OR REPLACE FUNCTION public.ai_erase_user/,/^END \$\$;/p' "${MODELS}/osionos-user-events-migration.sql"
	} >"${WORK}/erase-fn.sql"
	grep -q 'ai_agents_erase_user' "${WORK}/erase-fn.sql" || {
		DETAIL="ai_erase_user does not dispatch ai_agents_erase_user"
		return 1
	}
	apply_file "${WORK}/erase-fn.sql" || return 1
	map="${MODELS}/osionos-account-erasure-migration.sql"
	for row in "ai_agents', 'owner_id" "ai_agents', 'created_by" "ai_agents', 'updated_by" \
		"ai_agents_audit', 'actor_id" "ai_workspace_agent_settings', 'updated_by"; do
		grep -E "^\('${row}'," "${map}" | grep -v "'keep'" | grep -q . || {
			DETAIL="C314: no non-keep data-map row for ${row}"
			return 1
		}
	done
	run_sql "
INSERT INTO public.ai_agents (id, scope, owner_id, workspace_id, name, instructions, version, created_by, updated_by) VALUES
 ('${U6_AG}', 'user', '${U6}', NULL, 'n', 'i', 2, '${U6}', '${U6}'),
 ('${W6_A}', 'workspace', NULL, '${W6}', 'n', 'i', 2, '${U6}', '${V6}'),
 ('${W6_B}', 'workspace', NULL, '${W6}', 'n', 'i', 2, '${V6}', '${U6}'),
 ('${V6_AG}', 'user', '${V6}', NULL, 'n', 'i', 1, '${V6}', '${V6}');
INSERT INTO public.ai_workspace_agent_settings (workspace_id, updated_by) VALUES ('${W6}', '${U6}');
INSERT INTO public.ai_agents_audit (agent_id, version, action, actor_id, before, after)
SELECT a.id, 1, 'create', a.created_by, NULL, to_jsonb(a) - 'updated_at' FROM public.ai_agents a WHERE a.id IN ('${U6_AG}','${W6_A}','${W6_B}','${V6_AG}');
INSERT INTO public.ai_agents_audit (agent_id, version, action, actor_id, before, after)
SELECT a.id, 2, 'update', a.updated_by, to_jsonb(a) - 'updated_at', to_jsonb(a) FROM public.ai_agents a WHERE a.id IN ('${U6_AG}','${W6_A}','${W6_B}');" || {
		DETAIL="seed failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	pre="$(q "SELECT count(*) FROM public.ai_agents_audit WHERE before::text LIKE '%${U6}%' AND after::text LIKE '%${U6}%';")"
	[ "${pre:-0}" -ge 3 ] || {
		DETAIL="seed holds ${pre} audit rows with the user in before and after, expected >= 3"
		return 1
	}
	v_before="$(q "SELECT md5(row_to_json(a)::text) FROM public.ai_agents a WHERE id = '${V6_AG}';")"
	run_sql "SELECT public.ai_erase_user('${U6}');" || {
		DETAIL="ai_erase_user failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	leaks="$(q "SELECT (SELECT count(*) FROM public.ai_agents t WHERE row_to_json(t)::text LIKE '%${U6}%') + (SELECT count(*) FROM public.ai_agents_audit t WHERE row_to_json(t)::text LIKE '%${U6}%') + (SELECT count(*) FROM public.ai_workspace_agent_settings t WHERE row_to_json(t)::text LIKE '%${U6}%');")"
	gone="$(q "SELECT (SELECT count(*) FROM public.ai_agents WHERE id = '${U6_AG}') + (SELECT count(*) FROM public.ai_agents_audit WHERE agent_id = '${U6_AG}');")"
	kept="$(q "SELECT (SELECT count(*) FROM public.ai_agents WHERE id IN ('${W6_A}','${W6_B}')) || '/' || (SELECT count(*) FROM public.ai_agents_audit WHERE agent_id IN ('${W6_A}','${W6_B}'));")"
	tomb="$(q "SELECT (SELECT created_by FROM public.ai_agents WHERE id = '${W6_A}') = '${TOMB}' AND (SELECT updated_by FROM public.ai_agents WHERE id = '${W6_A}') = '${V6}' AND (SELECT updated_by FROM public.ai_agents WHERE id = '${W6_B}') = '${TOMB}' AND (SELECT created_by FROM public.ai_agents WHERE id = '${W6_B}') = '${V6}' AND (SELECT updated_by FROM public.ai_workspace_agent_settings WHERE workspace_id = '${W6}') = '${TOMB}';")"
	vkept="$(q "SELECT md5(row_to_json(a)::text) FROM public.ai_agents a WHERE id = '${V6_AG}';")"
	vaud="$(q "SELECT count(*) FROM public.ai_agents_audit WHERE agent_id = '${V6_AG}' AND actor_id = '${V6}';")"
	vref="$(q "SELECT count(*) FROM public.ai_agents_audit WHERE after::text LIKE '%${V6}%' AND agent_id IN ('${W6_A}','${W6_B}');")"
	[ "${leaks}" = "0" ] && [ "${gone}" = "0" ] && [ "${kept}" = "2/4" ] && [ "${tomb}" = "t" ] \
		&& [ -n "${v_before}" ] && [ "${vkept}" = "${v_before}" ] && [ "${vaud}" = "1" ] && [ "${vref}" = "4" ] && return 0
	DETAIL="uuidLeft=${leaks} userAgentRows=${gone} wsAgents/audit=${kept} tombstoned=${tomb} vAgentSame=$([ "${vkept}" = "${v_before}" ] && echo y || echo n) vAudit=${vaud} vInWsAudit=${vref}"
	return 1
}

main() {
	start_pg
	note "postgres up in ${CTN}; migration ${AGENTS}"
	apply_file "${STANDIN}" || exit 1
	apply_file "${MODELS}/osionos-ai-migration.sql" || exit 1
	apply_file "${AGENTS}" || exit 1
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
