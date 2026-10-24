-- The old-shape audit table (integer user_id) an upgraded install carries, with the blanket grant
-- an old bootstrap left on it. The migration must move it aside and close it to anon/authenticated.
CREATE TABLE public.auth_audit_events (
  id BIGSERIAL PRIMARY KEY,
  event_type VARCHAR(64) NOT NULL,
  user_id INTEGER NULL,
  email VARCHAR(255),
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO public.auth_audit_events (event_type, user_id) VALUES ('login_success', 7), ('logout', 7);
GRANT ALL ON public.auth_audit_events TO anon, authenticated;
