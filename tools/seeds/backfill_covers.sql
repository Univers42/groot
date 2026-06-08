BEGIN;
UPDATE public.osionos_pages f
SET cover = CASE
  WHEN parent.title ILIKE '%algorithm%'                                THEN 'https://images.unsplash.com/photo-1526374965328-7f61d4dc18c5?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%data structure%'                           THEN 'https://images.unsplash.com/photo-1635070041078-e363dbe005cb?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%language%'                                 THEN 'https://images.unsplash.com/photo-1487058792275-0ad4aaf24ca7?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%paradigm%'                                 THEN 'https://images.unsplash.com/photo-1517077304055-6e89abbf09b0?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%distributed%'                              THEN 'https://images.unsplash.com/photo-1451187580459-43490279c0fa?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%scalab%' OR parent.title ILIKE '%performance%' THEN 'https://images.unsplash.com/photo-1564865878688-9a244444042a?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%resilien%'                                 THEN 'https://images.unsplash.com/photo-1550751827-4bd374c3f58b?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%reliab%' OR parent.title ILIKE '%ops%'     THEN 'https://images.unsplash.com/photo-1504384308090-c894fdcc538d?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%system%'                                   THEN 'https://images.unsplash.com/photo-1558494949-ef010cbdcc31?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%complex%'                                  THEN 'https://images.unsplash.com/photo-1639322537228-f710d846310a?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%design%'                                   THEN 'https://images.unsplash.com/photo-1542831371-29b0f74f9713?auto=format&fit=crop&w=1200&q=80'
  WHEN parent.title ILIKE '%component%' OR parent.title ILIKE '%gallery%' THEN 'https://images.unsplash.com/photo-1518770660439-4636190af475?auto=format&fit=crop&w=1200&q=80'
  ELSE 'https://images.unsplash.com/photo-1517077304055-6e89abbf09b0?auto=format&fit=crop&w=1200&q=80'
END
FROM public.osionos_pages parent
WHERE f.workspace_id='3f009d03-d954-5e35-85b8-db5c37aa859f' AND f.surface IS NULL AND f.archived_at IS NULL
  AND (f.cover IS NULL OR f.cover = '') AND f.parent_page_id = parent.id;

UPDATE public.osionos_pages
SET cover = 'https://images.unsplash.com/photo-1517077304055-6e89abbf09b0?auto=format&fit=crop&w=1200&q=80'
WHERE workspace_id='3f009d03-d954-5e35-85b8-db5c37aa859f' AND surface IS NULL AND archived_at IS NULL AND (cover IS NULL OR cover = '');
COMMIT;
