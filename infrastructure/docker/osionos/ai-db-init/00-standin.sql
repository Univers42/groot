-- Stand-in for the osionos tables the AI service reads, on the dev stack's own
-- Postgres (compose service `osionos-ai-db`, profile `ai`).
--
-- WHY THIS FILE EXISTS. grobase's Postgres is NOT on this Docker daemon: in
-- link mode it runs elsewhere and is reached through a link relay, so the AI
-- service cannot share its database. The dev stack therefore brings its own
-- small Postgres, and this file gives it the two osionos tables the service
-- reads plus the two page functions it calls.
--
-- THE REAL DEFINITIONS ARE THE SOURCE OF TRUTH: models/osionos-bridge-migration.sql
-- (the tables) and models/osionos-page-search-migration.sql (the functions).
-- This file holds the SAME COLUMNS as the test-only fixture of
-- services/osionos-ai/scripts/test.sh and nothing more; it is a stand-in, not
-- a fork. Change it there first, then here.
--
-- THE CAVEAT: these tables are EMPTY, so the page context of a run reads
-- nothing and every page the client sends is reported back in
-- `run.started.skippedPageIds`. A real grobase Postgres (set
-- OSIONOS_AI_DATABASE_URL in .env.local) carries the real pages and the real
-- workspace members; only then does a run quote the pages it is given.
--
-- The roles the AI migration grants to (service_role) and revokes from (anon,
-- authenticated) must exist BEFORE 10-osionos-ai.sql runs: it is applied
-- after this file, and it grants to service_role. Created only if missing —
-- this file must also be safe next to a grobase Postgres that has them.

do $$
begin
	if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
	if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
	if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end
$$;

-- TEST-ONLY FIXTURE: the columns of osionos_workspace_members that
-- canAccessWorkspace reads. The production table (models/osionos-bridge-migration.sql)
-- carries created_at/updated_at and a foreign key to osionos_workspaces as well; this
-- fixture holds the same column types and nothing more.
create table if not exists public.osionos_workspace_members (
	workspace_id uuid not null,
	user_id uuid not null,
	role text not null,
	permissions text[] not null default array['read'],
	primary key (workspace_id, user_id)
);

-- TEST-ONLY FIXTURE: the columns of osionos_pages that the page context of a
-- run reads (src/pageContext.ts). The production table
-- (models/osionos-bridge-migration.sql) carries many more; this fixture holds
-- the same column types and nothing more.
create table if not exists public.osionos_pages (
	id uuid primary key default gen_random_uuid(),
	workspace_id uuid not null,
	owner_id uuid,
	title text not null default 'Untitled',
	visibility text not null default 'private',
	collaborators jsonb not null default '[]'::jsonb,
	content jsonb not null default '[]'::jsonb,
	archived_at timestamptz
);

-- TEST-ONLY FIXTURE: the block walker of the pages, copied verbatim from
-- models/osionos-page-search-migration.sql, so the real SQL of the page
-- context runs against the fixture.
CREATE OR REPLACE FUNCTION public.osionos_page_blocks(doc jsonb)
RETURNS SETOF jsonb
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  WITH RECURSIVE walk(b) AS (
    SELECT jsonb_array_elements(CASE WHEN jsonb_typeof(doc) = 'array' THEN doc ELSE '[]'::jsonb END)
    UNION ALL
    SELECT jsonb_array_elements(w.b -> 'children')
    FROM walk w
    WHERE jsonb_typeof(w.b -> 'children') = 'array'
  )
  SELECT b FROM walk
$$;

-- TEST-ONLY FIXTURE: the text projection of a page, copied verbatim from
-- models/osionos-page-search-migration.sql.
CREATE OR REPLACE FUNCTION public.osionos_page_text(doc jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT coalesce(string_agg(b ->> 'content', ' '), '')
  FROM public.osionos_page_blocks(doc) AS b
  WHERE b ? 'content'
$$;
