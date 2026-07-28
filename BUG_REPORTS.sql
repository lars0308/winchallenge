-- WIN CHALLENGE: Bug-Reports, Antworten und Admin-Belohnungen
-- Einmal im Supabase SQL Editor ausführen.

create table if not exists public.bug_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reporter_name text,
  title text not null check (char_length(title) between 3 and 100),
  body text not null check (char_length(body) between 5 and 1500),
  status text not null default 'open' check (status in ('open','reviewed','fixed','closed')),
  admin_feedback text,
  reward_coins integer not null default 0 check (reward_coins between 0 and 500),
  rewarded boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.touch_bug_report_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists bug_reports_touch_updated_at on public.bug_reports;
create trigger bug_reports_touch_updated_at
before update on public.bug_reports
for each row execute function public.touch_bug_report_updated_at();

alter table public.bug_reports enable row level security;

drop policy if exists "bug reports: reporter reads own" on public.bug_reports;
create policy "bug reports: reporter reads own"
on public.bug_reports for select to authenticated
using ((select auth.uid()) = reporter_id);

drop policy if exists "bug reports: reporter creates own" on public.bug_reports;
create policy "bug reports: reporter creates own"
on public.bug_reports for insert to authenticated
with check ((select auth.uid()) = reporter_id);

drop policy if exists "bug reports: admins manage" on public.bug_reports;
create policy "bug reports: admins manage"
on public.bug_reports for all to authenticated
using (exists (select 1 from public.profiles p where p.id=(select auth.uid()) and coalesce(p.is_admin,false)))
with check (exists (select 1 from public.profiles p where p.id=(select auth.uid()) and coalesce(p.is_admin,false)));

grant select, insert, update on public.bug_reports to authenticated;

-- Live-Aktualisierungen für Reporter und Admins.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bug_reports'
  ) then
    alter publication supabase_realtime add table public.bug_reports;
  end if;
end;
$$;
