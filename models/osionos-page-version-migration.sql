-- AI-P4b-1a — a page's content carries a version, and blocks can be appended atomically.
--
-- WHY
--   A page's content is ONE jsonb array of blocks and every writer replaces the
--   whole array (the bridge's PATCH: assignPayloadValue(row, payload, 'content', ...),
--   osionos bridge-api.mjs:765). Two writers therefore erase each other: the last
--   whole-array write wins, the other's blocks are gone, and the row keeps no trace
--   that it happened. This file gives the content a version — so a writer can tell
--   that the server copy moved — and adds ONE server-side append, so a writer can
--   add blocks without reading the page first.
--
-- WHAT
--   1. public.osionos_pages.version bigint NOT NULL DEFAULT 0 — a CONTENT version.
--   2. A BEFORE UPDATE trigger that owns it: a writer can never set it from a payload.
--   3. public.osionos_page_append(...) — the atomic append, reached over RPC.
--   4. public.osionos_page_append_keys — the idempotency ledger (C21).
--
-- TRIGGER ORDER ON public.osionos_pages
--   PostgreSQL runs every BEFORE trigger before every AFTER trigger, and inside one
--   group in trigger-name order. The order on this table is therefore:
--     BEFORE UPDATE  osionos_pages_version_trg      <- this file: FIRST
--     AFTER  INSERT  ai_enqueue_page_ins
--     AFTER  UPDATE  ai_enqueue_page_upd
--     AFTER  UPDATE  ai_sync_page_acl_trg
--     AFTER  UPDATE  osionos_pages_links_trg
--     AFTER  UPDATE  osionos_pages_tasks_trg
--     AFTER  DELETE  ai_delete_page_chunks_trg
--   The version must be settled BEFORE the after-triggers read the row: the index
--   enqueue (ai_enqueue_page_upd) fires on a content change and is what tells the
--   indexer the page moved. A BEFORE trigger is the only place the version can be
--   settled in time, and it is the only trigger this file adds.
--
-- WHY THE VERSION IS A CONTENT VERSION, NOT A ROW VERSION (C15)
--   The predicate is the one this tree already uses for the same purpose
--   (models/osionos-ai-rag-migration.sql:249-252): OLD.content IS DISTINCT FROM
--   NEW.content. Four production writers never touch content — the archive cascade,
--   the record-note refresh, the marketplace publish and the marketplace app-patch —
--   and the archive cascade writes a whole subtree. A row version would bump on
--   those and turn every open editor on those pages into a spurious conflict. If a
--   row version is wanted later, it is a SECOND column, not this one.
--
-- THE APPEND REACHES THE BRIDGE OVER RPC, NOT OVER A ROW WRITE (C20)
--   The bridge writes osionos_pages through PostgREST REST only (baasRest,
--   bridge-api.mjs:426-447) and has no raw-SQL path for the app's own tables; the
--   query-router passthrough serves tenant databases. The proven pattern for a
--   DB-side function is a PostgREST RPC with an explicit grant (bridge-api.mjs:1289
--   -> rest/v1/rpc/osionos_bridge_upsert_workspace; models/osionos-bridge-migration.sql:361-362).
--   This file follows that rule exactly: REVOKE … FROM PUBLIC; GRANT EXECUTE …
--   TO service_role.
--
-- WHY THE FUNCTION IS NOT SECURITY DEFINER
--   The bridge calls RPCs with the service key, i.e. as service_role
--   (bridge-api.mjs:1289-1295: apikey and Authorization are config.serviceKey).
--   service_role already holds GRANT ALL on osionos_pages and BYPASSRLS, and this
--   file grants it the same on the keys table. A SECURITY DEFINER function would
--   run as its owner (postgres) instead: the same writes would then no longer be
--   subject to the RLS policies the bridge's own writes are subject to, and the one
--   thing that keeps the append honest — "an append may do exactly what a PATCH may
--   do" — would stop being true in the catalog. SECURITY INVOKER keeps the append's
--   privileges identical to the caller's, so the table ACL IS the gate. (It is also
--   the shape of the tree's other trigger function, models/auth-session-cutoffs.sql:36-45:
--   not SECURITY DEFINER, search_path pinned.)
--
-- The append's permission checks are the bridge's, not the function's: the function
--   runs as service_role (which bypasses RLS), so the bridge must keep doing
--   requireReadablePage + ownerOrWorkspaceAccess('update') before it calls this.
--
-- Idempotent: a replay moves no grant, policy or RLS flag, re-creates the same
-- objects and changes no row. ADD COLUMN IF NOT EXISTS on an existing table keeps
-- every version at 0, so a replay never bumps a page.

-- -----------------------------------------------------------------------------
-- 1. The content version
-- -----------------------------------------------------------------------------
ALTER TABLE public.osionos_pages
  ADD COLUMN IF NOT EXISTS version bigint NOT NULL DEFAULT 0;

-- The trigger owns the column: it OVERWRITES NEW.version on every update, so a
-- writer can never set it from a payload, and a title / archive / properties /
-- record-note write never bumps it.
CREATE OR REPLACE FUNCTION public.osionos_page_bump_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  NEW.version := CASE
    WHEN NEW.content IS DISTINCT FROM OLD.content THEN OLD.version + 1
    ELSE OLD.version
  END;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS osionos_pages_version_trg ON public.osionos_pages;
CREATE TRIGGER osionos_pages_version_trg
  BEFORE UPDATE ON public.osionos_pages
  FOR EACH ROW EXECUTE FUNCTION public.osionos_page_bump_version();

-- -----------------------------------------------------------------------------
-- 2. The idempotency ledger (C21)
-- -----------------------------------------------------------------------------
-- One row per (page, key). The key is claimed by the append that uses it, and the
-- row records the version that append produced. A repeated key returns that stored
-- version and the CURRENT content, and appends nothing.
CREATE TABLE IF NOT EXISTS public.osionos_page_append_keys (
  page_id UUID NOT NULL REFERENCES public.osionos_pages(id) ON DELETE CASCADE,
  idempotency_key TEXT NOT NULL,
  version BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (page_id, idempotency_key)
);

-- The prune reads created_at; the index is what keeps it cheap.
CREATE INDEX IF NOT EXISTS osionos_page_append_keys_created_idx
  ON public.osionos_page_append_keys (created_at);

ALTER TABLE public.osionos_page_append_keys ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_page_append_keys_service_role_all ON public.osionos_page_append_keys;
CREATE POLICY osionos_page_append_keys_service_role_all ON public.osionos_page_append_keys
  FOR ALL TO service_role USING (true) WITH CHECK (true);
REVOKE ALL ON public.osionos_page_append_keys FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_page_append_keys TO service_role;

-- PRUNING: no scheduler ships with this migration. Run the statement yourself
-- (cron, the desktop edition's boot, whatever you have):
--
--   DELETE FROM public.osionos_page_append_keys
--    WHERE created_at < now() - interval '7 days';
--
-- A key older than 7 days is forgotten on purpose: the ledger exists to make a
-- RETRY safe, and a retry that arrives more than 7 days later is a new write.

-- -----------------------------------------------------------------------------
-- 3. The atomic append
-- -----------------------------------------------------------------------------
-- Appends p_blocks to a page's content and answers the page's new version and
-- content. One statement does the append, so two concurrent callers cannot lose
-- one another's blocks: the UPDATE takes the row's lock, and the loser re-reads
-- the content the winner committed.
--
-- p_after_block_id: the blocks land right after the TOP-LEVEL block whose id is
-- that value. An unknown id appends at the end. Only the top level is addressed:
-- a block nested in `children` or in a layout cell has no top-level ordinal, so
-- an id that names one is an unknown id here and the blocks land at the end.
--
-- p_idempotency_key: NULL (or '') means no idempotency — every call appends. A
-- caller that can be retried MUST carry a key: the same key twice appends once.
CREATE OR REPLACE FUNCTION public.osionos_page_append(
  p_page_id UUID,
  p_blocks JSONB,
  p_after_block_id TEXT DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL
) RETURNS TABLE (version BIGINT, content JSONB)
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_claimed BOOLEAN := false;
  v_stored_version BIGINT;
  v_version BIGINT;
  v_content JSONB;
BEGIN
  -- The blocks must be a non-empty array of objects, each carrying a string id.
  -- (A blank id is refused too: it could never be addressed by p_after_block_id.)
  IF p_blocks IS NULL OR jsonb_typeof(p_blocks) <> 'array' OR jsonb_array_length(p_blocks) = 0 THEN
    RAISE EXCEPTION 'osionos_page_append: p_blocks must be a non-empty jsonb array of blocks';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_blocks) AS b
     WHERE jsonb_typeof(b) <> 'object'
        OR NOT (b ? 'id')
        OR jsonb_typeof(b -> 'id') <> 'string'
        OR btrim(b ->> 'id') = ''
  ) THEN
    RAISE EXCEPTION 'osionos_page_append: every block must be an object carrying a non-empty string id';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.osionos_pages p WHERE p.id = p_page_id) THEN
    RAISE EXCEPTION 'osionos_page_append: page % does not exist', p_page_id;
  END IF;

  -- Claim the key. The INSERT takes the ledger row's lock, so a concurrent caller
  -- with the SAME key waits here until the first append commits and then finds
  -- the key claimed.
  IF p_idempotency_key IS NOT NULL AND p_idempotency_key <> '' THEN
    INSERT INTO public.osionos_page_append_keys (page_id, idempotency_key, version)
    VALUES (p_page_id, p_idempotency_key, 0)
    ON CONFLICT (page_id, idempotency_key) DO NOTHING;
    v_claimed := FOUND;
    IF NOT v_claimed THEN
      -- A repeat of a key already used: no second append. The stored version is
      -- the one the first append produced; the content is the page's CURRENT one
      -- (it may have moved on since).
      SELECT k.version INTO v_stored_version
        FROM public.osionos_page_append_keys k
       WHERE k.page_id = p_page_id AND k.idempotency_key = p_idempotency_key;
      SELECT p.content INTO v_content
        FROM public.osionos_pages p
       WHERE p.id = p_page_id;
      RETURN QUERY SELECT v_stored_version, v_content;
      RETURN;
    END IF;
  END IF;

  -- The append: ONE statement, so it is atomic under concurrent callers.
  UPDATE public.osionos_pages p
     SET content = (
           SELECT coalesce(jsonb_agg(e.b ORDER BY e.ord) FILTER (WHERE e.ord <= idx.i), '[]'::jsonb)
                || p_blocks
                || coalesce(jsonb_agg(e.b ORDER BY e.ord) FILTER (WHERE e.ord > idx.i), '[]'::jsonb)
             FROM jsonb_array_elements(p.content) WITH ORDINALITY AS e(b, ord)
             CROSS JOIN LATERAL (
               -- The ordinal of the top-level block named by p_after_block_id, or
               -- one past the last element when there is none (append at the end).
               SELECT coalesce(
                        min(e2.ord) FILTER (WHERE e2.b ->> 'id' = p_after_block_id),
                        count(*) + 1
                      ) AS i
                 FROM jsonb_array_elements(p.content) WITH ORDINALITY AS e2(b, ord)
             ) idx
         ),
         updated_at = now()
   WHERE p.id = p_page_id
  RETURNING p.version, p.content INTO v_version, v_content;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'osionos_page_append: page % disappeared', p_page_id;
  END IF;

  IF v_claimed THEN
    UPDATE public.osionos_page_append_keys k
       SET version = v_version
     WHERE k.page_id = p_page_id AND k.idempotency_key = p_idempotency_key;
  END IF;

  RETURN QUERY SELECT v_version, v_content;
END $$;

REVOKE ALL ON FUNCTION public.osionos_page_append(UUID, JSONB, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_page_append(UUID, JSONB, TEXT, TEXT) TO service_role;

COMMENT ON FUNCTION public.osionos_page_append(UUID, JSONB, TEXT, TEXT) IS
  'Appends blocks to a page''s content atomically and answers (version, content). '
  'The version is bumped by the BEFORE UPDATE trigger when the content changed. '
  'p_after_block_id names a TOP-LEVEL block to insert after (unknown id -> end). '
  'p_idempotency_key makes a retry safe: the same key twice appends once and '
  'answers the stored version with the current content. Service role only.';

NOTIFY pgrst, 'reload schema';
