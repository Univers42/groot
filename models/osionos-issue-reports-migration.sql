-- osionos_issue_reports — what users report from "Report an issue", read by staff in
-- the Issues panel and turned into a GitHub issue by a person (a prefilled link the
-- developer submits; nothing here talks to GitHub).
--
-- The bridge (service_role) is the only reader and writer: it stamps reporter_id from
-- the verified app-session token, shows a reporter only their own rows, and shows
-- every row to platform moderators and admins. A report holds no page content: a
-- title, the reporter's own text, the KIND of screen it came from, and an optional
-- screenshot the reporter picked and saw before sending (a capability path of the
-- existing page-media upload).

create extension if not exists "pgcrypto";

create table if not exists public.osionos_issue_reports (
	id              uuid primary key default gen_random_uuid(),
	reporter_id     uuid not null references auth.users (id) on delete cascade,
	workspace_id    uuid references public.osionos_workspaces (id) on delete set null,
	title           text not null
		check (char_length(title) between 1 and 120 and title !~ '[[:cntrl:]]'),
	body            text not null
		check (char_length(body) between 1 and 4000 and body !~ '[\x00-\x09\x0B-\x1F\x7F]'),
	route_kind      text not null
		check (route_kind in ('page', 'database', 'chat', 'settings', 'admin', 'other')),
	app_version     text check (app_version is null or (char_length(app_version) <= 64 and app_version !~ '[[:cntrl:]]')),
	user_agent      text check (user_agent is null or (char_length(user_agent) <= 300 and user_agent !~ '[[:cntrl:]]')),
	-- The redacted frontend errors a developer attached: at most 20 strings.
	errors          jsonb not null default '[]'::jsonb
		check (jsonb_typeof(errors) = 'array' and jsonb_array_length(errors) <= 20),
	screenshot_path text
		check (screenshot_path is null or screenshot_path ~ '^/api/media/uploads/[0-9a-f-]{36}/[0-9a-f]{64}\.(png|jpe?g|webp)$'),
	status          text not null default 'open'
		check (status in ('open', 'triaged', 'sent', 'closed')),
	github_url      text check (github_url is null or github_url ~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+$'),
	created_at      timestamptz not null default now(),
	updated_at      timestamptz not null default now()
);

create index if not exists osionos_issue_reports_reporter_idx
	on public.osionos_issue_reports (reporter_id, created_at desc);
create index if not exists osionos_issue_reports_status_idx
	on public.osionos_issue_reports (status, created_at desc);

alter table public.osionos_issue_reports enable row level security;

drop policy if exists osionos_issue_reports_service_role_all
	on public.osionos_issue_reports;
create policy osionos_issue_reports_service_role_all
	on public.osionos_issue_reports for all
	to service_role using (true) with check (true);

grant all on public.osionos_issue_reports to service_role;

-- One report, with the daily cap of its reporter checked in the same statement.
-- Caveat: two reports sent in the same instant by one reporter can both pass at
-- 19, so the cap is 20 a day give or take the number of concurrent sends; it
-- bounds abuse, it is not an exact quota.
create or replace function public.osionos_issue_report_create(
	p_reporter uuid,
	p_workspace uuid,
	p_title text,
	p_body text,
	p_route_kind text,
	p_app_version text,
	p_user_agent text,
	p_errors jsonb,
	p_screenshot_path text
) returns public.osionos_issue_reports
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
	created public.osionos_issue_reports;
begin
	if (select count(*) from public.osionos_issue_reports
		where reporter_id = p_reporter and created_at > now() - interval '1 day') >= 20 then
		raise exception 'daily report limit reached' using errcode = 'P0001', hint = 'issue_report_daily_cap';
	end if;
	insert into public.osionos_issue_reports
		(reporter_id, workspace_id, title, body, route_kind, app_version, user_agent, errors, screenshot_path)
	values
		(p_reporter, p_workspace, p_title, p_body, p_route_kind, p_app_version, p_user_agent,
		 coalesce(p_errors, '[]'::jsonb), p_screenshot_path)
	returning * into created;
	return created;
end;
$$;

revoke all on function public.osionos_issue_report_create(uuid, uuid, text, text, text, text, text, jsonb, text) from public;
grant execute on function public.osionos_issue_report_create(uuid, uuid, text, text, text, text, text, jsonb, text) to service_role;

notify pgrst, 'reload schema';
