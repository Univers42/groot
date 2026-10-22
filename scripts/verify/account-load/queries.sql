-- queries.sql
-- Hot queries from the osionos bridge, exactly as issued (PostgREST filters translated to SQL).
-- Each query preceded by: -- QUERY: <id>
-- Bridge file:line cited in comment above each.
-- UUIDs are the deterministic md5('user-N') values from seed-10k.sql.

-- Known user UUIDs (md5('user-N') for N in 1,100,1000,5000,9999):
-- user1    = d6d77053-92bc-7af6-3332-8bea8c4c6904
-- user100  = ebb4bc01-7f24-c8dd-c7e6-2cd972adcc61
-- user1000 = d51aafc7-f082-03a1-6a05-cb5d2cc71824
-- user5000 = 151be6ec-b3ad-c263-e4ca-fc267a98d04e
-- user9999 = 592298ec-9e05-5baf-586b-bc439cd8f0a8
-- workspace1 = 668953d2-25f2-b4fd-7d72-1e8cf024a277
-- page1     = 30bc93c6-e5fb-81fc-8947-80d053feff40

-- ============================================================
-- directory_search
-- bridge-social.mjs:70-72 — rest(config, fetchImpl, 'osionos_people_directory?select=user_id,display_name,username,profile,last_seen_at,directory_opt_out&order=display_name.asc&limit=200')
--   With fuzzy filter from bridge-social-core.mjs:209-224 for q="user":
--   &or=(display_name.ilike.*user*,username.ilike.*user*,profile->>headline.ilike.*user*,display_name.ilike.*use*,username.ilike.*use*,search_doc.wfts(simple).user)
--   And directory_opt_out=not.eq.true → NOT (directory_opt_out = true)
-- QUERY: directory_search
SELECT user_id, display_name, username, profile, last_seen_at, directory_opt_out
FROM public.osionos_people_directory
WHERE NOT (directory_opt_out = true)
  AND (
    display_name ILIKE '%user%' OR
    username ILIKE '%user%' OR
    profile->>'headline' ILIKE '%user%' OR
    display_name ILIKE '%use%' OR
    username ILIKE '%use%' OR
    search_doc @@ websearch_to_tsquery('simple', 'user')
  )
ORDER BY display_name ASC
LIMIT 200;

-- ============================================================
-- directory_by_ids (50 ids)
-- bridge-social-core.mjs:390 — identitySummaries uses:
--   rest(config, fetchImpl, 'osionos_people_directory?user_id=in.(ids...)&select=user_id,display_name,profile,last_seen_at')
-- 50 literal UUIDs: the 5 known users + 45 more (users 6-50)
-- QUERY: directory_by_ids
SELECT user_id, display_name, profile, last_seen_at
FROM public.osionos_people_directory
WHERE user_id IN (
    'd6d77053-92bc-7af6-3332-8bea8c4c6904',
    'ebb4bc01-7f24-c8dd-c7e6-2cd972adcc61',
    'd51aafc7-f082-03a1-6a05-cb5d2cc71824',
    '151be6ec-b3ad-c263-e4ca-fc267a98d04e',
    '592298ec-9e05-5baf-586b-bc439cd8f0a8',
    '523d9e31-5b8a-fbee-39be-392d0cffd8b3',
    '40ca0979-0c31-c57a-e9b4-68903f6cd580',
    'c17d3a58-3c65-5a54-16f6-cd42c532cf2a',
    'ab1cce36-e215-8608-a0fd-3d52c1038688',
    'a6e3db59-4a11-c15c-50cd-27d518202c88',
    'b762295c-91f4-e49f-2b04-28a73708b18a',
    'e62b8bcc-21d7-cf37-a1ab-f477863b0bd4',
    '13ca05f7-945e-7659-a51d-a6abfd2eddac',
    'df3c6ecc-3336-fd23-0a18-315cbb3fc6d6',
    'e0b4341c-457b-d9b6-bf43-815ace7f5bae',
    'ce594d95-7058-b2bc-7fce-448aea1007f0',
    '62ba5332-09fd-a25d-4b0d-5e5e2151a0b2',
    '681be464-db0d-3e82-3c34-96d95c9b3897',
    '46d82946-67be-1568-9d0c-9e0e09161a1e',
    '3ff24f82-23a7-fed3-3613-2bb25ec3313e',
    '46199f9d-ae2b-7e3c-1269-b52940d1f53a',
    'bc12fcb3-aa7b-57df-090e-f11e52283fff',
    '65aa74dd-0189-23af-1461-5ba8e8a35b0b',
    '4380da81-0d87-47b2-4ae7-03f6c640cff0',
    '1ec8e757-0a09-07e2-8b30-50f5710f9221',
    '9fc89575-150c-8f1f-5db3-dce52957a7e2',
    'ca20996b-e248-d807-5f0a-21a6bb54c333',
    '27c9af56-9162-8266-121c-2bb6622eb745',
    'bb71f93d-1dc7-be41-ccf2-fd15209e2d0b',
    '8326dcfc-4535-76ab-dcc8-2a88c7303333',
    '3289f079-a59d-e711-e279-0f8c8d8e65c9',
    '56859f9d-389e-a6e2-a24d-679456dc22a4',
    '169066d1-4f4c-f996-9246-752240297e79',
    '4445b069-56a0-ec47-a272-456a5a955c1f',
    'ffa180b5-fad4-1fa7-e54b-c26fc4f0c9f4',
    '3a2b1469-893b-e8da-4ae2-9c91803851de',
    '972912c0-6d5e-0d8c-3c59-4c6ed911e557',
    'dd261e04-3c0c-c9fb-45af-ac85e01182be',
    '69e45b12-e772-41dc-18a6-1bcb31afc172',
    'c2cd5ffd-bdd0-c447-d874-59fb7adae788',
    '03b39f7a-b9f3-c79f-e931-2517e9b69da3',
    '7631bc07-a1cc-8fcd-56e7-0fc6b2fb4a43',
    '601e01f3-0777-a5db-3cbe-23e80670b9da',
    'b7bba9bd-a759-6596-ddc5-f2b1b66a92c6',
    'cc912de8-5a57-3961-2627-c9ac6cd06df4',
    'd8f68423-ee95-128e-b870-e6a1eb484001',
    '659636f0-008e-11db-d77c-33779fc925a1',
    '2dd33dff-0a0f-5b8e-e610-d0764b4ae49f',
    'bc8435b4-a192-222c-d55a-1f39e4ebb9c2',
    'a39eedb1-50d3-045d-edaf-804199d419b2',
    'd7b8751e-1abb-fe2d-1726-d2d1e503b331',
    'a6d8d5a8-c072-3ffe-8ca8-2fcbcf22706d',
    'ffc2e1ea-d1d6-5a82-05ef-a7ddb11ed4a0',
    '69b52f6d-91b6-5e17-ef2b-de0cff585473',
    '06ab5541-ed17-898c-1c83-b3dc1fb68271'
);

-- ============================================================
-- colleague_join_200
-- The join the colleague-edges trigger answers: one member joins a workspace
-- that holds 199 members, and the trigger writes 199 colleague edges in the
-- same transaction (the trigger's own cap is 200 members, so one join stays at
-- 199 inserts — models/osionos-social-scale-migration.sql).
-- The workspace is DEDICATED to this measurement: the CTEs below create it and
-- hold 170 members, so the harness's 30 runs (30 joins, one member each) end at
-- exactly 200 members and every run stays in the <= 200 branch. Each run
-- inserts a member that is not in the workspace yet (a fresh uuid), so the join
-- is never a duplicate and the trigger always has peers to pair.
-- The statements after the measured one seed the feed tables the next query
-- measures and ANALYZE them: the 10K seed leaves osionos_feed_likes and
-- osionos_feed_comments empty, and an empty table is cheaper to read
-- sequentially, so the no_seq_scan budget of feed_page_counts would measure
-- nothing. The files are measured in name order, so this runs before
-- feed_page_counts, and the ANALYZE gives the planner the row counts.
-- QUERY: colleague_join_200
WITH workspace AS (
    INSERT INTO public.osionos_workspaces (id, owner_id, name, slug)
    VALUES ('0a5a0000-0000-4000-8000-000000000001',
            '0a5a0000-0000-4000-8000-0000000000ff',
            'P0-5a colleague scale',
            'p0-5a-colleague-scale')
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name
    RETURNING id
), seeded AS (
    INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions)
    SELECT w.id, gen_random_uuid(), 'viewer', ARRAY['read']
      FROM workspace w, generate_series(1, 170) g
     WHERE (SELECT count(*) FROM public.osionos_workspace_members m WHERE m.workspace_id = w.id) < 170
    RETURNING 1
)
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions)
SELECT w.id, gen_random_uuid(), 'viewer', ARRAY['read']
  FROM workspace w, (SELECT count(*) FROM seeded) s;
-- The feed tables the next query measures. The rows are spread over 5 000
-- pages (page-1 among them) so the filter on one page stays selective: a
-- table whose every row matches one page is cheaper to read sequentially, and
-- the no_seq_scan budget would measure nothing.
INSERT INTO public.osionos_feed_likes (page_id, user_id)
SELECT md5(('page-' || p::text))::uuid, gen_random_uuid()
  FROM generate_series(1, 5000) p
 WHERE NOT EXISTS (SELECT 1 FROM public.osionos_feed_likes WHERE page_id = '30bc93c6-e5fb-81fc-8947-80d053feff40');
INSERT INTO public.osionos_feed_comments (page_id, author_id, content)
SELECT md5(('page-' || p::text))::uuid, gen_random_uuid(), 'seed comment'
  FROM generate_series(1, 5000) p
 WHERE NOT EXISTS (SELECT 1 FROM public.osionos_feed_comments WHERE page_id = '30bc93c6-e5fb-81fc-8947-80d053feff40');
ANALYZE public.osionos_feed_likes, public.osionos_feed_comments;

-- ============================================================
-- colleague_join_200_edges
-- The invariant the measured join must keep: every pair of the dedicated
-- workspace's members has a colleague edge. A join that the trigger SKIPPED
-- (the 200-member cap) would leave the count short of C(n,2), and this query
-- fails on it — the divisor is 0 at RUN time, not a folded constant, so the
-- query only fails when the invariant is broken.
-- QUERY: colleague_join_200_edges
SELECT 1 / (CASE WHEN
         (SELECT count(*)
            FROM public.osionos_connections c
           WHERE c.requester_id IN (SELECT user_id FROM public.osionos_workspace_members
                                     WHERE workspace_id = '0a5a0000-0000-4000-8000-000000000001')
             AND c.addressee_id IN (SELECT user_id FROM public.osionos_workspace_members
                                     WHERE workspace_id = '0a5a0000-0000-4000-8000-000000000001'))
       = (SELECT n * (n - 1) / 2 FROM (SELECT count(*) AS n
                                        FROM public.osionos_workspace_members
                                       WHERE workspace_id = '0a5a0000-0000-4000-8000-000000000001') t)
       THEN 1 ELSE 0 END) AS every_pair_has_an_edge;

-- ============================================================
-- feed_page_counts
-- bridge-feed.mjs:145-153 (likes), :174-180 (the comment count) and :307-309
-- (shares) read three tables per post card and counted the rows in JS. The
-- one-call replacement is public.osionos_feed_page_counts(page, viewer): three
-- counts and one "did the viewer like it" filter, each served by an index on
-- page_id.
-- QUERY: feed_page_counts
SELECT likes, liked_by_viewer, comments, shares
FROM public.osionos_feed_page_counts(
    '30bc93c6-e5fb-81fc-8947-80d053feff40',
    'd6d77053-92bc-7af6-3332-8bea8c4c6904'
);

-- ============================================================
-- identity_by_email_hash
-- bridge-api.mjs:1520 — email_hash lookup with select=is_admin&limit=1:
--   baasRest(config, fetchImpl, `osionos_bridge_identities?email_hash=eq.${hash}&select=is_admin&limit=1`)
-- Test query: lookup by email_hash for user 1 (md5('email-hash-1'))
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
WHERE user_id = 'd6d77053-92bc-7af6-3332-8bea8c4c6904'
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
WHERE requester_id = 'd6d77053-92bc-7af6-3332-8bea8c4c6904'
   OR addressee_id = 'd6d77053-92bc-7af6-3332-8bea8c4c6904'
ORDER BY created_at DESC;

-- ============================================================
-- workspace_members_of_large_workspace
-- bridge-social-core.mjs:236-244 — coMemberPath(userId) uses:
--   osionos_workspace_members?user_id=eq.{userId}&select=user_id,workspace_id,workspace:osionos_workspaces!workspace_id(members:osionos_workspace_members!workspace_id(user_id))
--   with limits 200 workspaces, 500 members per workspace
-- Measures coMemberPath shape: anchor on caller's user_id, join caller's workspaces
-- and their other members (member.user_id <> caller), with bridge limits.
-- QUERY: workspace_members_of_large_workspace
SELECT wm.user_id, wm.workspace_id,
       w.id, w.owner_id, w.name, w.slug, w.settings, w.created_at, w.updated_at,
       m.user_id AS member_user_id
FROM (
    SELECT user_id, workspace_id
    FROM public.osionos_workspace_members
    WHERE user_id = 'd6d77053-92bc-7af6-3332-8bea8c4c6904'
    LIMIT 200
) wm
LEFT JOIN LATERAL (
    SELECT id, owner_id, name, slug, settings, created_at, updated_at
    FROM public.osionos_workspaces w
    WHERE w.id = wm.workspace_id
) w ON true
LEFT JOIN LATERAL (
    SELECT m.user_id
    FROM public.osionos_workspace_members m
    WHERE m.workspace_id = wm.workspace_id
      AND m.user_id <> 'd6d77053-92bc-7af6-3332-8bea8c4c6904'
    LIMIT 500
) m ON true;

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
WHERE p.id = '30bc93c6-e5fb-81fc-8947-80d053feff40'
  AND wm.user_id = 'd6d77053-92bc-7af6-3332-8bea8c4c6904'
LIMIT 1;

-- ============================================================
-- p1_directory_search_common
-- bridge-social-core.mjs:209-224 — directoryFuzzyFilter, the shape P1-2 will
-- send: the three ILIKE arms and the two stem arms (q is 4 characters or more,
-- so the stem still has the 3 characters a trigram index needs), over the
-- profile's OWN headline column — never profile->>'headline', which no index
-- can serve — plus the full-text arm.
--   &or=(display_name.ilike.*user*,username.ilike.*user*,headline.ilike.*user*,
--        display_name.ilike.*use*,username.ilike.*use*,search_doc.wfts(simple).user)
--   &directory_opt_out=not.eq.true
-- The term matches every seeded user, so the plan walks the display_name
-- index in order and stops at the limit.
-- QUERY: p1_directory_search_common
SELECT user_id, display_name, username, profile, last_seen_at, directory_opt_out
FROM public.osionos_people_directory
WHERE NOT (directory_opt_out = true)
  AND (
    display_name ILIKE '%user%' OR
    username ILIKE '%user%' OR
    headline ILIKE '%user%' OR
    display_name ILIKE '%use%' OR
    username ILIKE '%use%' OR
    search_doc @@ websearch_to_tsquery('simple', 'user')
  )
ORDER BY display_name ASC
LIMIT 200;

-- ============================================================
-- p1_directory_search_rare
-- The same shape, a term that matches two of the seeded users: "User 10000"
-- through the full arm and "User 1000" through the stem arm.
-- It exists to prove the plan reaches the GIN indexes: a btree walk that
-- removes 4001 rows would pass a no-seq-scan budget in O(N), and this term
-- must come back as a Bitmap Index Scan.
-- QUERY: p1_directory_search_rare
SELECT user_id, display_name, username, profile, last_seen_at, directory_opt_out
FROM public.osionos_people_directory
WHERE NOT (directory_opt_out = true)
  AND (
    display_name ILIKE '%user 10000%' OR
    username ILIKE '%user 10000%' OR
    headline ILIKE '%user 10000%' OR
    display_name ILIKE '%user 1000%' OR
    username ILIKE '%user 1000%' OR
    search_doc @@ websearch_to_tsquery('simple', 'user 10000')
  )
ORDER BY display_name ASC
LIMIT 200;

-- ============================================================
-- p1_directory_by_ids
-- bridge-social-core.mjs:390 — identitySummaries, the shape P1-2 will send:
--   osionos_people_directory?user_id=in.(ids...)&select=user_id,display_name,profile,last_seen_at
-- The same 50 literal ids as directory_by_ids: the directory is now a view
-- over osionos_profiles, so the lookup must not scan it.
-- QUERY: p1_directory_by_ids
SELECT user_id, display_name, profile, last_seen_at
FROM public.osionos_people_directory
WHERE user_id IN (
    'd6d77053-92bc-7af6-3332-8bea8c4c6904',
    'ebb4bc01-7f24-c8dd-c7e6-2cd972adcc61',
    'd51aafc7-f082-03a1-6a05-cb5d2cc71824',
    '151be6ec-b3ad-c263-e4ca-fc267a98d04e',
    '592298ec-9e05-5baf-586b-bc439cd8f0a8',
    '523d9e31-5b8a-fbee-39be-392d0cffd8b3',
    '40ca0979-0c31-c57a-e9b4-68903f6cd580',
    'c17d3a58-3c65-5a54-16f6-cd42c532cf2a',
    'ab1cce36-e215-8608-a0fd-3d52c1038688',
    'a6e3db59-4a11-c15c-50cd-27d518202c88',
    'b762295c-91f4-e49f-2b04-28a73708b18a',
    'e62b8bcc-21d7-cf37-a1ab-f477863b0bd4',
    '13ca05f7-945e-7659-a51d-a6abfd2eddac',
    'df3c6ecc-3336-fd23-0a18-315cbb3fc6d6',
    'e0b4341c-457b-d9b6-bf43-815ace7f5bae',
    'ce594d95-7058-b2bc-7fce-448aea1007f0',
    '62ba5332-09fd-a25d-4b0d-5e5e2151a0b2',
    '681be464-db0d-3e82-3c34-96d95c9b3897',
    '46d82946-67be-1568-9d0c-9e0e09161a1e',
    '3ff24f82-23a7-fed3-3613-2bb25ec3313e',
    '46199f9d-ae2b-7e3c-1269-b52940d1f53a',
    'bc12fcb3-aa7b-57df-090e-f11e52283fff',
    '65aa74dd-0189-23af-1461-5ba8e8a35b0b',
    '4380da81-0d87-47b2-4ae7-03f6c640cff0',
    '1ec8e757-0a09-07e2-8b30-50f5710f9221',
    '9fc89575-150c-8f1f-5db3-dce52957a7e2',
    'ca20996b-e248-d807-5f0a-21a6bb54c333',
    '27c9af56-9162-8266-121c-2bb6622eb745',
    'bb71f93d-1dc7-be41-ccf2-fd15209e2d0b',
    '8326dcfc-4535-76ab-dcc8-2a88c7303333',
    '3289f079-a59d-e711-e279-0f8c8d8e65c9',
    '56859f9d-389e-a6e2-a24d-679456dc22a4',
    '169066d1-4f4c-f996-9246-752240297e79',
    '4445b069-56a0-ec47-a272-456a5a955c1f',
    'ffa180b5-fad4-1fa7-e54b-c26fc4f0c9f4',
    '3a2b1469-893b-e8da-4ae2-9c91803851de',
    '972912c0-6d5e-0d8c-3c59-4c6ed911e557',
    'dd261e04-3c0c-c9fb-45af-ac85e01182be',
    '69e45b12-e772-41dc-18a6-1bcb31afc172',
    'c2cd5ffd-bdd0-c447-d874-59fb7adae788',
    '03b39f7a-b9f3-c79f-e931-2517e9b69da3',
    '7631bc07-a1cc-8fcd-56e7-0fc6b2fb4a43',
    '601e01f3-0777-a5db-3cbe-23e80670b9da',
    'b7bba9bd-a759-6596-ddc5-f2b1b66a92c6',
    'cc912de8-5a57-3961-2627-c9ac6cd06df4',
    'd8f68423-ee95-128e-b870-e6a1eb484001',
    '659636f0-008e-11db-d77c-33779fc925a1',
    '2dd33dff-0a0f-5b8e-e610-d0764b4ae49f',
    'bc8435b4-a192-222c-d55a-1f39e4ebb9c2',
    'a39eedb1-50d3-045d-edaf-804199d419b2',
    'd7b8751e-1abb-fe2d-1726-d2d1e503b331',
    'a6d8d5a8-c072-3ffe-8ca8-2fcbcf22706d',
    'ffc2e1ea-d1d6-5a82-05ef-a7ddb11ed4a0',
    '69b52f6d-91b6-5e17-ef2b-de0cff585473',
    '06ab5541-ed17-898c-1c83-b3dc1fb68271'
);