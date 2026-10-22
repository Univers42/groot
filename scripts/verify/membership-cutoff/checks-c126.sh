# shellcheck disable=SC2317,SC2329
#
# C126: the catalog of the tables a token-trusting route reads by workspace_id.
#
# The skip in the migration (a workspace that is gone signs nobody out) is only
# safe if the ROWS of every one of those tables die with the workspace. The
# catalog below prints, for every table with a workspace_id column, the foreign
# key on that column and whether its rows die with the workspace: directly, or
# through the pages (which cascade from the workspace).
#
# The assertion: a table whose rows SURVIVE the workspace delete fails the check,
# unless it is in the list below with the reason why it is safe.

# The tables whose workspace_id column carries no foreign key of its own. Their
# rows still die with the workspace, through the pages.
CATALOG_EXCEPTIONS="osionos_page_links osionos_tasks"

# The tables the five token-trusting surfaces read by workspace_id. The catalog
# must hold every one of them, or the fixture did not apply the models the
# routes read and the catalog proves nothing.
CATALOG_EXPECTED="osionos_channels osionos_page_links osionos_page_configurations osionos_pages osionos_tasks osionos_workspace_databases osionos_workspace_members"

# The catalog: table | the foreign key on workspace_id | whether the rows die with
# the workspace. "DEAD" is the recursive cascade set: every table that a delete
# of the workspace reaches, directly or through the pages.
CATALOG_SQL="
WITH RECURSIVE dead(relid) AS (
	SELECT 'public.osionos_workspaces'::regclass
	UNION
	SELECT c.conrelid
	FROM pg_constraint c JOIN dead d ON c.confrelid = d.relid
	WHERE c.contype = 'f' AND c.confdeltype = 'c'
)
SELECT t.relname || '|' || COALESCE(fk.action, 'NO FK') || '|' || CASE WHEN d.relid IS NULL THEN 'ALIVE' ELSE 'DEAD' END
FROM pg_class t
JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = 'public'
LEFT JOIN dead d ON d.relid = t.oid
LEFT JOIN LATERAL (
	SELECT CASE c.confdeltype
		WHEN 'c' THEN 'CASCADE' WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
		WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END AS action
	FROM pg_constraint c
	WHERE c.contype = 'f' AND c.conrelid = t.oid
	  AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = t.oid AND attname = 'workspace_id')]
) fk ON true
WHERE t.relkind = 'r'
  AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = t.oid AND a.attname = 'workspace_id' AND a.attnum > 0 AND NOT a.attisdropped)
ORDER BY t.relname;"

# Why a table without a foreign key of its own is still safe.
catalog_reason() {
	case "$1" in
	osionos_page_links)
		printf 'its rows cascade from osionos_pages (source_page_id), and the pages cascade from the workspace\n'
		;;
	osionos_tasks)
		printf 'its rows cascade from osionos_pages (page_id), and the pages cascade from the workspace\n'
		;;
	*)
		printf ''
		;;
	esac
}

check_c126() {
	printf '[c126] catalog: table | workspace_id FK | rows when the workspace is deleted\n' >&2
	catalog="$(q "${CATALOG_SQL}")"
	[ -n "${catalog}" ] || { printf 'FAIL c126 catalog  no table carries a workspace_id\n' >&2; return 1; }
	printf '%s\n' "${catalog}" | sed 's/|/  ->  /g' >&2
	printf '%s\n' "${catalog}" >"${WORK}/catalog.txt"

	# Every table the routes read is in the catalog.
	for expected in ${CATALOG_EXPECTED}; do
		grep -q "^${expected}|" "${WORK}/catalog.txt" || {
			printf 'FAIL c126 catalog  %s is missing: the fixture did not apply every model the routes read\n' "${expected}" >&2
			return 1
		}
	done

	# Every table in the catalog dies with the workspace, or is in the list with
	# its reason.
	while IFS='|' read -r table action verdict; do
		[ -n "${table}" ] || continue
		if [ "${verdict}" = "DEAD" ] && [ "${action}" = "CASCADE" ]; then
			printf '[c126] %s: cascades from the workspace\n' "${table}" >&2
			continue
		fi
		reason="$(catalog_reason "${table}")"
		if [ -z "${reason}" ]; then
			printf 'FAIL c126 catalog  %s does not die with the workspace (FK %s) and is not in the exception list\n' "${table}" "${action}" >&2
			return 1
		fi
		printf '[c126] %s: %s\n' "${table}" "${reason}" >&2
	done <"${WORK}/catalog.txt"

	# A workspace delete signs nobody out: the owner included.
	U="77777777-7777-4777-8777-777777777777"
	W="77777777-eeee-4eee-8eee-777777777777"
	q "INSERT INTO auth.users (id) VALUES ('${U}') ON CONFLICT DO NOTHING;" >/dev/null
	for i in 1 2 3 4; do
		ui="77777777-000${i}-4777-8777-777777777777"
		q "INSERT INTO auth.users (id) VALUES ('${ui}') ON CONFLICT DO NOTHING;" >/dev/null
	done
	q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W}','${U}','w','w-${U}') ON CONFLICT DO NOTHING;" >/dev/null
	q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W}','${U}','owner',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
	for i in 1 2 3; do
		ui="77777777-000${i}-4777-8777-777777777777"
		q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions) VALUES ('${W}','${ui}','viewer',ARRAY['read']) ON CONFLICT DO NOTHING;" >/dev/null
	done
	q "DELETE FROM public.auth_session_cutoffs;" >/dev/null
	q "DELETE FROM public.osionos_workspaces WHERE id='${W}';" >/dev/null
	c="$(q "SELECT count(*) FROM public.auth_session_cutoffs;")"
	[ "${c}" = "0" ] || { printf 'FAIL c126 ws-delete expected 0 cutoff rows, got %s\n' "${c}" >&2; return 1; }
	oc="$(q "SELECT count(*) FROM public.auth_session_cutoffs WHERE user_id='${U}';")"
	[ "${oc}" = "0" ] || { printf 'FAIL c126 owner-cutoff expected 0, got %s\n' "${oc}" >&2; return 1; }
	return 0
}
