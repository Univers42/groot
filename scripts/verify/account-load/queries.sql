-- queries.sql
-- Hot queries from the osionos bridge, exactly as issued (PostgREST filters translated to SQL).
-- Each query preceded by: -- QUERY: <id>
-- Bridge file:line cited in comment above each.

-- ============================================================
-- directory_search
-- bridge-social.mjs:70-72 — rest(config, fetchImpl, 'osionos_people_directory?select=user_id,display_name,username,profile,last_seen_at,directory_opt_out&order=display_name.asc&limit=200')
--   With fuzzy filter from bridge-social-core.mjs:213-223:
--   &or=(display_name.ilike.*q*,username.ilike.*q*,profile->>headline.ilike.*q*,search_doc.wfts(simple).q)
--   And directory_opt_out=not.eq.true
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
-- Test with 50 known user IDs from _known_users (users 1,100,1000,5000,9999) + 45 more
-- QUERY: directory_by_ids
SELECT user_id, display_name, profile, last_seen_at
FROM public.osionos_people_directory
WHERE user_id IN (
    SELECT user_id FROM _known_users
    UNION ALL
    SELECT md5(('user-' || i::text))::uuid FROM generate_series(6, 50) AS i
);

-- ============================================================
-- identity_by_email_hash
-- bridge-api.mjs:1520 — email_hash lookup with select=is_admin&limit=1:
--   baasRest(config, fetchImpl, `osionos_bridge_identities?email_hash=eq.${hash}&select=is_admin&limit=1`)
-- Test query: lookup by email_hash for a known user (user 1)
-- QUERY: identity_by_email_hash
SELECT is_admin
FROM public.osionos_bridge_identities
WHERE email_hash = md5('email-hash-1')
LIMIT 1;

-- ============================================================
-- feed_shares_for_user
-- bridge-profile.mjs:231 — listProfileShares uses:
--   rest(config, fetchImpl, `osionos_feed_shares?user_id=eq.${userId}&target=in.(profile)&select=page_id,created_at&order=created_at.desc&limit=60`)
-- QUERY: feed_shares_for_user
SELECT page_id, created_at
FROM public.osionos_feed_shares
WHERE user_id = (SELECT user_id FROM _known_users LIMIT 1)
  AND target = 'profile'
ORDER BY created_at DESC
LIMIT 60;

-- ============================================================
-- connections_for_user
-- bridge-social-core.mjs:249 — connectionEdgesPath(userId) returns:
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
-- bridge-social-core.mjs:236-244 — coMemberPath(userId) uses:
--   osionos_workspace_members?user_id=eq.{userId}&select=user_id,workspace_id,workspace:osionos_workspaces!workspace_id(members:osionos_workspace_members!workspace_id(user_id))
-- For a large workspace (workspace 1 has ~200+ members), test the co-member read.
-- QUERY: workspace_members_of_large_workspace
SELECT wm.workspace_id, wm.user_id, wm.role, wm.permissions,
       w.id, w.owner_id, w.name, w.slug, w.settings, w.created_at, w.updated_at
FROM public.osionos_workspace_members wm
JOIN public.osionos_workspaces w ON w.id = wm.workspace_id
WHERE wm.workspace_id = (SELECT id FROM public.osionos_workspaces WHERE slug LIKE 'workspace-1-%' LIMIT 1)
ORDER BY wm.created_at;

-- ============================================================
-- pages_of_workspace (fetchPageRowWithMember shape)
-- bridge-api.mjs:972-980 — fetchPageRowWithMember uses:
--   osionos_pages?select=*,workspace:osionos_workspaces!workspace_id(members:osionos_workspace_members!workspace_id(user_id,role,permissions))&workspace.members.user_id=eq.{userId}&id=eq.{pageId}&limit=1
-- QUERY: pages_of_workspace
SELECT p.id, p.workspace_id, p.parent_page_id, p.owner_id, p.title, p.icon, p.cover,
       p.database_id, p.surface, p.visibility, p.collaborators, p.properties, p.content,
       p.is_template, p.is_default_template, p.recurrence, p.template_surface,
       p.archived_at, p.created_at, p.updated_at,
       w.id as workspace_id_2, w.owner_id as workspace_owner_id, w.name, w.slug, w.settings, w.created_at as workspace_created_at, w.updated_at as workspace_updated_at,
       wm.user_id as member_user_id, wm.role, wm.permissions
FROM public.osionos_pages p
JOIN public.osionos_workspaces w ON w.id = p.workspace_id
JOIN public.osionos_workspace_members wm ON wm.workspace_id = w.id
WHERE p.id = (SELECT id FROM public.osionos_pages WHERE workspace_id = (SELECT id FROM public.osionos_workspaces WHERE slug LIKE 'workspace-1-%' LIMIT 1) LIMIT 1)
  AND wm.user_id = (SELECT user_id FROM _known_users LIMIT 1)
LIMIT 1;