-- AI assistant tables for the `osionos-ai` service: conversations, messages,
-- runs, the daily spend ledger, and the users' own model connections (P2). The
-- service keeps them in the SAME Postgres as osionos_pages; the RAG index (P3)
-- is NOT part of this file.
--
-- The bridge (service_role) is the only reader and writer; anon and
-- authenticated get no privilege on any of them. These tables are named `ai_*`,
-- so the pattern-based catalog pass in osionos-service-role-only-migration.sql
-- does NOT cover them ("a new table needs the prefix or its own REVOKE") —
-- each table therefore carries its own REVOKE here.
--
-- Idempotent: every CREATE is IF NOT EXISTS / DROP POLICY IF EXISTS-shaped;
-- applied twice against a throwaway pgvector 0.8.0 / PG16 container to prove it.
--
-- No touch-updated_at trigger on ai_conversations: models/ has no shared
-- updated_at function or trigger to reuse, so the service sets updated_at itself.

create extension if not exists "pgcrypto";

create table if not exists public.ai_conversations (
	id           uuid primary key default gen_random_uuid(),
	owner_id     uuid not null,
	workspace_id uuid not null,
	title        text not null default '',
	model        text,
	created_at   timestamptz not null default now(),
	updated_at   timestamptz not null default now(),
	archived_at  timestamptz
);

-- Inbox listing: a user's live conversations in a workspace, most recently
-- touched first; archived rows are excluded from the scan.
create index if not exists ai_conversations_owner_ws_updated_idx
	on public.ai_conversations (owner_id, workspace_id, updated_at desc)
	where archived_at is null;

create table if not exists public.ai_messages (
	id              uuid primary key default gen_random_uuid(),
	conversation_id uuid not null references public.ai_conversations (id) on delete cascade,
	run_id          uuid,
	role            text not null check (role in ('user','assistant','system','tool')),
	parts           jsonb not null default '[]'::jsonb check (jsonb_typeof(parts) = 'array'),
	model           text,
	usage           jsonb,
	created_at      timestamptz not null default now()
);

-- Transcript read: one conversation's messages in order.
create index if not exists ai_messages_conversation_idx
	on public.ai_messages (conversation_id, created_at);

create table if not exists public.ai_runs (
	-- NO default: the client generates this id and sends it with every attempt,
	-- so the primary key doubles as the idempotency key — a retried request
	-- hits the unique violation instead of starting a second run.
	id                uuid primary key,
	conversation_id   uuid not null references public.ai_conversations (id) on delete cascade,
	owner_id          uuid not null,
	status            text not null check (status in ('running','succeeded','failed','cancelled')),
	model             text not null,
	error             text,
	usage             jsonb,
	reserved_microusd bigint not null default 0 check (reserved_microusd >= 0),
	created_at        timestamptz not null default now(),
	ended_at          timestamptz
);

create index if not exists ai_runs_owner_created_idx
	on public.ai_runs (owner_id, created_at desc);
-- Stale-run sweep: only rows still 'running' are candidates for the reaper.
create index if not exists ai_runs_running_created_idx
	on public.ai_runs (created_at) where status = 'running';
-- One running run per conversation. Two concurrent POSTs on the same
-- conversation do not race: the second one hits this unique violation and is
-- refused with 409 run_in_progress. The index is partial, so a finished run
-- never blocks the next one.
create unique index if not exists ai_runs_one_running_per_conversation
	on public.ai_runs (conversation_id) where status = 'running';

-- Daily spend ledger. subject is a user id as text, or the literal 'platform'
-- for the global breaker. ONE row per (subject, day).
create table if not exists public.ai_usage_daily (
	subject           text not null,
	day               date not null,
	spent_microusd    bigint not null default 0 check (spent_microusd >= 0),
	reserved_microusd bigint not null default 0 check (reserved_microusd >= 0),
	primary key (subject, day)
);

comment on table public.ai_usage_daily is
	'reserve/settle protocol: reserve = INSERT (subject, day, 0, 0) ... ON CONFLICT DO NOTHING, then
	 UPDATE ai_usage_daily SET reserved_microusd = reserved + $r WHERE subject = $s AND day = $d
	 AND spent + reserved + $r <= $limit RETURNING 1 (no row -> refuse); settle = reserved -= $r, spent += $actual.';

-- The connections of P2: how a user brings their own model access (an API
-- key, or their own OpenAI-compatible endpoint).
--
-- PERSONAL SCOPE ONLY in v2: owner_user_id is the only gate, and a connection
-- never belongs to a workspace. The workspace scope — a connection shared by a
-- workspace, with its own members — comes later, in its own table; this one
-- keeps the personal rows readable by their owner alone.
--
-- The secret never leaves the server: secret_box holds the key under a
-- per-secret data key, and wrapped_dek holds that data key under the KEK of
-- the deployment (kek_id names it). The plaintext is nowhere in this database,
-- and last4 is the only part of the key that is readable.
create table if not exists public.ai_connections (
	id             uuid primary key default gen_random_uuid(),
	owner_user_id  uuid not null,
	kind           text not null check (kind in ('api_key','oauth','endpoint')),
	provider       text not null,
	label          text not null,
	base_url       text,
	last4          text,
	secret_box     bytea,
	wrapped_dek    bytea,
	kek_id         text,
	status         text not null default 'untested' check (status in ('ok','error','untested')),
	status_message text,
	created_at     timestamptz not null default now(),
	updated_at     timestamptz not null default now()
);

-- The inbox of a user's connections: their own, the newest first.
create index if not exists ai_connections_owner_created_idx
	on public.ai_connections (owner_user_id, created_at desc);

comment on table public.ai_connections is
	'AI assistant connections (P2): the users own model access. Personal scope only in v2 — owner_user_id is the only gate. The secret is envelope-encrypted: secret_box under a per-secret data key, wrapped_dek under the KEK (kek_id); last4 is the only readable part of the key.';

comment on table public.ai_conversations is 'AI assistant conversations; one row per thread, scoped to an owner and workspace.';
comment on table public.ai_messages     is 'AI assistant transcript rows; parts is the message part array (text/tool/…), cascade-deleted with the conversation.';
comment on table public.ai_runs         is 'AI assistant runs; client-generated id is the idempotency key, cascade-deleted with the conversation.';

-- RLS: service_role only (precedent: osionos-object-databases-migration.sql ~:35-45).
alter table public.ai_conversations enable row level security;
alter table public.ai_messages      enable row level security;
alter table public.ai_runs          enable row level security;
alter table public.ai_usage_daily   enable row level security;
alter table public.ai_connections   enable row level security;

drop policy if exists ai_conversations_service_role_all on public.ai_conversations;
create policy ai_conversations_service_role_all
	on public.ai_conversations for all
	to service_role using (true) with check (true);

drop policy if exists ai_messages_service_role_all on public.ai_messages;
create policy ai_messages_service_role_all
	on public.ai_messages for all
	to service_role using (true) with check (true);

drop policy if exists ai_runs_service_role_all on public.ai_runs;
create policy ai_runs_service_role_all
	on public.ai_runs for all
	to service_role using (true) with check (true);

drop policy if exists ai_usage_daily_service_role_all on public.ai_usage_daily;
create policy ai_usage_daily_service_role_all
	on public.ai_usage_daily for all
	to service_role using (true) with check (true);

drop policy if exists ai_connections_service_role_all on public.ai_connections;
create policy ai_connections_service_role_all
	on public.ai_connections for all
	to service_role using (true) with check (true);

grant all on public.ai_conversations to service_role;
grant all on public.ai_messages      to service_role;
grant all on public.ai_runs          to service_role;
grant all on public.ai_usage_daily   to service_role;
grant all on public.ai_connections   to service_role;

-- ai_* is outside the osionos_* catalog pass (see header): close PostgREST's
-- anon/authenticated roles here, not pattern-matched elsewhere.
revoke all on public.ai_conversations from public, anon, authenticated;
revoke all on public.ai_messages      from public, anon, authenticated;
revoke all on public.ai_runs          from public, anon, authenticated;
revoke all on public.ai_usage_daily   from public, anon, authenticated;
revoke all on public.ai_connections   from public, anon, authenticated;

notify pgrst, 'reload schema';
