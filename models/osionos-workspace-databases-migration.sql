-- osionos_workspace_databases — which grobase mounts a "work" (workspace) owns.
--
-- Membership (osionos_workspace_members) decides WHO can reach a workspace; this
-- table decides WHICH databases that workspace is linked to. The bridge derives a
-- user's authorized resource set by joining the two, so a caller can never name a
-- mount their workspaces aren't associated with (the client never sends a dbId).
--
-- Access enforcement lives in the bridge (it holds the tenant api-key and composes
-- the graph): every /api/databases/* handler now joins osionos_workspace_members →
-- osionos_workspaces → this table before proxying, so a caller can only reach a
-- mount linked to a workspace they own or belong to. The authenticated SELECT
-- policy below is defense-in-depth for a direct (non-service-role) connection —
-- it scopes to membership instead of full deny, mirroring osionos_workspaces.
-- ponytail: per-mount database_members + ABAC inside grobase is the deeper
-- data-plane layer (a later m<NN>); the bridge join is the immediate guard.

create extension if not exists "pgcrypto";

create table if not exists public.osionos_workspace_databases (
	id           uuid primary key default gen_random_uuid(),
	workspace_id uuid not null references public.osionos_workspaces (id) on delete cascade,
	db_id        text not null,
	engine       text,
	tables       text[] not null default '{}',
	edges_table  text,
	label        text,
	created_at   timestamptz not null default now(),
	updated_at   timestamptz not null default now(),
	unique (workspace_id, db_id)
);

create index if not exists osionos_workspace_databases_workspace_idx
	on public.osionos_workspace_databases (workspace_id);

alter table public.osionos_workspace_databases enable row level security;

drop policy if exists osionos_workspace_databases_service_role_all
	on public.osionos_workspace_databases;
create policy osionos_workspace_databases_service_role_all
	on public.osionos_workspace_databases for all
	to service_role using (true) with check (true);

-- Defense-in-depth: an authenticated connection may SELECT a mount only when it
-- owns or is a member of the linking workspace (mirrors osionos_workspaces_select_
-- member). The live bridge path uses the service-role key above; this guards any
-- future direct/anon data-plane read so databases stay personal-unless-invited.
drop policy if exists osionos_workspace_databases_select_member
	on public.osionos_workspace_databases;
create policy osionos_workspace_databases_select_member
	on public.osionos_workspace_databases for select
	to authenticated using (
		exists (
			select 1 from public.osionos_workspaces ws
			where ws.id = osionos_workspace_databases.workspace_id
				and (
					ws.owner_id = auth.uid()
					or exists (
						select 1 from public.osionos_workspace_members member
						where member.workspace_id = ws.id
							and member.user_id = auth.uid()
					)
				)
		)
	);
