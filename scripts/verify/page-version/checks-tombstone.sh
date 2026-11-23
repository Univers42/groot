# page-version/checks-tombstone.sh — c10 (osionos #344): a page id re-created
# after a hard delete continues its content version; it never restarts at 0, so
# a stale `update … where id = $1 and version = 0` cannot match the new row.
#
# Every case: create the page, two content updates (version 2), delete it by one
# of the three paths the tree has (P344-2), create the SAME id again, then a
# stale conditional write at version 0 must touch 0 rows and the page must read
# version 3.
#   rest     the bridge's delete: DELETE + POST + conditional PATCH through the
#            throwaway PostgREST, as service_role.
#   cascade  DELETE of the workspace as service_role; the FK cascade
#            (osionos-bridge-migration.sql:51) removes the page.
#   erase    the erase's own statement (osionos-account-erasure-migration.sql:725)
#            run as postgres, the owner its SECURITY DEFINER function runs as.
#            osionos_account_erase itself is NOT applied here: it needs the
#            ORDERED_LAST account files (foundation … user-emails), which this
#            fixture does not load. models-grants.sh would, but it needs the
#            apps/grobase submodule.
# Plus: a payload version is overwritten (P344-6); a create racing an
# uncommitted delete fails with SQLSTATE 40001 instead of landing at 0 (P344-5);
# the delete trigger is statement-level and lock-free, and a 5,000-page cascade
# leaves 5,000 tombstones (P344-3/4); the rollback file round-trips (P344-7).
#
# Sourced by scripts/verify/page-version.sh, which calls these checks: the
# linter reads one file at a time and calls them unreachable.
# shellcheck shell=sh disable=SC2317,SC2329

C10_WS="11111111-1111-1111-1111-111111111110"
C10_OWNER="22222222-2222-2222-2222-222222222222"
C10_ERASED="33333333-3333-3333-3333-333333333333"
P10R="aaaaaaaa-0000-0000-0000-0000000010a1"
P10C="aaaaaaaa-0000-0000-0000-0000000010a2"
P10E="aaaaaaaa-0000-0000-0000-0000000010a3"
P10D="aaaaaaaa-0000-0000-0000-0000000010a4"
P10F="aaaaaaaa-0000-0000-0000-0000000010a5"

# c10_page <id> <owner> [version] — a private page in the c10 workspace. A third
# argument puts a version in the payload, which the database must ignore.
c10_page() {
	if [ -n "${3:-}" ]; then
		q "INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title, content, visibility, version)
VALUES ('$1', '${C10_WS}', '$2', 'c10', '[{\"id\":\"new\",\"type\":\"text\",\"content\":\"n\"}]'::jsonb, 'private', $3)" >/dev/null
	else
		q "INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title, content, visibility)
VALUES ('$1', '${C10_WS}', '$2', 'c10', '[{\"id\":\"new\",\"type\":\"text\",\"content\":\"n\"}]'::jsonb, 'private')" >/dev/null
	fi
}

c10_workspace() {
	q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug)
VALUES ('${C10_WS}', '${C10_OWNER}', 'c10', 'c10') ON CONFLICT (id) DO NOTHING" >/dev/null
}

# Two content writes: the page reads version 2.
c10_two_writes() {
	q "UPDATE public.osionos_pages SET content = '[{\"id\":\"w1\",\"type\":\"text\",\"content\":\"1\"}]'::jsonb WHERE id = '$1';
UPDATE public.osionos_pages SET content = '[{\"id\":\"w2\",\"type\":\"text\",\"content\":\"2\"}]'::jsonb WHERE id = '$1';" >/dev/null
}

# The stale client's write: rows it touched.
c10_stale_write() {
	q "WITH u AS (
  UPDATE public.osionos_pages SET content = '[{\"id\":\"stale\",\"type\":\"text\",\"content\":\"s\"}]'::jsonb
   WHERE id = '$1' AND version = 0 RETURNING 1
) SELECT count(*) FROM u"
}

# c10_judge <case> <id> <rows the stale write touched> — prints PASS or FAIL.
c10_judge() {
	v="$(version_of "$2")"
	if [ "$3" = "0" ] && [ "${v}" = "3" ]; then
		printf 'PASS c10 %-8s the re-created id continued at version %s; the stale write at version 0 touched 0 rows\n' "$1" "${v}"
		return 0
	fi
	printf 'FAIL c10 %-8s the re-created id reads version %s (expected 3); the stale write at version 0 touched %s row(s) (expected 0)\n' "$1" "${v}" "$3"
	return 1
}

# rest <method> <path> [json] — the HTTP status; the body lands in ${WORK}/rest.body.
rest() {
	svc="$(mint_jwt service_role)"
	if [ -n "${3:-}" ]; then
		set -- "$1" "$2" -d "$3"
	fi
	m="$1"
	p="$2"
	shift 2
	curl -sS -o "${WORK}/rest.body" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${PGRST_PORT}/${p}" \
		-H "apikey: ${svc}" -H "Authorization: Bearer ${svc}" \
		-H "Content-Type: application/json" -H "Prefer: return=representation" "$@"
}

c10_rest() {
	curl -sS -o /dev/null "http://127.0.0.1:${PGRST_PORT}/" 2>/dev/null || start_postgrest || return 1
	c10_page "${P10R}" "${C10_OWNER}"
	c10_two_writes "${P10R}"
	del="$(rest DELETE "osionos_pages?id=eq.${P10R}")"
	post="$(rest POST osionos_pages "{\"id\":\"${P10R}\",\"workspace_id\":\"${C10_WS}\",\"owner_id\":\"${C10_OWNER}\",\"title\":\"c10\",\"content\":[]}")"
	if [ "${del}" != "200" ] || [ "${post}" != "201" ]; then
		printf 'FAIL c10 rest     DELETE answered %s, the re-create POST answered %s (expected 200 and 201): %s\n' "${del}" "${post}" "$(tr -d '\n' <"${WORK}/rest.body")"
		return 1
	fi
	patch="$(rest PATCH "osionos_pages?id=eq.${P10R}&version=eq.0" '{"content":[{"id":"stale","type":"text","content":"s"}]}')"
	body="$(tr -d '\n' <"${WORK}/rest.body")"
	rows=1
	[ "${patch}" = "200" ] && [ "${body}" = "[]" ] && rows=0
	printf '[c10] rest: DELETE %s, POST %s, stale PATCH version=eq.0 -> %s %.60s\n' "${del}" "${post}" "${patch}" "${body}" >&2
	c10_judge rest "${P10R}" "${rows}"
}

c10_cascade() {
	c10_page "${P10C}" "${C10_OWNER}"
	c10_two_writes "${P10C}"
	q "BEGIN; SET LOCAL ROLE service_role;
DELETE FROM public.osionos_workspaces WHERE id = '${C10_WS}';
COMMIT;" >/dev/null || {
		printf 'FAIL c10 cascade  the workspace DELETE as service_role was refused\n'
		return 1
	}
	c10_workspace
	# The payload says 0; the database decides (P344-6).
	c10_page "${P10C}" "${C10_OWNER}" 0
	c10_judge cascade "${P10C}" "$(c10_stale_write "${P10C}")"
}

c10_erase() {
	c10_page "${P10E}" "${C10_ERASED}"
	c10_two_writes "${P10E}"
	q "DELETE FROM public.osionos_pages WHERE owner_id = '${C10_ERASED}' AND visibility = 'private'" >/dev/null
	c10_page "${P10E}" "${C10_ERASED}"
	c10_judge erase "${P10E}" "$(c10_stale_write "${P10E}")"
}

# P344-6: an id never deleted starts at 0 whatever the payload says.
c10_payload() {
	c10_page "${P10F}" "${C10_OWNER}" 99
	v="$(version_of "${P10F}")"
	if [ "${v}" = "0" ]; then
		printf 'PASS c10 payload  an INSERT carrying version 99 for a new id reads version 0\n'
		return 0
	fi
	printf 'FAIL c10 payload  an INSERT carrying version 99 for a new id reads version %s (expected 0)\n' "${v}"
	return 1
}

# P344-5: A deletes at version 2 and holds its transaction open; B re-creates the
# id meanwhile. B must fail with 40001, and B's retry after A commits reads 3.
c10_race() {
	c10_page "${P10D}" "${C10_OWNER}"
	c10_two_writes "${P10D}"
	printf '%s\n' 'BEGIN;' "DELETE FROM public.osionos_pages WHERE id = '${P10D}';" 'SELECT pg_sleep(3);' 'COMMIT;' |
		docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt \
			>"${WORK}/race-del.out" 2>&1 &
	pd=$!
	sleep 1
	printf '%s\n' '\set VERBOSITY sqlstate' \
		"INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title) VALUES ('${P10D}', '${C10_WS}', '${C10_OWNER}', 'race');" |
		docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt \
			>"${WORK}/race-ins.out" 2>"${WORK}/race-ins.err" && rc=0 || rc=$?
	wait "${pd}" || true
	code="$(sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\).*/\1/p' "${WORK}/race-ins.err" | head -1)"
	if [ "${rc}" -eq 0 ] || [ "${code}" != "40001" ]; then
		printf 'FAIL c10 race     a create racing an uncommitted delete answered rc=%s sqlstate=%s (expected 40001); version now %s\n' "${rc}" "${code:-none}" "$(version_of "${P10D}")"
		return 1
	fi
	q "INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title) VALUES ('${P10D}', '${C10_WS}', '${C10_OWNER}', 'retry')" >/dev/null
	v="$(version_of "${P10D}")"
	if [ "${v}" = "3" ]; then
		printf 'PASS c10 race     a create racing an uncommitted delete failed with 40001; its retry reads version 3\n'
		return 0
	fi
	printf 'FAIL c10 race     the create failed with 40001, but its retry reads version %s (expected 3)\n' "${v}"
	return 1
}

# P344-5 through PostgREST: the same race, the create sent as the bridge sends it.
# PostgREST v12 retries a transaction that fails with 40001 (measured
# 2026-11-23: the 40001 is in the postgres log, the POST answers 201), so the
# property checked is the one that matters: never a 201 carrying a restarted
# version. A 201 must carry tombstone + 1; any other answer must be a 5xx.
P10G="aaaaaaaa-0000-0000-0000-0000000010a6"
c10_rest_race() {
	c10_page "${P10G}" "${C10_OWNER}"
	c10_two_writes "${P10G}"
	printf '%s\n' 'BEGIN;' "DELETE FROM public.osionos_pages WHERE id = '${P10G}';" 'SELECT pg_sleep(3);' 'COMMIT;' |
		docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt \
			>"${WORK}/rest-race-del.out" 2>&1 &
	pd=$!
	sleep 1
	code="$(rest POST osionos_pages "{\"id\":\"${P10G}\",\"workspace_id\":\"${C10_WS}\",\"owner_id\":\"${C10_OWNER}\",\"title\":\"race\"}")"
	wait "${pd}" || true
	got="$(sed -n 's/.*"version":\([0-9]*\).*/\1/p' "${WORK}/rest.body")"
	case "${code}" in
	201)
		if [ "${got}" = "3" ]; then
			printf 'PASS c10 rest-race a POST racing an uncommitted delete answered 201 at version 3 (PostgREST retried the 40001)\n'
			return 0
		fi
		printf 'FAIL c10 rest-race a POST racing an uncommitted delete answered 201 at version %s (expected 3)\n' "${got:-none}"
		return 1
		;;
	5??)
		printf 'PASS c10 rest-race a POST racing an uncommitted delete answered %s, not a 201\n' "${code}"
		return 0
		;;
	esac
	printf 'FAIL c10 rest-race a POST racing an uncommitted delete answered %s: %s\n' "${code}" "$(tr -d '\n' <"${WORK}/rest.body")"
	return 1
}

# P344-3 + P344-4: the delete trigger is statement-level over a transition table,
# and no function of the file takes an advisory lock.
c10_shape() {
	shape="$(q "SELECT (tgtype & 1) || '|' || coalesce(tgoldtable, '-') FROM pg_trigger
 WHERE tgrelid = 'public.osionos_pages'::regclass AND tgname = 'osionos_pages_version_tombstone_trg'")"
	adv="$(q "SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
 AND proname LIKE 'osionos\\_page\\_version\\_%' AND prosrc ILIKE '%advisory%'")"
	if [ "${shape}" = "0|deleted_pages" ] && [ "${adv}" = "0" ]; then
		printf 'PASS c10 shape    the tombstone trigger is FOR EACH STATEMENT over OLD TABLE deleted_pages; no advisory lock\n'
		return 0
	fi
	printf 'FAIL c10 shape    trigger row-bit|old-table = %s (expected 0|deleted_pages); advisory-lock functions = %s (expected 0)\n' "${shape:-absent}" "${adv}"
	return 1
}

# P344-3 at size: a 5,000-page workspace deleted in one statement leaves 5,000
# tombstones.
C10_BULK_WS="11111111-1111-1111-1111-1111111111b0"
c10_bulk() {
	q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug)
VALUES ('${C10_BULK_WS}', '${C10_OWNER}', 'c10-bulk', 'c10-bulk');
INSERT INTO public.osionos_pages (workspace_id, owner_id, title)
SELECT '${C10_BULK_WS}', '${C10_OWNER}', 'bulk-' || g FROM generate_series(1, 5000) g;" >/dev/null
	before="$(q "SELECT count(*) FROM public.osionos_page_version_tombstones")"
	t0="$(date +%s%N)"
	q "BEGIN; SET LOCAL ROLE service_role;
DELETE FROM public.osionos_workspaces WHERE id = '${C10_BULK_WS}';
COMMIT;" >/dev/null || {
		printf 'FAIL c10 bulk     the 5,000-page workspace DELETE as service_role was refused\n'
		return 1
	}
	ms=$((($(date +%s%N) - t0) / 1000000))
	after="$(q "SELECT count(*) FROM public.osionos_page_version_tombstones")"
	if [ $((after - before)) = "5000" ]; then
		printf 'PASS c10 bulk     a 5,000-page workspace cascade wrote 5,000 tombstones (%s ms wall, docker exec included)\n' "${ms}"
		return 0
	fi
	printf 'FAIL c10 bulk     the 5,000-page cascade wrote %s tombstones (expected 5000)\n' "$((after - before))"
	return 1
}

# P344-7: the rollback removes every object the file made, and the file applies
# again on top of it.
c10_rollback() {
	objs="SELECT (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.osionos_pages'::regclass
   AND tgname IN ('osionos_pages_version_tombstone_trg', 'osionos_pages_version_seed_trg', 'osionos_pages_version_recheck_trg'))
 || '|' || (to_regclass('public.osionos_page_version_tombstones') IS NOT NULL)"
	apply "${REPO}/scripts/rollback/page-version-tombstone-rollback.sql" || return 1
	gone="$(q "${objs}")"
	apply "${MODELS}/osionos-page-version-tombstone-migration.sql" || return 1
	back="$(q "${objs}")"
	if [ "${gone}" = "0|false" ] && [ "${back}" = "3|true" ]; then
		printf 'PASS c10 rollback the rollback dropped the 3 triggers and the table; the file then applied again (3 triggers, table back)\n'
		return 0
	fi
	printf 'FAIL c10 rollback after rollback %s (expected 0|false), after re-apply %s (expected 3|true)\n' "${gone}" "${back}"
	return 1
}

# Every case runs, so a RED run lists every path that restarts at 0. The
# rollback runs last: it empties the tombstone table.
check_recreate_version() {
	c10_workspace
	ok=0
	c10_rest || ok=1
	c10_cascade || ok=1
	c10_erase || ok=1
	c10_payload || ok=1
	c10_race || ok=1
	c10_rest_race || ok=1
	c10_shape || ok=1
	c10_bulk || ok=1
	c10_rollback || ok=1
	return "${ok}"
}
