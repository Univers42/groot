-- Stand-ins for what GoTrue (auth.users) and later grobase migrations provide on a real stack.
CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb);
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS display_name text;
CREATE UNIQUE INDEX IF NOT EXISTS user_profiles_user_id_key ON public.user_profiles(user_id);