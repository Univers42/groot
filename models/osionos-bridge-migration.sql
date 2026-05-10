-- Shared BaaS schema for the Prismatica -> osionos bridge.
-- The browser receives only app-scoped session metadata; this schema keeps the
-- durable identity/workspace mapping inside Postgres behind PostgREST/service-role access.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS auth;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID AS $$
  SELECT (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb->>'sub')::uuid;
$$ LANGUAGE SQL STABLE;

CREATE TABLE IF NOT EXISTS public.osionos_bridge_identities (
  provider TEXT NOT NULL,
  subject UUID NOT NULL,
  user_id UUID NOT NULL,
  email_hash TEXT NOT NULL,
  display_name TEXT NOT NULL,
  private_workspace_id UUID NOT NULL DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, subject),
  UNIQUE (user_id),
  UNIQUE (private_workspace_id)
);

CREATE TABLE IF NOT EXISTS public.osionos_workspaces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID NOT NULL,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  source TEXT NOT NULL DEFAULT 'bridge',
  settings JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.osionos_workspace_members (
  workspace_id UUID NOT NULL REFERENCES public.osionos_workspaces(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'editor', 'viewer')),
  permissions TEXT[] NOT NULL DEFAULT ARRAY['read'],
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.osionos_bridge_audit_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL,
  subject UUID NOT NULL,
  event_type TEXT NOT NULL,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS osionos_workspaces_owner_idx ON public.osionos_workspaces(owner_id);
CREATE INDEX IF NOT EXISTS osionos_workspace_members_user_idx ON public.osionos_workspace_members(user_id);
CREATE INDEX IF NOT EXISTS osionos_bridge_audit_subject_idx ON public.osionos_bridge_audit_events(provider, subject, created_at DESC);

ALTER TABLE public.osionos_bridge_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_workspace_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_bridge_audit_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS osionos_bridge_identities_select_own ON public.osionos_bridge_identities;
CREATE POLICY osionos_bridge_identities_select_own ON public.osionos_bridge_identities
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS osionos_workspaces_select_member ON public.osionos_workspaces;
CREATE POLICY osionos_workspaces_select_member ON public.osionos_workspaces
  FOR SELECT TO authenticated USING (
    owner_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public.osionos_workspace_members member
      WHERE member.workspace_id = id AND member.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS osionos_workspace_members_select_own ON public.osionos_workspace_members;
CREATE POLICY osionos_workspace_members_select_own ON public.osionos_workspace_members
  FOR SELECT TO authenticated USING (user_id = auth.uid());

GRANT SELECT ON public.osionos_bridge_identities TO authenticated;
GRANT SELECT ON public.osionos_workspaces TO authenticated;
GRANT SELECT ON public.osionos_workspace_members TO authenticated;
GRANT ALL ON public.osionos_bridge_identities TO service_role;
GRANT ALL ON public.osionos_workspaces TO service_role;
GRANT ALL ON public.osionos_workspace_members TO service_role;
GRANT ALL ON public.osionos_bridge_audit_events TO service_role;

CREATE OR REPLACE FUNCTION public.osionos_bridge_upsert_workspace(
  p_provider TEXT,
  p_subject UUID,
  p_email_hash TEXT,
  p_display_name TEXT
) RETURNS TABLE (
  user_id UUID,
  workspace_id UUID,
  workspace_name TEXT,
  workspace_slug TEXT,
  workspace_role TEXT,
  permissions TEXT[]
) AS $$
DECLARE
  v_display_name TEXT := LEFT(NULLIF(BTRIM(p_display_name), ''), 80);
  v_workspace_id UUID;
  v_workspace_name TEXT;
  v_workspace_slug TEXT;
  v_permissions TEXT[] := ARRAY['create', 'read', 'update', 'delete', 'admin'];
  v_role_id UUID;
BEGIN
  IF p_provider <> 'prismatica' THEN
    RAISE EXCEPTION 'unsupported bridge provider';
  END IF;

  v_display_name := COALESCE(v_display_name, 'osionos owner');

  INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name)
  VALUES (p_provider, p_subject, p_subject, p_email_hash, v_display_name)
  ON CONFLICT (provider, subject) DO UPDATE SET
    email_hash = EXCLUDED.email_hash,
    display_name = EXCLUDED.display_name,
    updated_at = now(),
    last_seen_at = now()
  RETURNING private_workspace_id INTO v_workspace_id;

  v_workspace_name := v_display_name || '''s osionos';
  v_workspace_slug := lower(regexp_replace(v_workspace_name, '[^a-zA-Z0-9]+', '-', 'g'));
  v_workspace_slug := trim(both '-' from v_workspace_slug) || '-' || left(p_subject::text, 8);

  INSERT INTO public.osionos_workspaces (id, owner_id, name, slug, source, settings)
  VALUES (
    v_workspace_id,
    p_subject,
    v_workspace_name,
    v_workspace_slug,
    'bridge',
    jsonb_build_object('bridgeProvider', p_provider, 'role', 'owner', 'permissions', v_permissions)
  )
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    slug = EXCLUDED.slug,
    settings = EXCLUDED.settings,
    updated_at = now();

  INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions)
  VALUES (v_workspace_id, p_subject, 'owner', v_permissions)
  ON CONFLICT ON CONSTRAINT osionos_workspace_members_pkey DO UPDATE SET
    role = 'owner',
    permissions = v_permissions,
    updated_at = now();

  IF to_regclass('public.roles') IS NOT NULL
    AND to_regclass('public.user_roles') IS NOT NULL
    AND to_regclass('public.resource_policies') IS NOT NULL THEN
    INSERT INTO public.roles (name, description, is_system, metadata)
    VALUES ('osionos_owner', 'Owner of a bridged osionos workspace', true, jsonb_build_object('app', 'osionos'))
    ON CONFLICT (name) DO UPDATE SET updated_at = now()
    RETURNING id INTO v_role_id;

    INSERT INTO public.user_roles (user_id, role_id)
    VALUES (p_subject, v_role_id)
    ON CONFLICT (user_id, role_id) DO NOTHING;

    INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
    SELECT
      v_role_id,
      'osionos_workspace',
      v_workspace_id::text,
      ARRAY['create', 'read', 'update', 'delete', 'admin'],
      jsonb_build_object('owner_id', p_subject),
      'allow',
      200
    WHERE NOT EXISTS (
      SELECT 1 FROM public.resource_policies
      WHERE role_id = v_role_id
        AND resource_type = 'osionos_workspace'
        AND resource_name = v_workspace_id::text
    );
  END IF;

  INSERT INTO public.osionos_bridge_audit_events (provider, subject, event_type, details)
  VALUES (p_provider, p_subject, 'bridge_workspace_upserted', jsonb_build_object('workspace_id', v_workspace_id));

  RETURN QUERY SELECT p_subject, v_workspace_id, v_workspace_name, v_workspace_slug, 'owner'::TEXT, v_permissions;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.osionos_bridge_upsert_workspace(TEXT, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_bridge_upsert_workspace(TEXT, UUID, TEXT, TEXT) TO service_role;

NOTIFY pgrst, 'reload schema';