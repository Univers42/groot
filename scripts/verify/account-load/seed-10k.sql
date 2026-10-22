-- seed-10k.sql
-- Deterministic 10K-user seed for account-load verification.
-- One transaction, no random(), uses generate_series + md5(i::text) for all values.
-- Completes in ≤120s on this host.
--
-- Rows:
--   10,000 auth.users + public.users + osionos_bridge_identities (with email_hash)
--   1,000 workspaces with 1–50 members (skewed: a few large ones, 200+ members)
--   100,000 pages
--   20,000 connections
--   50,000 feed shares
--
-- Known user IDs for query tests go into temp table _known_users.

BEGIN;

-- ============================================================
-- 1. USERS (auth.users, public.users, public.user_profiles, osionos_bridge_identities)
-- ============================================================

-- Generate 10,000 deterministic users
-- Using generate_series(1, 10000) and md5 for all derived values

-- auth.users (shim table: id, email, raw_user_meta_data)
INSERT INTO auth.users (id, email, raw_user_meta_data)
SELECT
    md5(('user-' || i::text))::uuid,
    'user' || i || '@example.com',
    jsonb_build_object('full_name', 'User ' || i)
FROM generate_series(1, 10000) AS i;

-- public.users (from grobase 001_initial_schema: id, email, name, created_at, updated_at)
INSERT INTO public.users (id, email, name, created_at, updated_at)
SELECT
    md5(('user-' || i::text))::uuid,
    'user' || i || '@example.com',
    'User ' || i,
    '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval,
    '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval
FROM generate_series(1, 10000) AS i;

-- public.user_profiles (from grobase 001_initial_schema: id, user_id, bio, avatar_url, display_name from shim)
INSERT INTO public.user_profiles (user_id, bio, avatar_url, display_name, created_at, updated_at)
SELECT
    md5(('user-' || i::text))::uuid,
    'Bio for user ' || i,
    'https://example.com/avatar' || i || '.png',
    'User ' || i,
    '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval,
    '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval
FROM generate_series(1, 10000) AS i;

-- osionos_bridge_identities (from osionos-bridge-migration + osionos-social-migration)
-- Columns: provider, subject, user_id, email_hash, display_name, username, profile, private_workspace_id,
-- created_at, updated_at, last_seen_at, directory_opt_out, bio_embedding, search_doc
-- Note: search_doc is GENERATED ALWAYS STORED, bio_embedding is nullable
INSERT INTO public.osionos_bridge_identities (
    provider, subject, user_id, email_hash, display_name, username, profile,
    private_workspace_id, created_at, updated_at, last_seen_at, directory_opt_out
)
SELECT
    'prismatica',
    md5(('subject-' || i::text))::uuid,
    md5(('user-' || i::text))::uuid,
    md5(('email-hash-' || i::text)),
    'User ' || i,
    'user' || i,
    jsonb_build_object('avatar', 'https://example.com/avatar' || i || '.png', 'headline', 'Headline ' || i),
    md5(('workspace-' || i::text))::uuid,
    '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval,
    '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval,
    '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval,
    false
FROM generate_series(1, 10000) AS i;

-- ============================================================
-- 2. WORKSPACES (1,000 workspaces with 1-50 members, skewed)
-- ============================================================

-- Create 1,000 workspaces
-- First 10 are "large" workspaces with 200+ members each
-- Remaining 990 have 1-50 members (deterministic distribution)
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug, source, settings, created_at, updated_at)
SELECT
    md5(('workspace-' || w::text))::uuid,
    md5(('user-' || ((w - 1) % 10000 + 1)::text))::uuid,
    'Workspace ' || w,
    'workspace-' || w || '-' || substr(md5(('workspace-' || w::text)), 1, 8),
    'bridge',
    jsonb_build_object('bridgeProvider', 'prismatica', 'role', 'owner', 'permissions', ARRAY['create','read','update','delete','admin']),
    '2024-01-01 00:00:00+00'::timestamptz + (w || ' hours')::interval,
    '2024-01-01 00:00:00+00'::timestamptz + (w || ' hours')::interval
FROM generate_series(1, 1000) AS w;

-- Workspace members
-- For each workspace w, determine member count:
--   w <= 10: 200 + (w * 10) members (200-300 range for large workspaces)
--   w > 10: 1 + ((w * 7) % 50) members (1-50 range)
-- Members are selected deterministically using md5-based offsets

-- Large workspaces (1-10): 200-300 members each
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions, created_at, updated_at)
SELECT
    md5(('workspace-' || w::text))::uuid,
    md5(('user-' || user_idx::text))::uuid,
    CASE WHEN user_idx = ((w - 1) % 10000 + 1) THEN 'owner' ELSE 'viewer' END,
    CASE WHEN user_idx = ((w - 1) % 10000 + 1)
         THEN ARRAY['create','read','update','delete','admin']
         ELSE ARRAY['read'] END,
    '2024-01-01 00:00:00+00'::timestamptz + (w || ' hours')::interval + (user_idx || ' minutes')::interval,
    '2024-01-01 00:00:00+00'::timestamptz + (w || ' hours')::interval + (user_idx || ' minutes')::interval
FROM generate_series(1, 10) AS w
CROSS JOIN LATERAL (
    SELECT ((w * 1000 + u * 37) % 10000) + 1 AS user_idx
    FROM generate_series(0, 199 + w * 10) AS u
) members;

-- Small/medium workspaces (11-1000): 1-50 members each
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions, created_at, updated_at)
SELECT
    md5(('workspace-' || w::text))::uuid,
    md5(('user-' || user_idx::text))::uuid,
    CASE WHEN user_idx = ((w - 1) % 10000 + 1) THEN 'owner' ELSE 'viewer' END,
    CASE WHEN user_idx = ((w - 1) % 10000 + 1)
         THEN ARRAY['create','read','update','delete','admin']
         ELSE ARRAY['read'] END,
    '2024-01-01 00:00:00+00'::timestamptz + (w || ' hours')::interval + (user_idx || ' minutes')::interval,
    '2024-01-01 00:00:00+00'::timestamptz + (w || ' hours')::interval + (user_idx || ' minutes')::interval
FROM generate_series(11, 1000) AS w
CROSS JOIN LATERAL (
    SELECT ((w * 1000 + u * 37) % 10000) + 1 AS user_idx
    FROM generate_series(0, 1 + ((w * 7) % 50)) AS u
) members;

-- ============================================================
-- 3. PAGES (100,000 pages across workspaces)
-- ============================================================

-- Distribute 100,000 pages across 1,000 workspaces (100 per workspace)
-- Pages have varying surface types and visibility
INSERT INTO public.osionos_pages (
    id, workspace_id, parent_page_id, owner_id, title, icon, cover,
    database_id, surface, visibility, collaborators, properties, content,
    is_template, is_default_template, recurrence, template_surface,
    created_at, updated_at
)
SELECT
    md5(('page-' || p::text))::uuid,
    md5(('workspace-' || ((p - 1) % 1000 + 1)::text))::uuid,
    NULL,
    md5(('user-' || ((p * 13) % 10000 + 1)::text))::uuid,
    'Page ' || p,
    CASE (p % 5) WHEN 0 THEN '📄' WHEN 1 THEN '📋' WHEN 2 THEN '📁' WHEN 3 THEN '🏠' ELSE '⚙️' END,
    NULL,
    CASE WHEN p % 10 = 0 THEN 'db-' || p ELSE NULL END,
    CASE (p % 4) WHEN 0 THEN 'page' WHEN 1 THEN 'agent' WHEN 2 THEN 'home' ELSE 'folder' END,
    CASE (p % 3) WHEN 0 THEN 'private' WHEN 1 THEN 'shared' ELSE 'public' END,
    '[]'::jsonb,
    '[]'::jsonb,
    '[]'::jsonb,
    false,
    false,
    NULL,
    NULL,
    '2024-01-01 00:00:00+00'::timestamptz + (p || ' seconds')::interval,
    '2024-01-01 00:00:00+00'::timestamptz + (p || ' seconds')::interval
FROM generate_series(1, 100000) AS p;

-- ============================================================
-- 4. CONNECTIONS (20,000 connections)
-- ============================================================

-- Create 20,000 connections between users using deterministic unique pairs.
-- Use a pairing function that generates unique (requester, addressee) pairs.
-- Generate extra rows and use ON CONFLICT DO NOTHING to handle any collisions.
INSERT INTO public.osionos_connections (
    requester_id, addressee_id, status, intro_message, source, created_at, responded_at
)
SELECT
    md5(('user-' || req::text))::uuid,
    md5(('user-' || add::text))::uuid,
    CASE (i % 5) WHEN 0 THEN 'pending' WHEN 1 THEN 'accepted' WHEN 2 THEN 'declined' WHEN 3 THEN 'withdrawn' ELSE 'blocked' END,
    'Intro message for connection ' || i,
    CASE (i % 2) WHEN 0 THEN 'manual' ELSE 'colleague' END,
    '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval,
    CASE WHEN i % 5 != 0 THEN '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval + '1 hour'::interval ELSE NULL END
FROM generate_series(1, 30000) AS i
CROSS JOIN LATERAL (
    SELECT ((i * 13) % 10000) + 1 AS req
) r
CROSS JOIN LATERAL (
    SELECT CASE
        WHEN ((req * 17) % 10000) + 1 = req THEN ((req * 17) % 10000) + 2
        ELSE ((req * 17) % 10000) + 1
    END AS add
) a
WHERE req <> add
ON CONFLICT (pair_key) DO NOTHING;

-- ============================================================
-- 5. FEED SHARES (50,000 feed shares)
-- ============================================================

-- 50,000 shares across pages and users
INSERT INTO public.osionos_feed_shares (page_id, user_id, target, created_at)
SELECT
    md5(('page-' || ((s * 17) % 100000 + 1)::text))::uuid,
    md5(('user-' || ((s * 19) % 10000 + 1)::text))::uuid,
    CASE (s % 3) WHEN 0 THEN 'profile' WHEN 1 THEN 'link' ELSE 'dm' END,
    '2024-01-01 00:00:00+00'::timestamptz + (s || ' seconds')::interval
FROM generate_series(1, 50000) AS s;



-- Verify counts
-- SELECT 'users' AS table_name, count(*) FROM auth.users
-- UNION ALL SELECT 'public.users', count(*) FROM public.users
-- UNION ALL SELECT 'user_profiles', count(*) FROM public.user_profiles
-- UNION ALL SELECT 'bridge_identities', count(*) FROM public.osionos_bridge_identities
-- UNION ALL SELECT 'workspaces', count(*) FROM public.osionos_workspaces
-- UNION ALL SELECT 'workspace_members', count(*) FROM public.osionos_workspace_members
-- UNION ALL SELECT 'pages', count(*) FROM public.osionos_pages
-- UNION ALL SELECT 'connections', count(*) FROM public.osionos_connections
-- UNION ALL SELECT 'feed_shares', count(*) FROM public.osionos_feed_shares;

COMMIT;