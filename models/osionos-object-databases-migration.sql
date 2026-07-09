-- osionos_object_databases — server-side home for user-created "object" databases
-- (the inline `/database` blocks; id shape `db-<hex>`, source=adapter).
--
-- Previously these lived ONLY in the browser (localStorage
-- `osionos.knownDatabaseState.v1`), so a database's schema + records never left the
-- device — invisible on any other machine and lost on a cache clear. This table
-- gives each one a durable, owner-isolated home in Postgres (the mini-baas volume):
-- ONE row per (owner, db_key) holding the whole database slice — its schema, views,
-- name AND records — as JSONB (`state`).
--
-- The bridge (service-role key) is the enforcement boundary; it stamps `owner_id`
-- from the verified app-session token and scopes every read/write by it. The RLS
-- below is defense-in-depth for a hypothetical direct/anon connection — owner-only,
-- mirroring the per-user pattern of osionos_page_configurations.

create extension if not exists "pgcrypto";

create table if not exists public.osionos_object_databases (
	id           uuid primary key default gen_random_uuid(),
	owner_id     uuid not null,
	workspace_id uuid references public.osionos_workspaces (id) on delete cascade,
	db_key       text not null,
	title        text not null default 'Untitled',
	state        jsonb not null default '{}'::jsonb,
	created_at   timestamptz not null default now(),
	updated_at   timestamptz not null default now(),
	unique (owner_id, db_key)
);

create index if not exists osionos_object_databases_owner_idx
	on public.osionos_object_databases (owner_id);
create index if not exists osionos_object_databases_workspace_idx
	on public.osionos_object_databases (workspace_id);

alter table public.osionos_object_databases enable row level security;

drop policy if exists osionos_object_databases_service_role_all
	on public.osionos_object_databases;
create policy osionos_object_databases_service_role_all
	on public.osionos_object_databases for all
	to service_role using (true) with check (true);

-- Defense-in-depth: an authenticated (non-service-role) connection may only touch
-- its OWN object databases. The live bridge path uses the service-role key above
-- and enforces owner scoping in the handler; this keeps a direct/anon read private.
drop policy if exists osionos_object_databases_owner_all
	on public.osionos_object_databases;
create policy osionos_object_databases_owner_all
	on public.osionos_object_databases for all
	to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

grant select, insert, update, delete on public.osionos_object_databases to authenticated;
grant all on public.osionos_object_databases to service_role;

notify pgrst, 'reload schema';
