-- osionos — suggested edits, replies and reactions on page comments (#228).
--
-- A page comment can now be a SUGGESTION: a proposed replacement of a range of
-- one block's inline source. The decide (accept or reject) and the splice of the
-- accepted text run in ONE transaction here, so a decided suggestion and the page
-- text never disagree (spec docs/superpowers/specs/2026-10-30-suggestions-and-
-- discussions-design.md in apps/osionos/app, rev 2.1).
--
--   1. Columns on osionos_page_comments: parent_id (one level of replies), kind,
--      anchor, suggestion, status, decided_by, decided_at, deleted_at, updated_at.
--      Additive with fast defaults: old rows read as kind='comment', status='open';
--      old readers ignore the columns, old writers never set them.
--   2. Named CHECKs, added NOT VALID then validated (old rows pass every one).
--   3. A write guard (updated_at stamp, parent on the same page and a root) and a
--      delete guard (a decided suggestion is history; a row with replies is
--      soft-deleted by the bridge, never hard-deleted).
--   4. osionos_page_comment_reactions, service_role only.
--   5. The anchor rules, mirrored from src/features/comments/model/suggestionAnchor.ts
--      and proved over the same fixture (tests/fixtures/suggestion-anchors.json):
--      osionos_suggestion_reanchor / _overlap / _rebase / _apply.
--   6. osionos_decide_suggestion(...) — service_role only, not SECURITY DEFINER
--      (the osionos_page_append pattern, ADR 0026).
--
-- OFFSETS ARE CODE POINTS. The database is UTF8, so substr / strpos / char_length
-- count code points, the unit the composer converts to (spec C4).
--
-- Caveat: a re-anchor looks for prefix || quote || suffix where the anchor says,
-- then for its UNIQUE occurrence in the block. A quote whose 16-code-point context
-- was edited, or that reads twice with the same context, is stale — never guessed.
-- A crafted anchor whose offsets cut a tag in half splices broken markup; the card
-- shows the raw quote before anyone accepts (spec S15).
--
-- Caveat: parent_id is ON DELETE RESTRICT (spec S4). A page or workspace cascade
-- deletes a root and its replies in one statement, so the restrict check sees no
-- child left; scripts/verify/discussions.sh proves it (C13) rather than assume it.
--
-- Lock-safe: ADD COLUMN with constant / stable defaults (no rewrite), NOT VALID
-- constraints validated separately. Idempotent: replayed on every boot.
-- Rollback: models/rollback/osionos-discussions-rollback.sql.

SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1. Columns
-- -----------------------------------------------------------------------------
ALTER TABLE public.osionos_page_comments
  ADD COLUMN IF NOT EXISTS parent_id  UUID REFERENCES public.osionos_page_comments(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS kind       TEXT NOT NULL DEFAULT 'comment',
  ADD COLUMN IF NOT EXISTS anchor     JSONB,
  ADD COLUMN IF NOT EXISTS suggestion JSONB,
  ADD COLUMN IF NOT EXISTS status     TEXT NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS decided_by UUID,
  ADD COLUMN IF NOT EXISTS decided_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- -----------------------------------------------------------------------------
-- 2. CHECKs — a changed rule takes a NEW name, so the IF NOT EXISTS stays honest.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  c record;
BEGIN
  FOR c IN SELECT * FROM (VALUES
    ('osionos_page_comments_kind_check',
     $c$kind IN ('comment', 'suggestion')$c$),
    ('osionos_page_comments_status_check',
     $c$status IN ('open', 'accepted', 'rejected', 'superseded')$c$),
    ('osionos_page_comments_suggestion_shape_check',
     $c$kind <> 'suggestion' OR (parent_id IS NULL AND block_id IS NOT NULL
                                 AND anchor IS NOT NULL AND suggestion IS NOT NULL)$c$),
    ('osionos_page_comments_reply_kind_check',
     $c$parent_id IS NULL OR kind = 'comment'$c$),
    ('osionos_page_comments_decided_check',
     $c$(status = 'open') = (decided_by IS NULL AND decided_at IS NULL)$c$),
    -- start/end are integers, end - start is the quote's length in code points,
    -- the quote fits the bridge bound and the context is at most 16 code points.
    -- CASE guards the casts: a malformed anchor is a check violation, not a 22P02.
    ('osionos_page_comments_anchor_check',
     $c$anchor IS NULL OR CASE
        WHEN jsonb_typeof(anchor) <> 'object'
          OR jsonb_typeof(anchor -> 'start') IS DISTINCT FROM 'number'
          OR jsonb_typeof(anchor -> 'end') IS DISTINCT FROM 'number'
          OR jsonb_typeof(anchor -> 'quote') IS DISTINCT FROM 'string'
          OR jsonb_typeof(coalesce(anchor -> 'prefix', '""')) <> 'string'
          OR jsonb_typeof(coalesce(anchor -> 'suffix', '""')) <> 'string' THEN false
        ELSE (anchor ->> 'start')::numeric = trunc((anchor ->> 'start')::numeric)
         AND (anchor ->> 'start')::numeric >= 0
         AND (anchor ->> 'end')::numeric - (anchor ->> 'start')::numeric = char_length(anchor ->> 'quote')
         AND char_length(anchor ->> 'quote') <= 2000
         AND char_length(coalesce(anchor ->> 'prefix', '')) <= 16
         AND char_length(coalesce(anchor ->> 'suffix', '')) <= 16
        END$c$),
    ('osionos_page_comments_suggestion_check',
     $c$suggestion IS NULL OR (jsonb_typeof(suggestion) = 'object'
                               AND jsonb_typeof(suggestion -> 'insert') = 'string'
                               AND octet_length(suggestion ->> 'insert') <= 8000)$c$)
  ) AS t(name, body) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'public.osionos_page_comments'::regclass AND conname = c.name) THEN
      EXECUTE format('ALTER TABLE public.osionos_page_comments ADD CONSTRAINT %I CHECK (%s) NOT VALID',
                     c.name, c.body);
    END IF;
    EXECUTE format('ALTER TABLE public.osionos_page_comments VALIDATE CONSTRAINT %I', c.name);
  END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS osionos_page_comments_open_suggestions_idx
  ON public.osionos_page_comments (page_id, block_id)
  WHERE kind = 'suggestion' AND status = 'open' AND deleted_at IS NULL;
-- Also serves the parent_id restrict check (parent_id = $1 implies NOT NULL).
CREATE INDEX IF NOT EXISTS osionos_page_comments_parent_idx
  ON public.osionos_page_comments (parent_id)
  WHERE parent_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 3. Guards
-- -----------------------------------------------------------------------------
-- updated_at is the TEXT stamp the accepter echoes back (spec C6): it moves when
-- what a card shows moves (content, insert, quote, status, deletion), not when a
-- rebase shifts offsets or moderation / erasure touches other columns.
CREATE OR REPLACE FUNCTION public.osionos_page_comments_guard_write() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_parent record;
BEGIN
  IF TG_OP = 'UPDATE'
     AND (OLD.content, OLD.suggestion, OLD.anchor -> 'quote', OLD.status, OLD.deleted_at)
         IS DISTINCT FROM (NEW.content, NEW.suggestion, NEW.anchor -> 'quote', NEW.status, NEW.deleted_at) THEN
    NEW.updated_at := now();
  END IF;
  IF NEW.parent_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.parent_id IS DISTINCT FROM OLD.parent_id) THEN
    SELECT c.page_id, c.parent_id INTO v_parent
      FROM public.osionos_page_comments c WHERE c.id = NEW.parent_id;
    IF FOUND AND v_parent.page_id IS DISTINCT FROM NEW.page_id THEN
      RAISE EXCEPTION 'a reply must be on its parent''s page' USING ERRCODE = '23514';
    END IF;
    IF FOUND AND v_parent.parent_id IS NOT NULL THEN
      RAISE EXCEPTION 'a reply answers a root, not another reply' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS osionos_page_comments_guard_write_trg ON public.osionos_page_comments;
CREATE TRIGGER osionos_page_comments_guard_write_trg
  BEFORE INSERT OR UPDATE ON public.osionos_page_comments
  FOR EACH ROW EXECUTE FUNCTION public.osionos_page_comments_guard_write();

-- A decided suggestion is history and a row with replies keeps the thread's shape
-- (the bridge soft-deletes it). Neither rule applies when the page row is already
-- gone: a page, workspace or erasure cascade removes the whole discussion (C8).
CREATE OR REPLACE FUNCTION public.osionos_page_comments_guard_delete() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.osionos_pages p WHERE p.id = OLD.page_id) THEN
    RETURN OLD;
  END IF;
  IF OLD.status <> 'open' THEN
    RAISE EXCEPTION 'a decided suggestion is history and cannot be deleted' USING ERRCODE = '23503';
  END IF;
  IF EXISTS (SELECT 1 FROM public.osionos_page_comments c WHERE c.parent_id = OLD.id) THEN
    RAISE EXCEPTION 'a comment with replies is soft-deleted, not deleted' USING ERRCODE = '23503';
  END IF;
  RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS osionos_page_comments_guard_delete_trg ON public.osionos_page_comments;
CREATE TRIGGER osionos_page_comments_guard_delete_trg
  BEFORE DELETE ON public.osionos_page_comments
  FOR EACH ROW EXECUTE FUNCTION public.osionos_page_comments_guard_delete();

-- -----------------------------------------------------------------------------
-- 4. Reactions
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.osionos_page_comment_reactions (
  comment_id UUID NOT NULL REFERENCES public.osionos_page_comments(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL,
  emoji      TEXT NOT NULL CHECK (char_length(emoji) BETWEEN 1 AND 16),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (comment_id, user_id, emoji)
);
CREATE INDEX IF NOT EXISTS osionos_page_comment_reactions_user_idx
  ON public.osionos_page_comment_reactions (user_id);

ALTER TABLE public.osionos_page_comment_reactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_page_comment_reactions_service_role_all ON public.osionos_page_comment_reactions;
CREATE POLICY osionos_page_comment_reactions_service_role_all ON public.osionos_page_comment_reactions
  FOR ALL TO service_role USING (true) WITH CHECK (true);
REVOKE ALL ON public.osionos_page_comment_reactions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_page_comment_reactions TO service_role;

-- -----------------------------------------------------------------------------
-- 5. The anchor rules (suggestionAnchor.ts, the same fixture)
-- -----------------------------------------------------------------------------
-- The anchor in p_source: unchanged when prefix || quote || suffix still reads at
-- its offsets, moved to the unique place it reads, else NULL (stale). An empty
-- context is always stale (C2): an offset alone is not a place.
CREATE OR REPLACE FUNCTION public.osionos_suggestion_reanchor(p_source TEXT, p_anchor JSONB)
RETURNS JSONB LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE
  v_prefix  text := coalesce(p_anchor ->> 'prefix', '');
  v_quote   text := coalesce(p_anchor ->> 'quote', '');
  v_context text := v_prefix || v_quote || coalesce(p_anchor ->> 'suffix', '');
  v_from    int  := (p_anchor ->> 'start')::int - char_length(v_prefix);
  v_at      int;
  v_start   int;
BEGIN
  IF v_context = '' THEN
    RETURN NULL;
  END IF;
  IF v_from >= 0 AND substr(p_source, v_from + 1, char_length(v_context)) = v_context THEN
    RETURN p_anchor;
  END IF;
  v_at := strpos(p_source, v_context);
  -- A second occurrence may overlap the first, as indexOf(at + 1) finds it.
  IF v_at = 0 OR strpos(substr(p_source, v_at + 1), v_context) > 0 THEN
    RETURN NULL;
  END IF;
  v_start := v_at - 1 + char_length(v_prefix);
  RETURN p_anchor || jsonb_build_object('start', v_start, 'end', v_start + char_length(v_quote));
END $$;

-- Two anchors touch the same text; an insertion overlaps a range it sits inside or
-- on the edge of.
CREATE OR REPLACE FUNCTION public.osionos_suggestions_overlap(p_left JSONB, p_right JSONB)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE
    WHEN (p_left ->> 'start')::int = (p_left ->> 'end')::int
      OR (p_right ->> 'start')::int = (p_right ->> 'end')::int
    THEN (p_left ->> 'start')::int <= (p_right ->> 'end')::int
     AND (p_right ->> 'start')::int <= (p_left ->> 'end')::int
    ELSE (p_left ->> 'start')::int < (p_right ->> 'end')::int
     AND (p_right ->> 'start')::int < (p_left ->> 'end')::int
  END
$$;

-- The anchor [p_start, p_end) of p_source with its 16-code-point context.
CREATE OR REPLACE FUNCTION public.osionos_suggestion_anchor_at(p_source TEXT, p_start INT, p_end INT)
RETURNS JSONB LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT jsonb_build_object(
    'start', p_start,
    'end', p_end,
    'quote', substr(p_source, p_start + 1, p_end - p_start),
    'prefix', substr(p_source, greatest(0, p_start - 16) + 1, p_start - greatest(0, p_start - 16)),
    'suffix', substr(p_source, p_end + 1, 16))
$$;

-- p_draft = {anchor, insert} spliced into the source it was drafted against.
CREATE OR REPLACE FUNCTION public.osionos_suggestion_apply(p_source TEXT, p_draft JSONB)
RETURNS TEXT LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT left(p_source, (p_draft -> 'anchor' ->> 'start')::int)
      || (p_draft ->> 'insert')
      || substr(p_source, (p_draft -> 'anchor' ->> 'end')::int + 1)
$$;

-- Another open suggestion after p_accepted was spliced, p_next being the new
-- source: shifted past the splice with fresh context, or NULL when it overlaps the
-- accepted one (superseded).
CREATE OR REPLACE FUNCTION public.osionos_suggestion_rebase(p_other JSONB, p_accepted JSONB, p_next TEXT)
RETURNS JSONB LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE
  v_acc   jsonb := p_accepted -> 'anchor';
  v_start int   := (p_other ->> 'start')::int;
BEGIN
  IF public.osionos_suggestions_overlap(p_other, v_acc) THEN
    RETURN NULL;
  END IF;
  IF v_start >= (v_acc ->> 'end')::int THEN
    v_start := v_start + char_length(p_accepted ->> 'insert')
             - ((v_acc ->> 'end')::int - (v_acc ->> 'start')::int);
  END IF;
  RETURN public.osionos_suggestion_anchor_at(p_next, v_start, v_start + char_length(p_other ->> 'quote'));
END $$;

-- The jsonb path of the block p_block_id inside p_blocks, walking `children` and
-- `layoutCells[].blocks` (C5); NULL when no block carries that id.
CREATE OR REPLACE FUNCTION public.osionos_block_path(p_blocks JSONB, p_block_id TEXT)
RETURNS TEXT[] LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE
  v_block jsonb;
  v_i     int;
  v_cell  jsonb;
  v_j     int;
  v_found text[];
BEGIN
  IF jsonb_typeof(p_blocks) IS DISTINCT FROM 'array' THEN
    RETURN NULL;
  END IF;
  FOR v_block, v_i IN SELECT e.b, e.ord - 1 FROM jsonb_array_elements(p_blocks) WITH ORDINALITY AS e(b, ord) LOOP
    IF v_block ->> 'id' = p_block_id THEN
      RETURN ARRAY[v_i::text];
    END IF;
    v_found := public.osionos_block_path(v_block -> 'children', p_block_id);
    IF v_found IS NOT NULL THEN
      RETURN ARRAY[v_i::text, 'children'] || v_found;
    END IF;
    IF jsonb_typeof(v_block -> 'layoutCells') = 'array' THEN
      FOR v_cell, v_j IN SELECT e.c, e.ord - 1 FROM jsonb_array_elements(v_block -> 'layoutCells') WITH ORDINALITY AS e(c, ord) LOOP
        v_found := public.osionos_block_path(v_cell -> 'blocks', p_block_id);
        IF v_found IS NOT NULL THEN
          RETURN ARRAY[v_i::text, 'layoutCells', v_j::text, 'blocks'] || v_found;
        END IF;
      END LOOP;
    END IF;
  END LOOP;
  RETURN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- 6. The decide — verdict and text in ONE transaction (S2, S5)
-- -----------------------------------------------------------------------------
-- Lock order, for every decide: the page row, then the block's open suggestions
-- in id order — one global order, so two decides cannot deadlock. NO KEY UPDATE
-- does not conflict with the KEY SHARE a reply or reaction INSERT takes on its
-- parent, so a thread stays writable while a decide runs.
--
-- Answers {ok:false, reason} with reason in: missing (no such suggestion),
-- decided (not open any more), changed (p_expected_updated_at is not the row's
-- stamp: the decider saw another text, C6), archived (the page is), unsupported
-- (the block is not an inline-text block), stale (the block or the quote is gone).
-- Nothing is written on any of them. On success:
-- {ok:true, status, supersededIds, rebasedIds, version, content, updatedAt}, the
-- page's FULL content (C1).
CREATE OR REPLACE FUNCTION public.osionos_decide_suggestion(
  p_id UUID,
  p_decider UUID,
  p_verdict TEXT,
  p_expected_updated_at TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  v_page_id    uuid;
  v_block_id   text;
  v_target     record;
  v_page       record;
  v_path       text[];
  v_block      jsonb;
  v_source     text;
  v_anchor     jsonb;
  v_draft      jsonb;
  v_next       text;
  v_other      record;
  v_moved      jsonb;
  v_superseded jsonb := '[]'::jsonb;
  v_rebased    jsonb := '[]'::jsonb;
  v_version    bigint;
  v_content    jsonb;
  v_now        timestamptz := now();
BEGIN
  IF p_verdict IS NULL OR p_verdict NOT IN ('accepted', 'rejected') THEN
    RAISE EXCEPTION 'osionos_decide_suggestion: verdict must be accepted or rejected' USING ERRCODE = '22023';
  END IF;
  IF p_decider IS NULL THEN
    RAISE EXCEPTION 'osionos_decide_suggestion: a decider is required' USING ERRCODE = '22023';
  END IF;

  SELECT c.page_id, c.block_id INTO v_page_id, v_block_id
    FROM public.osionos_page_comments c
   WHERE c.id = p_id AND c.kind = 'suggestion';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing');
  END IF;

  SELECT p.content, p.archived_at INTO v_page
    FROM public.osionos_pages p WHERE p.id = v_page_id
     FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing');
  END IF;
  PERFORM 1 FROM public.osionos_page_comments c
    WHERE c.page_id = v_page_id AND c.block_id = v_block_id
      AND c.kind = 'suggestion' AND c.status = 'open'
    ORDER BY c.id
      FOR NO KEY UPDATE;

  -- Re-read under the locks: an edit that committed while this waited is seen.
  SELECT c.status, c.anchor, c.suggestion, c.updated_at, c.deleted_at INTO v_target
    FROM public.osionos_page_comments c WHERE c.id = p_id;
  IF v_target.status <> 'open' OR v_target.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'decided', 'status', v_target.status);
  END IF;
  IF p_expected_updated_at IS NOT NULL AND v_target.updated_at <> p_expected_updated_at THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'changed');
  END IF;

  IF p_verdict = 'rejected' THEN
    UPDATE public.osionos_page_comments
       SET status = 'rejected', decided_by = p_decider, decided_at = v_now
     WHERE id = p_id
    RETURNING updated_at INTO v_target.updated_at;
    RETURN jsonb_build_object('ok', true, 'status', 'rejected', 'supersededIds', '[]'::jsonb,
                              'rebasedIds', '[]'::jsonb, 'updatedAt', v_target.updated_at);
  END IF;

  IF v_page.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'archived');
  END IF;
  v_path := public.osionos_block_path(v_page.content, v_block_id);
  IF v_path IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stale');
  END IF;
  v_block := v_page.content #> v_path;
  IF NOT coalesce(v_block ->> 'type', '') = ANY (ARRAY['paragraph', 'heading_1', 'heading_2', 'heading_3',
       'heading_4', 'heading_5', 'heading_6', 'bulleted_list', 'numbered_list', 'to_do', 'toggle',
       'quote', 'callout']) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unsupported');
  END IF;
  v_source := coalesce(v_block ->> 'content', '');
  v_anchor := public.osionos_suggestion_reanchor(v_source, v_target.anchor);
  IF v_anchor IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stale');
  END IF;
  v_draft := jsonb_build_object('anchor', v_anchor, 'insert', v_target.suggestion ->> 'insert');
  v_next := public.osionos_suggestion_apply(v_source, v_draft);

  UPDATE public.osionos_pages p
     SET content = jsonb_set(p.content, v_path || ARRAY['content'], to_jsonb(v_next)),
         updated_at = v_now
   WHERE p.id = v_page_id
  RETURNING p.version, p.content INTO v_version, v_content;

  UPDATE public.osionos_page_comments
     SET status = 'accepted', decided_by = p_decider, decided_at = v_now, anchor = v_anchor
   WHERE id = p_id
  RETURNING updated_at INTO v_target.updated_at;

  -- The block's other open suggestions: placed against the source BEFORE the
  -- splice, then superseded when they overlap the accepted range, else shifted
  -- past it. One that can't be placed is left as it is: its own decide answers
  -- stale.
  FOR v_other IN
    SELECT c.id, c.anchor FROM public.osionos_page_comments c
     WHERE c.page_id = v_page_id AND c.block_id = v_block_id AND c.id <> p_id
       AND c.kind = 'suggestion' AND c.status = 'open' AND c.deleted_at IS NULL
     ORDER BY c.id
  LOOP
    v_moved := public.osionos_suggestion_reanchor(v_source, v_other.anchor);
    CONTINUE WHEN v_moved IS NULL;
    IF public.osionos_suggestions_overlap(v_moved, v_anchor) THEN
      UPDATE public.osionos_page_comments
         SET status = 'superseded', decided_by = p_decider, decided_at = v_now
       WHERE id = v_other.id;
      v_superseded := v_superseded || to_jsonb(v_other.id);
    ELSE
      UPDATE public.osionos_page_comments
         SET anchor = public.osionos_suggestion_rebase(v_moved, v_draft, v_next)
       WHERE id = v_other.id;
      v_rebased := v_rebased || to_jsonb(v_other.id);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'status', 'accepted', 'supersededIds', v_superseded,
                            'rebasedIds', v_rebased, 'version', v_version, 'content', v_content,
                            'updatedAt', v_target.updated_at);
END $$;

DO $$
DECLARE
  f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.osionos_suggestion_reanchor(text, jsonb)',
    'public.osionos_suggestions_overlap(jsonb, jsonb)',
    'public.osionos_suggestion_anchor_at(text, int, int)',
    'public.osionos_suggestion_apply(text, jsonb)',
    'public.osionos_suggestion_rebase(jsonb, jsonb, text)',
    'public.osionos_block_path(jsonb, text)',
    'public.osionos_decide_suggestion(uuid, uuid, text, timestamptz)',
    'public.osionos_page_comments_guard_write()',
    'public.osionos_page_comments_guard_delete()'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    -- The decide is SECURITY INVOKER: the service role runs every helper it calls.
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
