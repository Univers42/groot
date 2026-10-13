-- osionos_app_connections — per-account registry of connected third-party apps
-- (the Settings → Connections catalog: Slack, GitHub, Google Calendar, …).
--
-- Previously the Connections tab lived only in browser localStorage AND its REST
-- calls hit `/api/connections`, which actually serves the SOCIAL contacts graph
-- (a route collision) — so it had no real backend. This table gives connections a
-- durable, owner-isolated home: ONE row per (owner, provider). The bridge
-- (service-role key) stamps `owner_id` from the verified app-session token and
-- scopes every read/write by it.
--
-- The bridge (service_role) is the only reader and writer; nobody else gets a grant.

create extension if not exists "pgcrypto";

create table if not exists public.osionos_app_connections (
	id               uuid primary key default gen_random_uuid(),
	owner_id         uuid not null,
	provider         text not null,
	label            text not null default '',
	scopes           text[] not null default '{}',
	status           text not null default 'connected',
	external_account text,
	metadata         jsonb not null default '{}'::jsonb,
	connected_at     timestamptz not null default now(),
	last_sync_at     timestamptz,
	created_at       timestamptz not null default now(),
	updated_at       timestamptz not null default now(),
	removed_at       timestamptz,
	unique (owner_id, provider)
);

create index if not exists osionos_app_connections_owner_idx
	on public.osionos_app_connections (owner_id);

alter table public.osionos_app_connections enable row level security;

drop policy if exists osionos_app_connections_service_role_all on public.osionos_app_connections;
create policy osionos_app_connections_service_role_all
	on public.osionos_app_connections for all
	to service_role using (true) with check (true);

drop policy if exists osionos_app_connections_owner_all on public.osionos_app_connections;

grant all on public.osionos_app_connections to service_role;

notify pgrst, 'reload schema';
