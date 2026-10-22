-- queries.sql
-- Hot queries from the osionos bridge, exactly as issued (PostgREST filters translated to SQL).
-- Each query preceded by: -- QUERY: <id>
-- Bridge file:line cited in comment above each.

-- ============================================================
-- directory_search
-- bridge-social.mjs:70 — rest(config, fetchImpl, 'osionos_people_directory?select=user_id,display_name,username,profile,last_seen_at,directory_opt_out&order=display_name.asc&limit=200')
-- With fuzzy filter: directoryFuzzyFilter(query) adds &or=(display_name.ilike.*q*,username.ilike.*q*,profile->>headline.ilike.*q*,search_doc.wfts(simple).q)
-- Test query: searches for "user" (matches many)
-- QUERY: directory_search
SELECT user_id, display_name, username, profile, last_seen_at, directory_opt_out
FROM public.osionos_people_directory
WHERE directory_opt_out = false
  AND (
    display_name ILIKE '%user%' OR
    username ILIKE '%user%' OR
    profile->>'headline' ILIKE '%user%' OR
    search_doc @@ websearch_to_tsquery('simple', 'user')
  )
ORDER BY display_name ASC
LIMIT 200;

-- ============================================================
-- directory_by_ids (50 ids)
-- bridge-social-core.mjs:390 — identitySummaries uses:
--   rest(config, fetchImpl, 'osionos_people_directory?user_id=in.(ids...)&select=user_id,display_name,profile,last_seen_at')
-- Test with 50 known user IDs from _known_users (plus some more)
-- QUERY: directory_by_ids
SELECT user_id, display_name, profile, last_seen_at
FROM public.osionos_people_directory
WHERE user_id IN (
    SELECT user_id FROM _known_users
    UNION ALL
    SELECT md5(('user-' || i::text))::uuid FROM generate_series(6, 55) AS i
);

-- ============================================================
-- identity_by_email_hash
-- bridge-api.mjs:1516,1520 — email_hash lookup:
--   baasRest(config, fetchImpl, `osionos_bridge_identities?email_hash=eq.${hash}&select=is_admin&limit=1`)
--   baasRest(config, fetchImpl, `osionos_bridge_identities?email_hash=eq.${hash}&is_admin=is.false` (PATCH)
-- Test query: lookup by email_hash for a known user
-- QUERY: identity_by_email_hash
SELECT provider, subject, user_id, email_hash, display_name, username, profile,
       private_workspace_id, is_admin, directory_opt_out, created_at, updated_at, last_seen_at
FROM public.osionos_bridge_identities
WHERE email_hash = md5('email-hash-1');

-- ============================================================
-- feed_shares_for_user
-- bridge-feed.mjs (feed shares for a user) — pattern:
--   rest(config, fetchImpl, 'osionos_feed_shares?user_id=eq.{userId}&select=id,page_id,target,created_at&order=created_at.desc')
-- QUERY: feed_shares_for_user
SELECT id, page_id, user_id, target, created_at
FROM public.osionos_feed_shares
WHERE user_id = (SELECT user_id FROM _known_users LIMIT 1)
ORDER BY created_at DESC
LIMIT 50;

-- ============================================================
-- connections_for_user
-- bridge-social.mjs:99 — connectionEdgesPath(userId) returns:
--   'osionos_connections?or=(requester_id.eq.{userId},addressee_id.eq.{userId})&select=*&order=created_at.desc'
-- QUERY: connections_for_user
SELECT id, requester_id, addressee_id, status, intro_message, source,
       pair_key, created_at, responded_at
FROM public.osionos_connections
WHERE requester_id = (SELECT user_id FROM _known_users LIMIT 1)
   OR addressee_id = (SELECT user_id FROM _known_users LIMIT 1)
ORDER BY created_at DESC;

-- ============================================================
-- workspace_members_of_large_workspace
-- bridge-social-core.mjs:236 — coMemberPath(userId) uses:
--   osionos_workspace_members?user_id=eq.{userId}&select=user_id,workspace_id,workspace:osionos_workspaces!workspace_id(members:osionos_workspace_members!workspace_id(user_id))
-- This query finds all members of workspaces that a user belongs to.
-- For a large workspace (workspace 1 has ~200+ members), test the co-member read.
-- QUERY: workspace_members_of_large_workspace
SELECT wm.workspace_id, wm.user_id, wm.role, wm.permissions,
       w.id, w.owner_id, w.name, w.slug, w.settings, w.created_at, w.updated_at
FROM public.osionos_workspace_members wm
JOIN public.osionos_workspaces w ON w.id = wm.workspace_id
WHERE wm.workspace_id = (SELECT id FROM public.osionos_workspaces WHERE slug LIKE 'workspace-1-%' LIMIT 1)
ORDER BY wm.created_at;

-- ============================================================
-- pages_of_workspace
-- bridge-api.mjs:972-980 — fetchPageRowWithMember uses:
--   osionos_pages?select=*,workspace:osionos_workspaces!workspace_id(members:osionos_workspace_members!workspace_id(user_id,role,permissions))&workspace.members.user_id=eq.{userId}&id=eq.{pageId}&limit=1
-- For listing pages in a workspace (simpler list query):
--   rest(config, fetchImpl, 'osionos_pages?workspace_id=eq.{workspaceId}&select=*&order=updated_at.desc&limit=100')
-- QUERY: pages_of_workspace
SELECT id, workspace_id, parent_page_id, owner_id, title, icon, cover,
       database_id, surface, visibility, collaborators, properties, content,
       is_template, is_default_template, recurrence, template_surface,
       archived_at, created_at, updated_at
FROM public.osionos_pages
WHERE workspace_id = (SELECT id FROM public.osionos_workspaces WHERE slug LIKE 'workspace-1-%' LIMIT 1)
  AND archived_at IS NULL
ORDER BY updated_at DESC
LIMIT 100;