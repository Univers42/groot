-- Curated demo content for the daily-driver feature wave (F1-F9). Idempotent
-- (fixed UUIDs + ON CONFLICT). Direct osionos_pages inserts fire the search_doc /
-- tasks / page_links triggers, so this doubles as trigger proof. Owner-stamped to
-- the dev user. Apply: docker exec -i mini-baas-postgres psql -U postgres -d postgres < this
\set owner '5cc30a3f-87e4-471d-b795-c936723081ee'
\set ws '0ea96910-277a-49d6-901c-524b147cc009'

-- Parents + interlinked pages (F1 search, F5 backlinks via [[page:uuid]]).
INSERT INTO public.osionos_pages (id, workspace_id, parent_page_id, owner_id, title, icon, content) VALUES
 ('dddddddd-0000-4000-8000-000000000001', :'ws', NULL, :'owner', 'Dev Hub', 'icon:folder',
   '[{"id":"h1","type":"heading_1","content":"Dev Hub","children":[]},
     {"id":"h1p","type":"paragraph","content":"Start here: [[page:dddddddd-0000-4000-8000-000000000002]] and [[page:dddddddd-0000-4000-8000-000000000003]].","children":[]}]'::jsonb),
 ('dddddddd-0000-4000-8000-000000000002', :'ws', 'dddddddd-0000-4000-8000-000000000001', :'owner', 'Architecture Notes', 'icon:page',
   '[{"id":"a1","type":"heading_2","content":"Architecture Notes","children":[]},
     {"id":"a2","type":"paragraph","content":"The deploy steps live in [[page:dddddddd-0000-4000-8000-000000000003]]. Search finds this by content.","children":[]},
     {"id":"a3","type":"code","language":"sql","content":"SELECT status, count(*) FROM orders GROUP BY status ORDER BY 2 DESC","children":[]}]'::jsonb),
 ('dddddddd-0000-4000-8000-000000000003', :'ws', 'dddddddd-0000-4000-8000-000000000001', :'owner', 'Deploy Runbook', 'icon:page',
   '[{"id":"d1","type":"heading_2","content":"Deploy Runbook","children":[]},
     {"id":"d2","type":"paragraph","content":"See [[page:dddddddd-0000-4000-8000-000000000002]] for the design rationale.","children":[]}]'::jsonb),
 ('dddddddd-0000-4000-8000-000000000005', :'ws', NULL, :'owner', 'Daily Notes', 'icon:calendar',
   '[{"id":"dn","type":"paragraph","content":"Quick-capture lands here.","children":[]}]'::jsonb)
ON CONFLICT (id) DO UPDATE SET content = EXCLUDED.content, title = EXCLUDED.title, updated_at = now();

-- Sprint Board with staggered due dates (F2 tasks / My Tasks). dueAt computed live.
INSERT INTO public.osionos_pages (id, workspace_id, parent_page_id, owner_id, title, icon, content)
SELECT 'dddddddd-0000-4000-8000-000000000004', :'ws', 'dddddddd-0000-4000-8000-000000000001', :'owner', 'Sprint Board', 'icon:check',
  jsonb_build_array(
    jsonb_build_object('id','s0','type','heading_2','content','Sprint Board','children','[]'::jsonb),
    jsonb_build_object('id','s1','type','to_do','content','Ship the FTS migration','checked',true,'children','[]'::jsonb),
    jsonb_build_object('id','s2','type','to_do','content','Fix the overdue reminder','checked',false,'dueAt',to_char(current_date - 1,'YYYY-MM-DD'),'children','[]'::jsonb),
    jsonb_build_object('id','s3','type','to_do','content','Review the comments PR','checked',false,'dueAt',to_char(current_date,'YYYY-MM-DD'),'children','[]'::jsonb),
    jsonb_build_object('id','s4','type','to_do','content','Plan the backlinks rollout','checked',false,'dueAt',to_char(current_date + 2,'YYYY-MM-DD'),'children','[]'::jsonb),
    jsonb_build_object('id','s5','type','to_do','content','Publish the launch page','checked',false,'dueAt',to_char(current_date + 7,'YYYY-MM-DD'),'children','[]'::jsonb))
ON CONFLICT (id) DO UPDATE SET content = EXCLUDED.content, updated_at = now();

-- Today's daily note under Daily Notes (F7).
INSERT INTO public.osionos_pages (id, workspace_id, parent_page_id, owner_id, title, content)
SELECT 'dddddddd-0000-4000-8000-000000000006', :'ws', 'dddddddd-0000-4000-8000-000000000005', :'owner', to_char(current_date,'YYYY-MM-DD'),
  '[{"id":"t1","type":"paragraph","content":"Captured: shipped the daily-driver wave.","children":[]}]'::jsonb
ON CONFLICT (id) DO UPDATE SET updated_at = now();

-- Favorites (F6) + comments (F8) — idempotent.
INSERT INTO public.osionos_page_favorites (user_id, page_id) VALUES
 (:'owner','dddddddd-0000-4000-8000-000000000001'),
 (:'owner','dddddddd-0000-4000-8000-000000000004')
ON CONFLICT (user_id, page_id) DO NOTHING;

DELETE FROM public.osionos_page_comments WHERE content LIKE 'demo:%';
INSERT INTO public.osionos_page_comments (page_id, author_id, content, resolved_at) VALUES
 ('dddddddd-0000-4000-8000-000000000002', :'owner', 'demo: should we cache the connection pool?', NULL),
 ('dddddddd-0000-4000-8000-000000000002', :'owner', 'demo: resolved — per-request pool is fine for now.', now());
