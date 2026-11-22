-- osionos-chat-ai-autopost-migration.sql — the per-channel opt-in for osio
-- auto-posting "@ai" answers (osio bot Phase 1a, ruling OB2). In a channel with
-- ai_autopost on, the asker's client posts the answer through the existing
-- POST /api/chat/channels/:id/ai-answers route when the private draft is ready;
-- every guard of that route still applies. Off, the asker clicks Post, as before.
--
-- The flag is a consent knob, not a security boundary: the bridge decides who may
-- set it (a channel admin) and the post route's guards decide what is posted.
-- NOT NULL DEFAULT false: an existing or new channel never auto-posts until an
-- admin turns it on, and a reader never has to interpret NULL.
--
-- WHAT IT ADDS
--   osionos_channels.ai_autopost   boolean NOT NULL DEFAULT false
--
-- ORDER
--   osionos-chat-migration.sql is in ORDERED_FIRST (scripts/apply-models-migrations.sh),
--   so osionos_channels exists here even though "osionos-chat-a" sorts before it.
--
-- WHO REACHES WHAT
--   service_role  the column with the table (GRANT ALL in osionos-chat-migration.sql)
--   anyone else   nothing (osionos-service-role-only-migration.sql)
--
-- DOWN (by hand: models/rollback/osionos-chat-ai-autopost-rollback.sql; the bridge
-- reads a missing column as off)
--   ALTER TABLE public.osionos_channels DROP COLUMN IF EXISTS ai_autopost;

ALTER TABLE public.osionos_channels
  ADD COLUMN IF NOT EXISTS ai_autopost boolean NOT NULL DEFAULT false;
