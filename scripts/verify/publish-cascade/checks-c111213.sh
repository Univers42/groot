# shellcheck shell=sh

# publish-cascade/checks-c111213.sh — c11 a members re-key, c12 the backfill a
# re-apply runs over rows that predate the triggers, c13 the staged workspace
# delete (osionos-workspace-publish-hold-migration.sql).
#
# Each check seeds its own rows: c1-c10 already moved, archived and deleted the
# shared fixture.
#
# Sourced by scripts/verify/publish-cascade.sh, which calls these checks: the
# linter reads one file at a time and calls them unreachable.
# shellcheck disable=SC2317,SC2329

MARKET="5a4b1c2d-1111-4111-8111-000000000001"
X="22222222-0000-4000-8000-0000000000c1"
Y="22222222-0000-4000-8000-0000000000c2"
Z="22222222-0000-4000-8000-0000000000c3"
Q="22222222-0000-4000-8000-0000000000c4"
W11="11111111-0000-4000-8000-0000000000b1"
W13="11111111-0000-4000-8000-0000000000d1"
W13B="11111111-0000-4000-8000-0000000000d2"

# publish_new <page> <workspace> <owner> — a fresh page and its snapshot.
publish_new() {
	q "INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title, content, visibility)
VALUES ('$1', '$2', '$3', 'c-$1', '[]'::jsonb, 'public');
INSERT INTO public.osionos_published_pages (page_id, owner_id, title, icon, content)
VALUES ('$1', '$3', 'c-$1', 'star', '[]'::jsonb);" >/dev/null
}

# expect_rows <check> <label> <page> <0|1> — print the verdict for one page.
expect_rows() {
	n="$(pub_row "$3")"
	if [ "${n}" = "$4" ]; then
		printf 'PASS %s %-14s %s holds %s snapshot row(s)\n' "$1" "$2" "$3" "${n}"
		return 0
	fi
	printf 'FAIL %s %-14s %s holds %s snapshot row(s), expected %s\n' "$1" "$2" "$3" "${n}" "$4"
	return 1
}

check_c11() {
	P_USER="cccccccc-0000-4000-8000-000000000011"
	P_WS="cccccccc-0000-4000-8000-000000000012"
	P_STAY="cccccccc-0000-4000-8000-000000000013"
	q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('${W11}', '${B}', 'w-rekey', 'w-rekey-${W11}');
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role) VALUES
 ('${W11}', '${B}', 'owner'), ('${W11}', '${X}', 'editor'), ('${W11}', '${Z}', 'editor');" >/dev/null
	publish_new "${P_USER}" "${W11}" "${X}"
	publish_new "${P_WS}" "${W11}" "${Z}"
	publish_new "${P_STAY}" "${W11}" "${B}"
	# The members row is re-keyed in place, never deleted: only the UPDATE
	# trigger can see that X and Z stopped holding W11.
	q "UPDATE public.osionos_workspace_members SET user_id = '${Y}' WHERE workspace_id = '${W11}' AND user_id = '${X}';
UPDATE public.osionos_workspace_members SET workspace_id = '${V}' WHERE workspace_id = '${W11}' AND user_id = '${Z}';" >/dev/null
	expect_rows c11 user-rekey "${P_USER}" 0 &&
		expect_rows c11 ws-rekey "${P_WS}" 0 &&
		expect_rows c11 bystander "${P_STAY}" 1
}

check_c12() {
	P_ARCH="cccccccc-0000-4000-8000-000000000021"
	P_NOMEM="cccccccc-0000-4000-8000-000000000022"
	P_MARKET="cccccccc-0000-4000-8000-000000000023"
	P_OK="cccccccc-0000-4000-8000-000000000024"
	P_DRIFT="cccccccc-0000-4000-8000-000000000025"
	q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug)
VALUES ('${MARKET}', '${B}', 'marketplace', 'marketplace-${MARKET}') ON CONFLICT (id) DO NOTHING;" >/dev/null
	publish_new "${P_ARCH}" "${W}" "${B}"
	publish_new "${P_NOMEM}" "${W}" "${Q}"
	publish_new "${P_MARKET}" "${MARKET}" "${Q}"
	publish_new "${P_OK}" "${W}" "${B}"
	publish_new "${P_DRIFT}" "${W}" "${B}"
	# Y holds W, so P_DRIFT's only fault is the owner mismatch.
	q "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role) VALUES ('${W}', '${Y}', 'editor')" >/dev/null
	# Rows that went stale while no trigger existed: the triggers are switched
	# off for the setup so only the re-apply's backfill can clean them.
	q "ALTER TABLE public.osionos_pages DISABLE TRIGGER osionos_publish_unhold;
UPDATE public.osionos_pages SET archived_at = now() WHERE id = '${P_ARCH}';
UPDATE public.osionos_published_pages SET owner_id = '${Y}' WHERE page_id = '${P_DRIFT}';
ALTER TABLE public.osionos_pages ENABLE TRIGGER osionos_publish_unhold;" >/dev/null
	undo_stream || return 1
	expect_rows c12 archived "${P_ARCH}" 0 &&
		expect_rows c12 no-member "${P_NOMEM}" 0 &&
		expect_rows c12 owner-drift "${P_DRIFT}" 0 &&
		expect_rows c12 marketplace "${P_MARKET}" 1 &&
		expect_rows c12 consistent "${P_OK}" 1
}

check_c13() {
	P_DEL="cccccccc-0000-4000-8000-000000000031"
	P_KEEP="cccccccc-0000-4000-8000-000000000032"
	P_PRE="cccccccc-0000-4000-8000-000000000033"
	q "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES
 ('${W13}', '${B}', 'w-pending', 'w-pending-${W13}'),
 ('${W13B}', '${B}', 'w-pre-pending', 'w-pre-pending-${W13B}');
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role) VALUES
 ('${W13}', '${B}', 'owner'), ('${W13B}', '${B}', 'owner');" >/dev/null
	publish_new "${P_DEL}" "${W13}" "${B}"
	publish_new "${P_KEEP}" "${V}" "${B}"
	publish_new "${P_PRE}" "${W13B}" "${B}"
	q "UPDATE public.osionos_workspaces SET pending_delete_at = now(), delete_after = now() + interval '14 days' WHERE id = '${W13}'" >/dev/null
	expect_rows c13 staged-delete "${P_DEL}" 0 &&
		expect_rows c13 other-ws "${P_KEEP}" 1 || return 1
	# Already pending before the trigger existed: the file's backfill ends it.
	q "ALTER TABLE public.osionos_workspaces DISABLE TRIGGER osionos_publish_workspace_pending;
UPDATE public.osionos_workspaces SET pending_delete_at = now(), delete_after = now() + interval '14 days' WHERE id = '${W13B}';
ALTER TABLE public.osionos_workspaces ENABLE TRIGGER osionos_publish_workspace_pending;" >/dev/null
	expect_rows c13 pre-backfill "${P_PRE}" 1 || return 1
	apply "${HOLD_SQL}" || return 1
	expect_rows c13 backfill "${P_PRE}" 0 &&
		expect_rows c13 other-ws "${P_KEEP}" 1
}
