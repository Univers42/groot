-- osionos: vertical focal point (%) for page cover images.
-- A cover is drawn with object-fit: cover, so when it is taller than its frame
-- only a slice shows; cover_position is the CSS object-position focal % (0=top,
-- 50=centered, 100=bottom). Nullable → NULL means "centered" (the default).
-- Idempotent; applied to mini-baas-postgres alongside the other osionos-* SQL.

ALTER TABLE public.osionos_pages
  ADD COLUMN IF NOT EXISTS cover_position real;
