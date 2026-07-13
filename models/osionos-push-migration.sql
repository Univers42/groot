-- Web Push subscriptions (RFC 8291). One row per browser push endpoint. Same
-- discipline as osionos-engagement-migration.sql: idempotent DDL, RLS on,
-- own-row SELECT + service_role FOR ALL (the bridge holds the VAPID keys and
-- pushes with the service key; RLS is defence in depth).

CREATE TABLE IF NOT EXISTS public.osionos_push_subscriptions (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL,
  endpoint   TEXT NOT NULL UNIQUE,
  p256dh     TEXT NOT NULL,
  auth       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS osionos_push_subscriptions_user_idx
  ON public.osionos_push_subscriptions (user_id);

ALTER TABLE public.osionos_push_subscriptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_push_subscriptions_select_own ON public.osionos_push_subscriptions;
CREATE POLICY osionos_push_subscriptions_select_own ON public.osionos_push_subscriptions
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS osionos_push_subscriptions_service_role_all ON public.osionos_push_subscriptions;
CREATE POLICY osionos_push_subscriptions_service_role_all ON public.osionos_push_subscriptions
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT SELECT ON public.osionos_push_subscriptions TO authenticated;
GRANT ALL    ON public.osionos_push_subscriptions TO service_role;

NOTIFY pgrst, 'reload schema';
