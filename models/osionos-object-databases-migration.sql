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
-- from the verified app-session token and scopes every read/write by it.
--
-- The bridge (service_role) is the only reader and writer; nobody else gets a grant.

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

drop policy if exists osionos_object_databases_owner_all
	on public.osionos_object_databases;

grant all on public.osionos_object_databases to service_role;

notify pgrst, 'reload schema';
