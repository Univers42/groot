-- The slice of baas's platform database that vm-bootstrap.sh reads and writes, with the same
-- keys and uniqueness (models/osionos-bridge-migration.sql:28-47,
-- models/osionos-workspace-databases-migration.sql:18-29, adapter-registry schema.go:30-40).
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text UNIQUE NOT NULL);
REVOKE ALL ON SCHEMA auth FROM PUBLIC;
CREATE TABLE public.tenants (id text PRIMARY KEY);
CREATE TABLE public.tenant_databases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id text NOT NULL,
  engine text NOT NULL,
  name text NOT NULL,
  connection_string text NOT NULL,
  UNIQUE (tenant_id, name)
);
CREATE TABLE public.osionos_workspaces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL,
  name text NOT NULL,
  slug text NOT NULL UNIQUE,
  source text NOT NULL DEFAULT 'bridge'
);
CREATE TABLE public.osionos_workspace_members (
  workspace_id uuid NOT NULL REFERENCES public.osionos_workspaces (id),
  user_id uuid NOT NULL,
  role text NOT NULL CHECK (role IN ('owner', 'admin', 'editor', 'viewer')),
  permissions text[] NOT NULL DEFAULT '{read}',
  PRIMARY KEY (workspace_id, user_id)
);
CREATE TABLE public.osionos_workspace_databases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.osionos_workspaces (id),
  db_id text NOT NULL,
  engine text NOT NULL,
  tables text[] NOT NULL DEFAULT '{}',
  label text,
  UNIQUE (workspace_id, db_id)
);
CREATE TABLE public.osionos_pages (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), title text);
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;

-- Someone else's rows, which the run must leave in place.
INSERT INTO auth.users (email) VALUES ('someone@else.test');
INSERT INTO public.tenants VALUES ('agency'), ('other');
INSERT INTO public.tenant_databases (tenant_id, engine, name, connection_string)
VALUES ('agency', 'postgresql', 'osionos-crm', 'postgres://x:y@postgres/z');
INSERT INTO public.osionos_workspaces (owner_id, name, slug) VALUES (gen_random_uuid(), 'Someone', 'someone');
INSERT INTO public.osionos_pages (title) VALUES ('a page that is not ours');
