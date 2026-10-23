-- ai_media_annotations — what the local VLM said about one picture (M7, "Describe image").
--
-- The service describes a picture ON REQUEST (the reader's own click, with the
-- reader's app session; devil C94 forbids a background scan of private
-- content). The answer is cached here so the same picture is described once.
--
-- THE KEY IS THE HASH OF THE STRIPPED BYTES (EXIF/XMP/IPTC removed by the
-- service, C81), plus the model and its revision: a new model revision is a new
-- row, never a silent overwrite. The same picture uploaded by two users is one
-- row, and nobody learns anything from it that they do not already hold: to ask
-- for the description a caller must first read the bytes through the bridge.
--
-- `result` holds caption, tags, objects, ocr AND the model's `safety` hint. The
-- safety hint is moderation data (C92/C97): the service stores it and never
-- returns it to a client.
--
-- NO user column, so there is nothing for the account-erase path to delete
-- (compare ai_access_tokens_erase_user): the row describes bytes, not a person.
--
-- Service-role only (C43): RLS on, no policy for anyone else, REVOKE from the
-- public roles.
--
-- Idempotent: IF NOT EXISTS / DROP ... IF EXISTS, replayed on boot.

CREATE TABLE IF NOT EXISTS public.ai_media_annotations (
    sha256     TEXT        NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    model      TEXT        NOT NULL,
    revision   TEXT        NOT NULL,
    result     JSONB       NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (sha256, model, revision)
);

ALTER TABLE public.ai_media_annotations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_media_annotations_service_role_all ON public.ai_media_annotations;
CREATE POLICY ai_media_annotations_service_role_all
    ON public.ai_media_annotations FOR ALL
    TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT ALL ON public.ai_media_annotations TO service_role;
REVOKE ALL ON public.ai_media_annotations FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
