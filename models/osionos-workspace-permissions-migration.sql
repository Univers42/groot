-- Workspace memberships in the legacy permission vocabulary.
--
-- The bridge authorizes a workspace action with memberHasPermission
-- (apps/osionos/app/scripts/bridge-api.mjs): role owner/admin, or the action
-- itself (create, read, update, delete) or admin in `permissions`. Memberships
-- written in June 2026 carry an older vocabulary, `{read,write}`, and `write`
-- grants nothing there: an editor of Binocle Intelligence Agency or Acme
-- Operations who added a page got "addPage: create failed — Workspace
-- permission denied." from every device (b2b data center, 2026-10-13: 13 rows,
-- 11 of them editors; the June database merged on 2026-10-12 brought one).
-- Nothing writes `write` any more: tools/seeds/seed_agency_people.sh gives an
-- editor {create,read,update,delete}, which is what `write` meant.
--
-- So `write` becomes create + update + delete, in the order the bridge writes
-- (create, read, update, delete, admin); any other permission a row holds is
-- kept after them. An owner gains nothing it did not have (the role already
-- passes). Idempotent: a converged table has no `write` left and the update
-- matches no row.

update public.osionos_workspace_members m
set permissions = array(
		select p
		from unnest(array['create', 'read', 'update', 'delete', 'admin']) with ordinality as canon(p, n)
		where p = any(m.permissions) or p in ('create', 'update', 'delete')
		order by n
	) || array(
		select p
		from unnest(m.permissions) as p
		where p not in ('create', 'read', 'update', 'delete', 'admin', 'write')
	),
	updated_at = now()
where 'write' = any(m.permissions);

do $$
begin
	if exists (select 1 from public.osionos_workspace_members where 'write' = any(permissions)) then
		raise exception 'osionos_workspace_members still holds the legacy write permission';
	end if;
end
$$;
