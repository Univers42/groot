-- Read by scripts/verify/account-roundtrip.sh (psql -v binds email, username, title, marker,
-- page_id; :'name' is quoted by psql). One 'step|verdict|detail' row per check.
SET statement_timeout = '15s';
SELECT 'db auth.users', CASE WHEN count(*) = 1 AND bool_and(email_confirmed_at IS NOT NULL) THEN 'ok' ELSE 'FAIL' END,
  coalesce(string_agg('id=' || id || ' email_confirmed=' || (email_confirmed_at IS NOT NULL), ', '), 'no row for the email')
FROM auth.users WHERE email = :'email';
SELECT 'db public.users', CASE WHEN count(*) = 1 AND bool_and(username = :'username') THEN 'ok' ELSE 'FAIL' END,
  coalesce(string_agg('id=' || id || ' username=' || username || ' is_email_verified=' || is_email_verified, ', '), 'no row for the email')
FROM public.users WHERE email = :'email';
SELECT 'db osionos_bridge_identities', CASE WHEN count(*) = 1 THEN 'ok' ELSE 'FAIL' END,
  coalesce(string_agg('user_id=' || i.user_id || ' provider=' || i.provider || ' private_workspace_id=' || i.private_workspace_id, ', '), 'no row')
FROM osionos_bridge_identities i JOIN auth.users u ON u.id = i.user_id WHERE u.email = :'email';
SELECT 'db osionos_workspaces', CASE WHEN count(*) = 1 THEN 'ok' ELSE 'FAIL' END,
  coalesce(string_agg('id=' || w.id || ' owner_id=' || w.owner_id || ' name=' || w.name, ', '), 'no row')
FROM osionos_workspaces w JOIN osionos_bridge_identities i ON w.id = i.private_workspace_id AND w.owner_id = i.user_id
JOIN auth.users u ON u.id = i.user_id WHERE u.email = :'email';
SELECT 'db osionos_workspace_members', CASE WHEN count(*) = 1 AND bool_and(m.role = 'owner') THEN 'ok' ELSE 'FAIL' END,
  coalesce(string_agg('workspace_id=' || m.workspace_id || ' user_id=' || m.user_id || ' role=' || m.role, ', '), 'no row')
FROM osionos_workspace_members m JOIN osionos_bridge_identities i ON m.workspace_id = i.private_workspace_id AND m.user_id = i.user_id
JOIN auth.users u ON u.id = i.user_id WHERE u.email = :'email';
SELECT 'db osionos_pages', CASE WHEN count(*) = 1 AND bool_and(p.id::text = :'page_id'
  AND p.content @> jsonb_build_array(jsonb_build_object('content', :'marker'::text))) THEN 'ok' ELSE 'FAIL' END,
  coalesce(string_agg('id=' || p.id || ' workspace_id=' || p.workspace_id || ' title=' || p.title || ' content=' || p.content::text, ', '), 'no page with the title')
FROM osionos_pages p JOIN auth.users u ON u.id = p.owner_id
JOIN osionos_bridge_identities i ON i.user_id = u.id AND p.workspace_id = i.private_workspace_id
WHERE u.email = :'email' AND p.title = :'title';
