-- osionos page access requests, served ONLY through the bridge.
--
-- A member who opens a page they cannot read may ask its owner for access. The row is the
-- request, never a grant: an approval writes an ordinary share rule (osionos_share_rules)
-- with the owner's own authority, and this row only records that it was decided.
-- Devil verdict 2026-10-28 (Plan A, N13-N15): the note and requester_id are private to the
-- page owner, so nothing but service_role may reach the table, and no realtime trigger may
-- broadcast it.
--
-- One transaction: this database's default privileges give anon/authenticated
-- SELECT/INSERT/UPDATE/DELETE on every new public table, so a half-applied file would leave
-- the table writable with the public anon key through Kong /rest/v1. Idempotent.

BEGIN;

CREATE TABLE IF NOT EXISTS public.osionos_page_access_requests (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID        NOT NULL REFERENCES public.osionos_workspaces(id) ON DELETE CASCADE,
  -- A page delete is a hard delete, descendants first: a request must not hold one up.
  page_id      UUID        NOT NULL REFERENCES public.osionos_pages(id) ON DELETE CASCADE,
  requester_id UUID        NOT NULL,
  note         TEXT        CHECK (char_length(note) <= 280),
  -- 'expired' is written lazily by the bridge before an insert (N15), never by a job.
  status       TEXT        NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending', 'approved', 'declined', 'expired')),
  decided_by   UUID,
  decided_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT osionos_page_access_requests_decided
    CHECK ((status IN ('approved', 'declined')) = (decided_at IS NOT NULL))
);

-- One open request per person per page. The bridge decides with a filtered PATCH on
-- status=pending, so two owners' tabs cannot both decide one request.
CREATE UNIQUE INDEX IF NOT EXISTS osionos_page_access_requests_pending_idx
  ON public.osionos_page_access_requests (page_id, requester_id)
  WHERE status = 'pending';

-- The silent cap on a requester's open requests (N4) counts through this.
CREATE INDEX IF NOT EXISTS osionos_page_access_requests_requester_idx
  ON public.osionos_page_access_requests (requester_id, workspace_id)
  WHERE status = 'pending';

REVOKE ALL ON public.osionos_page_access_requests FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_page_access_requests TO service_role;

ALTER TABLE public.osionos_page_access_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_page_access_requests FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_page_access_requests_service_role_all ON public.osionos_page_access_requests;
CREATE POLICY osionos_page_access_requests_service_role_all ON public.osionos_page_access_requests
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- The realtime event trigger attaches a row-broadcasting trigger to every new public table,
-- and the realtime socket has no grant check: it would hand the note to any subscriber.
DROP TRIGGER IF EXISTS osionos_page_access_requests_realtime_trigger ON public.osionos_page_access_requests;

COMMIT;

NOTIFY pgrst, 'reload schema';
