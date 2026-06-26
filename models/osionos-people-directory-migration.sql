-- osionos-people-directory-migration.sql
-- ---------------------------------------------------------------------------
-- WHY: the osionos "People" panel showed nothing relevant. Its directory /
-- people / connection-name resolution read public.osionos_bridge_identities — a
-- thin local CACHE that only gets a bare row (provider, subject, display_name)
-- the moment someone logs INTO osionos. username/avatar/profile stay NULL and
-- people who never opened osionos are absent → an empty, name-less directory.
--
-- The authoritative user records live in the SHARED grobase tables, written by
-- prismatica's auth-gateway via gotrue:
--   - public.users         : id (uuid = auth.users.id), email, name, username
--   - public.user_profiles : user_id, display_name, avatar_url
--   - public.osionos_bridge_identities : profile->>'headline', last_seen_at,
--                                        directory_opt_out  (osionos-only extras)
-- The id is the SAME uuid the social graph uses (osionos_connections.*_id,
-- osionos_channel_members.user_id, osionos_workspace_members.user_id), so no
-- translation is needed.
--
-- FIX (DB-only, additive, idempotent — NO replication, just authorized read of
-- SAFE fields): a view that exposes the authoritative people with ONLY safe
-- columns — username, name, avatar, headline, online (last_seen_at), opt-out.
-- NEVER email / password_hash / theme / verification flags. The osionos-bridge
-- directory/people/identity handlers repoint their SELECT at this view, so the
-- People panel lights up with the real user base and real names — without ever
-- copying prismatica's data into an osionos table.
--
-- Column shape is kept IDENTICAL to what the bridge already selects from
-- osionos_bridge_identities (user_id, display_name, username, profile,
-- last_seen_at, directory_opt_out, search_doc) so the repoint is a 1-word change
-- and the existing fuzzy filter (display_name/username/profile->>headline ILIKE
-- + search_doc websearch FTS) keeps working.
--
-- ponytail: search_doc is recomputed per row (no stored GIN index like the
-- cache had). Fine for a modest user base + limit 200; promote to a matview or
-- expression index if the directory grows large.
--
-- Safe to run twice. Apply:
--   docker exec -i mini-baas-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     -f - < models/osionos-people-directory-migration.sql
-- Then reload PostgREST so it sees the new view:
--   docker exec -i mini-baas-postgres psql -U postgres -d postgres -c "NOTIFY pgrst, 'reload schema';"
-- ---------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE VIEW public.osionos_people_directory AS
SELECT
  u.id AS user_id,
  -- richest available human name, never the email
  COALESCE(
    NULLIF(btrim(up.display_name), ''),
    NULLIF(btrim(bi.display_name), ''),
    NULLIF(btrim(u.name), ''),
    u.username,
    'Member'
  ) AS display_name,
  COALESCE(u.username, bi.username) AS username,
  -- SAFE subset only: avatar + headline. No email / bio / sensitive metadata.
  jsonb_build_object(
    'avatar', COALESCE(up.avatar_url, bi.profile->>'avatar'),
    'headline', COALESCE(bi.profile->>'headline', '')
  ) AS profile,
  bi.last_seen_at,                                   -- → online presence
  COALESCE(bi.directory_opt_out, false) AS directory_opt_out,
  to_tsvector(
    'simple',
    concat_ws(' ', u.name, u.username, up.display_name, bi.profile->>'headline')
  ) AS search_doc
FROM public.users u
LEFT JOIN public.user_profiles up ON up.user_id = u.id
LEFT JOIN public.osionos_bridge_identities bi ON bi.user_id = u.id;

-- The bridge reads with the service-role key; authenticated kept for parity with
-- public.osionos_directory. The view exposes only the safe columns above.
GRANT SELECT ON public.osionos_people_directory TO authenticated, service_role;

COMMIT;

-- PostgREST must reload its schema cache to expose the new view:
NOTIFY pgrst, 'reload schema';
