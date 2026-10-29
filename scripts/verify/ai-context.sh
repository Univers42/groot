#!/bin/sh
# **************************************************************************** #
#                                                                              #
#    ai-context.sh                                                             #
#                                                                              #
#    Prove the AI context items migration (U1): closed to the public roles,    #
#    append-only audit, replayable, scope and caps enforced, erasable.         #
#                                                                              #
# **************************************************************************** #
#
# WHAT IT PROVES  (models/osionos-ai-context-migration.sql)
#   1  the migration applies twice: two tables, two audit triggers, the erase
#      function (C1002)
#   2  anon and authenticated can neither select nor insert on both tables, nor
#      call ai_context_erase_user
#   3  ai_context_item_audit refuses UPDATE, DELETE and TRUNCATE, even for the
#      owner; a user-scope audit row with a workspace is refused
#   4  the scope/owner CHECK, workspace-skill refusal and the 1200-character rule
#      body are CHECKs; a 6000-character user skill is accepted (C1004)
#   5  one active item per (owner, kind, slug): a duplicate is refused, the same
#      slug of another kind or another owner is not, an archive frees the slug
#   6  ai_context_erase_user deletes only that user's user-scope items and turns
#      them into the tombstone as the author of a workspace rule (C1007)
#   7  service_role can read and write an item and append to the audit
#   8  the commands migration (U2) refuses to run before U1, widens the kind
#      CHECK found by its shape, replays: a user command is accepted, a
#      workspace command and an unknown kind are refused (C1106)
#   9  the hooks migration (U3) refuses to run before U2, replays, accepts a
#      user hook of 1 to 32 pattern lines; refuses a workspace hook, an empty
#      or trailing line, 33 lines and a bad pattern; erase deletes a hook
#      (C1124, C1130, C1133)
#
# ISOLATION
#   One throwaway container: ai-context-pg, --network none, no port, no volume.
#   Removed on every exit path.
#
# Usage:  [CONTEXT_MIGRATION=<file>] [COMMANDS_MIGRATION=<file>] [HOOKS_MIGRATION=<file>] sh scripts/verify/ai-context.sh
# Exit:   0 every check passed · 1 a check, the fixture or the image failed
#
# shellcheck disable=SC2317,SC2329
# The functions are reached through the loop in main() and the trap.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MODELS="${REPO}/models"
STANDIN="${REPO}/infrastructure/docker/osionos/ai-db-init/00-standin.sql"
CONTEXT="${CONTEXT_MIGRATION:-${MODELS}/osionos-ai-context-migration.sql}"
COMMANDS="${COMMANDS_MIGRATION:-${MODELS}/osionos-ai-context-commands-migration.sql}"
HOOKS="${HOOKS_MIGRATION:-${MODELS}/osionos-ai-context-hooks-migration.sql}"
CTN="ai-context-pg"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:0.8.0-pg16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-context.XXXXXX")"
passed=0
failed=0
DETAIL=""

WS=11111111-1111-1111-1111-111111111111
USR=33333333-3333-3333-3333-333333333333
OTHER=33333333-3333-3333-3333-333333333334
TOMB=00000000-0000-4000-8000-000000000000
I1=44444444-4444-4444-4444-444444444441

note() { printf '[ai-context] %s\n' "$*" >&2; }
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

# item_sql kind scope owner workspace slug body-expression [id]
item_sql() {
	printf "INSERT INTO public.ai_context_items (id, kind, scope, owner_id, workspace_id, slug, name, description, body, created_by, updated_by) VALUES (%s, '%s', '%s', %s, %s, '%s', 'n', 'd', %s, '%s', '%s');" \
		"${7:-gen_random_uuid()}" "$1" "$2" "$3" "$4" "$5" "$6" "${USR}" "${USR}"
}
user_item() { item_sql "$1" user "'${USR}'" NULL "$2" "${3:-'b'}" "${4:-}"; }

check_1() {
	# Second apply of the migration.
	apply_file "${CONTEXT}" || return 1
	n="$(q "SELECT count(*) FROM pg_class WHERE relname IN ('ai_context_items','ai_context_item_audit') AND relkind = 'r';")"
	trg="$(q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.ai_context_item_audit'::regclass AND NOT tgisinternal;")"
	erase_fn="$(q "SELECT count(*) FROM pg_proc WHERE oid = to_regprocedure('public.ai_context_erase_user(uuid)');")"
	[ "${n}" = "2" ] && [ "${trg}" = "2" ] && [ "${erase_fn}" = "1" ] && return 0
	DETAIL="tables=${n} triggers=${trg} erase_fn=${erase_fn}, expected 2/2/1"
	return 1
}

check_2() {
	for role in anon authenticated; do
		for stmt in "SELECT 1 FROM public.ai_context_items" "SELECT 1 FROM public.ai_context_item_audit" \
			"$(user_item rule zz)" \
			"INSERT INTO public.ai_context_item_audit (item_id, scope, version, action, actor_id) VALUES ('${I1}', 'user', 1, 'create', '${USR}')" \
			"SELECT public.ai_context_erase_user('${USR}')"; do
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
INSERT INTO public.ai_context_item_audit (item_id, scope, version, action, actor_id, after)
VALUES ('${I1}', 'user', 1, 'create', '${USR}', '{\"body_length\":1}');" || {
		DETAIL="seed failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	for stmt in "UPDATE public.ai_context_item_audit SET version = 9" "DELETE FROM public.ai_context_item_audit" "TRUNCATE public.ai_context_item_audit"; do
		refused "${stmt};" || return 1
	done
	refused "INSERT INTO public.ai_context_item_audit (item_id, scope, workspace_id, version, action, actor_id) VALUES ('${I1}', 'user', '${WS}', 1, 'create', '${USR}');" || return 1
	left="$(q "SELECT count(*) FROM public.ai_context_item_audit;")"
	[ "${left}" = "1" ] && return 0
	DETAIL="audit holds ${left} rows after the refused writes, expected 1"
	return 1
}

check_4() {
	refused "$(item_sql rule user "'${USR}'" "'${WS}'" both-set "'b'")" || return 1
	refused "$(item_sql rule user NULL NULL no-owner "'b'")" || return 1
	refused "$(item_sql rule workspace "'${USR}'" "'${WS}'" ws-owner "'b'")" || return 1
	refused "$(item_sql skill workspace NULL "'${WS}'" ws-skill "'b'")" || return 1
	refused "$(user_item rule long-rule "repeat('x', 1201)")" || return 1
	refused "$(user_item skill long-skill "repeat('x', 6001)")" || return 1
	refused "$(user_item skill 'Bad_Slug')" || return 1
	run_sql "$(user_item rule rule-cap "repeat('x', 1200)")
$(user_item skill skill-cap "repeat('x', 6000)")
$(item_sql rule workspace NULL "'${WS}'" ws-rule "'b'")" && return 0
	DETAIL="a valid item was refused: $(head -1 "${WORK}/sql.err")"
	return 1
}

check_5() {
	run_sql "$(user_item skill shared "'b'" "'${I1}'")" || {
		DETAIL="seed failed: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	refused "$(user_item skill shared)" || {
		DETAIL="a duplicate active slug was accepted"
		return 1
	}
	run_sql "$(user_item rule shared)
$(item_sql skill user "'${OTHER}'" NULL shared "'b'")
UPDATE public.ai_context_items SET archived_at = now() WHERE id = '${I1}';
$(user_item skill shared)" && return 0
	DETAIL="slug not free across kind, owner or after archive: $(head -1 "${WORK}/sql.err")"
	return 1
}

check_6() {
	mine="$(q "SELECT count(*) FROM public.ai_context_items WHERE scope = 'user' AND owner_id = '${USR}';")"
	got="$(q "SELECT public.ai_context_erase_user('${USR}');")"
	left="$(q "SELECT count(*) FROM public.ai_context_items WHERE owner_id = '${USR}';")"
	other="$(q "SELECT count(*) FROM public.ai_context_items WHERE owner_id = '${OTHER}';")"
	authored="$(q "SELECT count(*) FROM public.ai_context_items WHERE '${USR}' IN (created_by, updated_by);")"
	tomb="$(q "SELECT count(*) FROM public.ai_context_items WHERE scope = 'workspace' AND created_by = '${TOMB}' AND updated_by = '${TOMB}';")"
	[ "${got}" = "${mine}" ] && [ "${left}" = "0" ] && [ "${other}" = "1" ] && [ "${authored}" = "0" ] && [ "${tomb}" = "1" ] && return 0
	DETAIL="deleted=${got}/${mine} left=${left} other=${other} authored=${authored} tombstoned=${tomb}, expected n/n 0 1 0 1"
	return 1
}

check_7() {
	run_sql "SET ROLE service_role;
$(user_item rule svc-rule)
UPDATE public.ai_context_items SET version = version + 1 WHERE slug = 'svc-rule';
INSERT INTO public.ai_context_item_audit (item_id, scope, workspace_id, version, action, actor_id)
VALUES ('${I1}', 'workspace', '${WS}', 2, 'update', '${USR}');
SELECT count(*) FROM public.ai_context_items;" && return 0
	DETAIL="service_role refused: $(head -1 "${WORK}/sql.err")"
	return 1
}

check_8() {
	apply_file "${COMMANDS}" || return 1
	apply_file "${COMMANDS}" || return 1
	checks="$(q "SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.ai_context_items'::regclass AND pg_get_constraintdef(oid) LIKE '%''command''%';")"
	[ "${checks}" = "1" ] || {
		DETAIL="${checks} CHECKs name 'command' after two applies, expected 1"
		return 1
	}
	refused "$(item_sql command workspace NULL "'${WS}'" ws-command "'b'")" || return 1
	refused "$(user_item hook a-hook)" || return 1
	run_sql "$(user_item command standup "repeat('x', 6000)")" && return 0
	DETAIL="a user command was refused: $(head -1 "${WORK}/sql.err")"
	return 1
}

check_9() {
	apply_file "${HOOKS}" || return 1
	apply_file "${HOOKS}" || return 1
	checks="$(q "SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.ai_context_items'::regclass AND pg_get_constraintdef(oid) LIKE '%''hook''%';")"
	body_check="$(q "SELECT count(*) FROM pg_constraint WHERE conname = 'ai_context_items_hook_body';")"
	if [ "${checks}" != "2" ] || [ "${body_check}" != "1" ]; then
		DETAIL="${checks} CHECKs name 'hook', ${body_check} body CHECK after two applies, expected 2 and 1"
		return 1
	fi
	refused "$(item_sql hook workspace NULL "'${WS}'" ws-hook "'create_page'")" || return 1
	for body in "''" "E'create_page\\n'" "E'create_page\\n\\narchive_page'" "'create page'" "'*'" "'9tool'" "'mcp_*x'" \
		"(SELECT string_agg('t' || n, E'\\n') FROM generate_series(1, 33) AS n)" "repeat('a', 65)"; do
		refused "$(user_item hook bad-hook "${body}")" || return 1
	done
	run_sql "$(user_item hook one-line "'archive_page'")
$(user_item hook many "E'create_page\\nmcp_ab12cd34_*\\nweb-fetch'")
$(user_item hook max-lines "(SELECT string_agg('t' || n, E'\\n') FROM generate_series(1, 32) AS n)")
$(user_item hook max-name "repeat('a', 64) || '*'")" || {
		DETAIL="a valid hook was refused: $(head -1 "${WORK}/sql.err")"
		return 1
	}
	q "SELECT public.ai_context_erase_user('${USR}');" >/dev/null
	left="$(q "SELECT count(*) FROM public.ai_context_items WHERE kind = 'hook' AND owner_id = '${USR}';")"
	[ "${left}" = "0" ] && return 0
	DETAIL="${left} hooks left after the erase, expected 0"
	return 1
}

main() {
	start_pg
	note "postgres up in ${CTN}; migration ${CONTEXT}"
	apply_file "${STANDIN}" || exit 1
	# U2 before U1 must stop with its message, not pass silently.
	if apply_file "${COMMANDS}" 2>/dev/null || ! grep -q 'apply osionos-ai-context-migration.sql before' "${WORK}/apply.log"; then
		fail check_0 "the commands migration did not refuse to run before U1"
	else
		pass check_0 "commands migration refuses before U1"
	fi
	# First apply here, second in check_1: the replay is the idempotence proof.
	apply_file "${CONTEXT}" || exit 1
	# U3 before U2 must stop with its message too.
	if apply_file "${HOOKS}" 2>/dev/null || ! grep -q 'apply osionos-ai-context-commands-migration.sql before' "${WORK}/apply.log"; then
		fail check_0 "the hooks migration did not refuse to run before U2"
	else
		pass check_0 "hooks migration refuses before U2"
	fi
	for fn in check_1 check_2 check_3 check_4 check_5 check_6 check_7 check_8 check_9; do
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
