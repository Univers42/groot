-- ===========================================================================
-- osionos admin migration — account-level administrator, the dedicated admin
-- workspace, per-section template write-grants, and the surface→template tag.
--
-- Additive + idempotent (ADD COLUMN IF NOT EXISTS / CREATE IF NOT EXISTS /
-- ON CONFLICT DO NOTHING), same discipline as the other osionos migrations.
-- Runs AFTER osionos-bridge / osionos-social / osionos-chat (it relies on
-- osionos_bridge_identities + osionos_workspaces existing).
-- ===========================================================================

-- 1. Persisted account-level administrator flag on the bridge identity. The
--    bridge promotes admins (from OSIONOS_ADMIN_EMAILS) at login and reads this
--    back, so admin status survives env changes once set.
ALTER TABLE public.osionos_bridge_identities
  ADD COLUMN IF NOT EXISTS is_admin BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS osionos_bridge_identities_admin_idx
  ON public.osionos_bridge_identities (is_admin) WHERE is_admin;

-- 2. Surface tag on pages: which admin shell a template page authors
--    (profile / marketplace-app). Lets a shell resolve "the template for surface
--    X" instead of a hard-coded id. NULL on ordinary pages.
ALTER TABLE public.osionos_pages
  ADD COLUMN IF NOT EXISTS template_surface TEXT
    CHECK (template_surface IS NULL OR template_surface IN ('profile', 'marketplace-app'));
CREATE INDEX IF NOT EXISTS osionos_pages_template_surface_idx
  ON public.osionos_pages (template_surface) WHERE template_surface IS NOT NULL;

-- 3. The dedicated admin workspace — a real workspace (so templates live in it
--    and reuse the page/ACL plumbing) but source='admin' + visibility kept
--    'confidential' so it never appears in collaboration discovery. Fixed id so
--    the bridge can provision membership + the seed can target it.
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug, source, settings)
VALUES (
  '0a4d1c2e-0000-4000-8000-000000000ad1',
  '0a4d1c2e-0000-4000-8000-00000000000a',
  'osionos Admin',
  'osionos-admin',
  'admin',
  '{"role":"admin","plan":"Admin"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- Keep it out of discovery (visibility column added by osionos-social-migration;
-- guarded so this migration is safe in editions that don't apply social/chat).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'osionos_workspaces' AND column_name = 'visibility'
  ) THEN
    UPDATE public.osionos_workspaces
      SET visibility = 'confidential'
      WHERE id = '0a4d1c2e-0000-4000-8000-000000000ad1' AND visibility <> 'confidential';
  END IF;
END $$;

-- 4. Per-section template write-grants. A template cell carries a `section` key
--    (read-only-canvas model); a grant row widens write access to that section
--    for a specific admin/role. No grant row → only account admins may write.
CREATE TABLE IF NOT EXISTS public.osionos_profile_template_section_grants (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  template_page_id UUID NOT NULL,
  section_key      TEXT NOT NULL,
  principal_type   TEXT NOT NULL CHECK (principal_type IN ('user', 'role')),
  principal_id     TEXT NOT NULL,
  can_write        BOOLEAN NOT NULL DEFAULT true,
  created_by       UUID NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (template_page_id, section_key, principal_type, principal_id)
);
CREATE INDEX IF NOT EXISTS osionos_section_grants_lookup_idx
  ON public.osionos_profile_template_section_grants (template_page_id, section_key);

-- RLS: service_role only (the bridge holds the service key; browsers never touch
-- this table directly), matching the existing bridge trust boundary.
ALTER TABLE public.osionos_profile_template_section_grants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_section_grants_service_all ON public.osionos_profile_template_section_grants;
CREATE POLICY osionos_section_grants_service_all ON public.osionos_profile_template_section_grants
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT ALL ON public.osionos_profile_template_section_grants TO service_role;

-- Refresh PostgREST's schema cache so the new column/table are queryable.
NOTIFY pgrst, 'reload schema';
