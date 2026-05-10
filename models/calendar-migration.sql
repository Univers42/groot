-- BaaS mirror tables for osionos Calendar provider data.
-- The bridge writes with the service role; frontend clients should not receive raw provider payloads directly.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.calendar_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL CHECK (provider IN ('google', 'outlook', 'caldav', 'local')),
  account_email TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (provider, account_email)
);

CREATE TABLE IF NOT EXISTS public.calendar_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.calendar_accounts(id) ON DELETE CASCADE,
  provider_calendar_id TEXT NOT NULL,
  name TEXT NOT NULL,
  color TEXT NOT NULL DEFAULT '#de5550',
  timezone TEXT NOT NULL DEFAULT 'UTC',
  is_visible BOOLEAN NOT NULL DEFAULT true,
  is_primary BOOLEAN NOT NULL DEFAULT false,
  access_role TEXT NOT NULL DEFAULT '',
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, provider_calendar_id)
);

CREATE TABLE IF NOT EXISTS public.calendar_event_cache (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id UUID NOT NULL REFERENCES public.calendar_sources(id) ON DELETE CASCADE,
  provider_event_id TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  location TEXT NOT NULL DEFAULT '',
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  all_day BOOLEAN NOT NULL DEFAULT false,
  status TEXT NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'tentative', 'cancelled')),
  visibility TEXT NOT NULL DEFAULT 'default' CHECK (visibility IN ('default', 'public', 'private')),
  busy_status TEXT NOT NULL DEFAULT 'busy' CHECK (busy_status IN ('busy', 'free')),
  attendees JSONB NOT NULL DEFAULT '[]'::jsonb,
  conferencing JSONB NOT NULL DEFAULT '{}'::jsonb,
  recurrence TEXT NOT NULL DEFAULT 'none',
  source_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source_id, provider_event_id)
);

CREATE INDEX IF NOT EXISTS calendar_sources_account_idx ON public.calendar_sources(account_id);
CREATE INDEX IF NOT EXISTS calendar_event_cache_source_idx ON public.calendar_event_cache(source_id);
CREATE INDEX IF NOT EXISTS calendar_event_cache_range_idx ON public.calendar_event_cache(starts_at, ends_at);
CREATE INDEX IF NOT EXISTS calendar_event_cache_payload_idx ON public.calendar_event_cache USING GIN (source_payload);

ALTER TABLE public.calendar_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_event_cache ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS calendar_accounts_no_public_access ON public.calendar_accounts;
CREATE POLICY calendar_accounts_no_public_access ON public.calendar_accounts FOR SELECT TO authenticated USING (false);

DROP POLICY IF EXISTS calendar_sources_no_public_access ON public.calendar_sources;
CREATE POLICY calendar_sources_no_public_access ON public.calendar_sources FOR SELECT TO authenticated USING (false);

DROP POLICY IF EXISTS calendar_event_cache_no_public_access ON public.calendar_event_cache;
CREATE POLICY calendar_event_cache_no_public_access ON public.calendar_event_cache FOR SELECT TO authenticated USING (false);

REVOKE ALL ON public.calendar_accounts FROM anon, authenticated;
REVOKE ALL ON public.calendar_sources FROM anon, authenticated;
REVOKE ALL ON public.calendar_event_cache FROM anon, authenticated;
GRANT ALL ON public.calendar_accounts TO service_role;
GRANT ALL ON public.calendar_sources TO service_role;
GRANT ALL ON public.calendar_event_cache TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;