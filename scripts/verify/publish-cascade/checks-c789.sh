# shellcheck shell=sh

# publish-cascade/checks-c789.sh — c7 the whole migration re-runs clean,
# c8 the ACL of the trigger functions, c9 the revert proof.
#
# Sourced by scripts/verify/publish-cascade.sh, which calls these checks: the
# linter reads one file at a time and calls them unreachable.
# shellcheck disable=SC2317,SC2329

# --- c7: the migration is re-runnable -----------------------------------------

snapshot() {
	q "
SELECT 'trigger|' || tgname || '|' || pg_get_triggerdef(oid)
  FROM pg_trigger
 WHERE (tgrelid = 'public.osionos_pages'::regclass AND tgname = 'osionos_publish_unhold')
    OR (tgrelid = 'public.osionos_workspace_members'::regclass
        AND tgname IN ('osionos_publish_member_left_delete', 'osionos_publish_member_left_move'))
 ORDER BY tgname;
SELECT 'func|' || proname || '|' || md5(prosrc)
  FROM pg_proc
 WHERE oid IN ('public.osionos_published_page_unhold()'::regprocedure,
               'public.osionos_published_member_left()'::regprocedure)
 ORDER BY proname;
SELECT 'index|' || indexdef FROM pg_indexes
 WHERE schemaname = 'public' AND indexname = 'osionos_published_pages_owner_idx';
SELECT 'priv|' || rolname || '|' ||
       has_function_privilege(rolname, 'public.osionos_published_page_unhold()', 'EXECUTE') || '|' ||
       has_function_privilege(rolname, 'public.osionos_published_member_left()', 'EXECUTE')
  FROM pg_roles
 WHERE rolname IN ('anon', 'authenticated', 'service_role') ORDER BY rolname;
SELECT 'rows|' || page_id || '|' || owner_id || '|' || published_at
  FROM public.osionos_published_pages ORDER BY page_id;
"
}

check_c7() {
	snapshot >"${WORK}/pc-snap1.out"
	if [ ! -s "${WORK}/pc-snap1.out" ]; then
		# An empty snapshot would make the diff vacuous: nothing to compare.
		printf 'FAIL c7 snapshot       the snapshot query produced no rows\n'
		return 1
	fi
	apply "${PUBLISH_SQL}" || return 1
	apply "${PUBLISH_SQL}" || return 1
	snapshot >"${WORK}/pc-snap2.out"
	if diff -u "${WORK}/pc-snap1.out" "${WORK}/pc-snap2.out" >"${WORK}/pc-snap.diff" 2>&1; then
		printf 'PASS c7 re-apply       the whole publish migration re-ran with no drift in triggers, functions, index, ACL or rows\n'
	else
		printf 'FAIL c7 re-apply       the re-run drifted:\n'
		sed 's/^/  | /' "${WORK}/pc-snap.diff" >&2
		return 1
	fi
	# The DROP TRIGGER IF EXISTS must make the re-run idempotent in a stronger
	# sense than "same diff": exactly one trigger of each name, no duplicates.
	names="$(q "
SELECT string_agg(tgname || '=' || n, ', ' ORDER BY tgname) FROM (
  SELECT tgname, count(*) AS n FROM pg_trigger
   WHERE tgname IN ('osionos_publish_unhold', 'osionos_publish_member_left_delete',
                    'osionos_publish_member_left_move') AND NOT tgisinternal
   GROUP BY tgname
) s")"
	if [ "${names}" = "osionos_publish_member_left_delete=1, osionos_publish_member_left_move=1, osionos_publish_unhold=1" ]; then
		printf 'PASS c7 one-each-name  exactly one trigger of each of the three names\n'
	else
		printf 'FAIL c7 one-each-name  the named triggers are: %s\n' "${names:-none}"
		return 1
	fi
	return 0
}

# --- c8: trigger functions are not callable APIs -------------------------------

check_c8() {
	for role in anon authenticated; do
		exists="$(q "SELECT count(*) FROM pg_roles WHERE rolname = '${role}'")"
		if [ "${exists}" = "0" ]; then
			# Not a failure: the fixture does not carry every deployment role.
			printf '[c8] %s is not in this fixture: the role check is skipped\n' "${role}"
			continue
		fi
		p1="$(q "SELECT has_function_privilege('${role}', 'public.osionos_published_page_unhold()', 'EXECUTE')")"
		p2="$(q "SELECT has_function_privilege('${role}', 'public.osionos_published_member_left()', 'EXECUTE')")"
		if [ "${p1}" = "f" ] && [ "${p2}" = "f" ]; then
			printf 'PASS c8 %s-denied  %s cannot EXECUTE either trigger function\n' "${role}" "${role}"
		else
			printf 'FAIL c8 %s-denied  unhold=%s member_left=%s (expected f for both)\n' "${role}" "${p1}" "${p2}"
			return 1
		fi
	done
	# The backup of the denial: service_role DOES reach the tables, but no
	# direct EXECUTE is granted either (the runner's sweep grants none).
	p="$(q "SELECT has_function_privilege('service_role', 'public.osionos_published_page_unhold()', 'EXECUTE')")"
	if [ "${p}" = "f" ]; then
		printf 'PASS c8 service-role   service_role has no direct EXECUTE either (the trigger is the only door)\n'
	else
		printf 'FAIL c8 service-role   service_role unexpectedly holds EXECUTE on the unhold function\n'
		return 1
	fi
	return 0
}

# --- c9: the revert proof --------------------------------------------------------

check_c9() {
	# Break: drop the osionos_pages trigger. An archive must now LEAVE the
	# snapshot row -- c1's archive check fails.
	q "DROP TRIGGER IF EXISTS osionos_publish_unhold ON public.osionos_pages" >/dev/null
	q "UPDATE public.osionos_pages SET archived_at = now() WHERE id = '${PC9}'" >/dev/null
	broken="$(pub_row "${PC9}")"
	if [ "${broken}" = "1" ]; then
		printf '[c9] with the trigger dropped the archive left %s snapshot row(s) for %s (the check fails as required)\n' \
			"${broken}" "${PC9}"
	else
		printf 'FAIL c9 reverted-check the check cannot tell: without the trigger the archive still removed the row (%s)\n' "${broken}"
		undo_stream || true
		return 1
	fi
	# Restore: the migration file is the source of truth.
	apply "${PUBLISH_SQL}" || return 1
	# Unarchive does not re-publish (OLD.archived_at is NOT NULL, so the WHEN
	# clause does not match), then re-archive must remove the row again.
	q "UPDATE public.osionos_pages SET archived_at = NULL WHERE id = '${PC9}'" >/dev/null
	q "UPDATE public.osionos_pages SET archived_at = now() WHERE id = '${PC9}'" >/dev/null
	restored="$(pub_row "${PC9}")"
	if [ "${restored}" = "0" ]; then
		printf 'PASS c9 restored       with the migration applied again the archive removed the row\n'
	else
		printf 'FAIL c9 restored       %s snapshot row(s) remained after the re-applied archive\n' "${restored}"
		return 1
	fi
	return 0
}
