-- The rollback of models/osionos-chat-ai-autopost-migration.sql (osio bot
-- Phase 1a, the per-channel auto-post opt-in).
--
-- THE RUNNER NEVER PICKS THIS FILE UP
--   The runner's glob is "${MODELS_DIR}"/*.sql and this file lives in the
--   models/rollback/ subdirectory, which that glob does not reach. A rollback is
--   run by hand, by the deploy owner.
--
-- IDEMPOTENT: IF EXISTS shaped, so it can be applied twice.
--
-- WHAT A ROLLBACK COSTS
--   Every channel's opt-in is forgotten; the bridge reads the missing column as
--   off, so every channel is back to the asker's click. Posted answers stay.

SET lock_timeout = '5s';

ALTER TABLE public.osionos_channels DROP COLUMN IF EXISTS ai_autopost;
