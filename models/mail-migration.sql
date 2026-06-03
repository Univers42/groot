-- BaaS mirror tables for osionos Mail (Gmail) provider data.
-- The bridge writes with the service role; frontend clients must not receive raw provider
-- payloads directly. Modeled on models/calendar-migration.sql (incl. the service_role RLS
-- policies that calendar originally missed — service_role does NOT bypass RLS here).
BEGIN;

CREATE TABLE IF NOT EXISTS public.mail_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL CHECK (provider IN ('gmail', 'outlook', 'imap')),
  account_email TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (provider, account_email)
);

CREATE TABLE IF NOT EXISTS public.mail_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.mail_accounts(id) ON DELETE CASCADE,
  provider_message_id TEXT NOT NULL,
  thread_id TEXT NOT NULL DEFAULT '',
  subject TEXT NOT NULL DEFAULT '',
  from_name TEXT NOT NULL DEFAULT '',
  from_email TEXT NOT NULL DEFAULT '',
  to_addrs JSONB NOT NULL DEFAULT '[]'::jsonb,
  cc_addrs JSONB NOT NULL DEFAULT '[]'::jsonb,
  bcc_addrs JSONB NOT NULL DEFAULT '[]'::jsonb,
  snippet TEXT NOT NULL DEFAULT '',
  mailbox TEXT NOT NULL DEFAULT '',
  labels JSONB NOT NULL DEFAULT '[]'::jsonb,
  category TEXT NOT NULL DEFAULT '',
  priority TEXT NOT NULL DEFAULT 'normal',
  is_unread BOOLEAN NOT NULL DEFAULT false,
  is_starred BOOLEAN NOT NULL DEFAULT false,
  is_important BOOLEAN NOT NULL DEFAULT false,
  is_sent BOOLEAN NOT NULL DEFAULT false,
  is_archived BOOLEAN NOT NULL DEFAULT false,
  has_attachments BOOLEAN NOT NULL DEFAULT false,
  received_at TIMESTAMPTZ NOT NULL,
  source_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, provider_message_id)
);

CREATE INDEX IF NOT EXISTS mail_messages_account_idx ON public.mail_messages(account_id);
CREATE INDEX IF NOT EXISTS mail_messages_received_idx ON public.mail_messages(received_at DESC);
CREATE INDEX IF NOT EXISTS mail_messages_thread_idx ON public.mail_messages(thread_id);
CREATE INDEX IF NOT EXISTS mail_messages_labels_idx ON public.mail_messages USING GIN (labels);

ALTER TABLE public.mail_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mail_messages ENABLE ROW LEVEL SECURITY;

-- No public access: these caches hold message metadata/snippets (PII).
DROP POLICY IF EXISTS mail_accounts_no_public_access ON public.mail_accounts;
CREATE POLICY mail_accounts_no_public_access ON public.mail_accounts FOR SELECT TO anon, authenticated USING (false);
DROP POLICY IF EXISTS mail_messages_no_public_access ON public.mail_messages;
CREATE POLICY mail_messages_no_public_access ON public.mail_messages FOR SELECT TO anon, authenticated USING (false);

-- The bridge reads/writes with the service role, which does NOT bypass RLS in this BaaS,
-- so an explicit allow-all policy is REQUIRED — without it every mirror upsert 403s.
DROP POLICY IF EXISTS mail_accounts_service_role_all ON public.mail_accounts;
CREATE POLICY mail_accounts_service_role_all ON public.mail_accounts FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS mail_messages_service_role_all ON public.mail_messages;
CREATE POLICY mail_messages_service_role_all ON public.mail_messages FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL ON public.mail_accounts FROM anon, authenticated;
REVOKE ALL ON public.mail_messages FROM anon, authenticated;
GRANT ALL ON public.mail_accounts TO service_role;
GRANT ALL ON public.mail_messages TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
