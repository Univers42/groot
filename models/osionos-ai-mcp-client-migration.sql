-- ai_mcp_servers, ai_mcp_tools — the remote MCP servers a user registers, and
-- the snapshot of the tools each one offers (E1a; devil verdict
-- e1-mcp-client-verdict.md, conditions C263-C292).
--
-- What this file is, and what it is not:
--   - STORAGE ONLY. No run reads these tables yet: a tool is `enabled` by the
--     user, one by one, and no tool is ever enabled by discovery (C270).
--   - A server belongs to ONE user. There is no workspace_id column on purpose
--     (C292, Q6): a bearer owned by one member and used under another member's
--     approval is a confused deputy, and the AAD of the sealed header is bound
--     to the owner anyway.
--   - The header is an envelope (C274): header_ciphertext under a data key of
--     its own, header_wrapped_dek under the KEK, header_kek_id naming the KEK.
--     The brief named only the ciphertext; the envelope of src/connections/
--     crypto.ts needs the other two to open it. header_last4 is the only
--     readable part. No route ever returns any of these columns (C271).
--   - ai_mcp_tools is the SNAPSHOT (C272): name, description, schema and the
--     hash of the three. A re-discovery that changes the hash turns the tool
--     off again; that rule is the service's, the hash column is what it needs.
--
-- C271  both tables are service_role-only: RLS on, one service_role policy and
--       REVOKE ALL from PUBLIC/anon/authenticated, as ai_skills does (C43).
-- C285  ai_mcp_erase_user(uuid) deletes the user's servers (the tools cascade);
--       ai_erase_user() dispatches to it dynamically, and osionos_account_data_map
--       lists the owner column.
--
-- Caveat: the size CHECKs are a backstop, not the cap. The service refuses a
-- schema above 8 KiB of compact JSON; jsonb::text adds spaces after ':' and
-- ',', so the same schema reads larger here, and the CHECK allows 16 KiB so a
-- schema the service accepted is never refused by the database.
--
-- Lock-safe: two new tables only. Idempotent: IF NOT EXISTS / DROP ... IF
-- EXISTS / CREATE OR REPLACE, replayed on every boot. Never deletes a row.

SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1. The servers.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_mcp_servers (
	id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
	owner_id            uuid        NOT NULL,
	label               text        NOT NULL CHECK (length(label) BETWEEN 1 AND 80),
	-- https only is the service's rule (it knows the dev-host hatch); the length is a backstop.
	url                 text        NOT NULL CHECK (length(url) BETWEEN 1 AND 2048),
	header_name         text,
	header_ciphertext   bytea,
	header_wrapped_dek  bytea,
	header_kek_id       text,
	header_last4        text        CHECK (header_last4 IS NULL OR length(header_last4) <= 4),
	status              text        NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'ok', 'failing', 'broken')),
	consecutive_failures integer    NOT NULL DEFAULT 0 CHECK (consecutive_failures >= 0),
	broken_until        timestamptz,
	created_at          timestamptz NOT NULL DEFAULT now(),
	updated_at          timestamptz NOT NULL DEFAULT now(),
	-- A header is all or nothing: a half-sealed row could never open.
	CONSTRAINT ai_mcp_servers_header_shape CHECK (
		(header_name IS NULL AND header_ciphertext IS NULL AND header_wrapped_dek IS NULL
			AND header_kek_id IS NULL AND header_last4 IS NULL)
		OR (header_name IS NOT NULL AND header_ciphertext IS NOT NULL AND header_wrapped_dek IS NOT NULL
			AND header_kek_id IS NOT NULL AND header_last4 IS NOT NULL)
	)
);

CREATE INDEX IF NOT EXISTS ai_mcp_servers_owner_created_idx
	ON public.ai_mcp_servers (owner_id, created_at DESC);

COMMENT ON TABLE public.ai_mcp_servers IS
	'Remote MCP servers a user registered (E1a). Owner-scoped, no workspace column (C292). The header is envelope-encrypted with AAD mcp:{id}:{owner}. service_role only.';

-- -----------------------------------------------------------------------------
-- 2. The snapshot of the tools (C272).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_mcp_tools (
	server_id       uuid        NOT NULL REFERENCES public.ai_mcp_servers (id) ON DELETE CASCADE,
	name            text        NOT NULL CHECK (length(name) BETWEEN 1 AND 128),
	description     text        NOT NULL CHECK (octet_length(description) <= 1024),
	input_schema    jsonb       NOT NULL CHECK (octet_length(input_schema::text) <= 16384),
	snapshot_sha256 text        NOT NULL CHECK (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
	enabled         boolean     NOT NULL DEFAULT false,
	discovered_at   timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (server_id, name)
);

COMMENT ON TABLE public.ai_mcp_tools IS
	'Snapshot of the tools a registered MCP server offered at its last discovery (E1a, C272). enabled is the user''s choice and never set by discovery. service_role only.';

-- -----------------------------------------------------------------------------
-- 3. service_role only (C271).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_mcp_servers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_mcp_tools   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_mcp_servers_service_role_all ON public.ai_mcp_servers;
CREATE POLICY ai_mcp_servers_service_role_all ON public.ai_mcp_servers
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_mcp_tools_service_role_all ON public.ai_mcp_tools;
CREATE POLICY ai_mcp_tools_service_role_all ON public.ai_mcp_tools
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_mcp_servers TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_mcp_tools   TO service_role;

REVOKE ALL ON public.ai_mcp_servers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_mcp_tools   FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. Erasure (C285), dispatched from ai_erase_user().
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_mcp_erase_user(p_user uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
	n bigint;
BEGIN
	-- The snapshots go with their server (ON DELETE CASCADE).
	DELETE FROM public.ai_mcp_servers WHERE owner_id = p_user;
	GET DIAGNOSTICS n = ROW_COUNT;
	RETURN n;
END $$;

COMMENT ON FUNCTION public.ai_mcp_erase_user(uuid) IS
	'Deletes every MCP server of the user and, by cascade, its tool snapshots; returns the number of servers deleted. Called by ai_erase_user() when this file is applied.';

REVOKE ALL ON FUNCTION public.ai_mcp_erase_user(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_mcp_erase_user(uuid) TO service_role;

RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
