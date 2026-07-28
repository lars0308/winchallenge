-- WIN CHALLENGE: Mitteilungszentrum, Antworten, Benachrichtigungen und Team-Chat
-- Einmal im Supabase SQL Editor ausführen. Das Skript kann wiederholt ausgeführt werden.

create table if not exists public.app_messages (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid references public.profiles(id) on delete cascade,
  category text not null default 'news' check (category in ('news','patch','bugfix','games','challenges','shop','direct')),
  title text not null check (char_length(title) between 1 and 90),
  body text not null check (char_length(body) between 1 and 1500),
  created_at timestamptz not null default now()
);

create table if not exists public.app_message_replies (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.app_messages(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 800),
  created_at timestamptz not null default now()
);

create table if not exists public.player_notifications (
  id uuid primary key default gen_random_uuid(),
  target_user_id uuid not null references public.profiles(id) on delete cascade,
  from_user_id uuid references public.profiles(id) on delete set null,
  icon text,
  message text not null check (char_length(message) between 1 and 1200),
  created_at timestamptz not null default now()
);

create table if not exists public.team_messages (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

create index if not exists app_messages_created_at_idx on public.app_messages(created_at desc);
create index if not exists app_message_replies_message_id_idx on public.app_message_replies(message_id, created_at);
create index if not exists player_notifications_target_idx on public.player_notifications(target_user_id, created_at desc);
create index if not exists team_messages_team_id_idx on public.team_messages(team_id, created_at);

alter table public.app_messages enable row level security;
alter table public.app_message_replies enable row level security;
alter table public.player_notifications enable row level security;
alter table public.team_messages enable row level security;

-- Nachrichten lesen: globale Nachrichten, eigene Direktnachrichten, eigene Nachrichten sowie Admins.
drop policy if exists "messages: recipients read" on public.app_messages;
create policy "messages: recipients read" on public.app_messages for select to authenticated
using (
  recipient_id is null
  or recipient_id = (select auth.uid())
  or author_id = (select auth.uid())
  or exists (select 1 from public.profiles p where p.id = (select auth.uid()) and coalesce(p.is_admin,false))
);

drop policy if exists "messages: admins create" on public.app_messages;
create policy "messages: admins create" on public.app_messages for insert to authenticated
with check (
  author_id = (select auth.uid())
  and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and coalesce(p.is_admin,false))
);

drop policy if exists "messages: admins update" on public.app_messages;
create policy "messages: admins update" on public.app_messages for update to authenticated
using (exists (select 1 from public.profiles p where p.id = (select auth.uid()) and coalesce(p.is_admin,false)))
with check (exists (select 1 from public.profiles p where p.id = (select auth.uid()) and coalesce(p.is_admin,false)));

drop policy if exists "messages: admins delete" on public.app_messages;
create policy "messages: admins delete" on public.app_messages for delete to authenticated
using (exists (select 1 from public.profiles p where p.id = (select auth.uid()) and coalesce(p.is_admin,false)));

-- Antworten dürfen nur Personen schreiben, die die jeweilige Nachricht auch lesen können.
drop policy if exists "message replies: audience reads" on public.app_message_replies;
create policy "message replies: audience reads" on public.app_message_replies for select to authenticated
using (
  exists (
    select 1 from public.app_messages m
    where m.id = message_id
      and (m.recipient_id is null or m.recipient_id = (select auth.uid()) or m.author_id = (select auth.uid())
           or exists (select 1 from public.profiles p where p.id = (select auth.uid()) and coalesce(p.is_admin,false)))
  )
);

drop policy if exists "message replies: audience creates" on public.app_message_replies;
create policy "message replies: audience creates" on public.app_message_replies for insert to authenticated
with check (
  author_id = (select auth.uid())
  and exists (
    select 1 from public.app_messages m
    where m.id = message_id
      and (m.recipient_id is null or m.recipient_id = (select auth.uid()) or m.author_id = (select auth.uid())
           or exists (select 1 from public.profiles p where p.id = (select auth.uid()) and coalesce(p.is_admin,false)))
  )
);

-- System-/Spielerbenachrichtigungen: Ziel, Absender und Admins dürfen sie sehen.
drop policy if exists "player notifications: participants read" on public.player_notifications;
create policy "player notifications: participants read" on public.player_notifications for select to authenticated
using (
  target_user_id = (select auth.uid()) or from_user_id = (select auth.uid())
  or exists (select 1 from public.profiles p where p.id = (select auth.uid()) and coalesce(p.is_admin,false))
);

drop policy if exists "player notifications: sender creates" on public.player_notifications;
create policy "player notifications: sender creates" on public.player_notifications for insert to authenticated
with check (from_user_id = (select auth.uid()));

-- Team-Chat: ausschließlich aktuelle Teammitglieder dürfen lesen und schreiben.
drop policy if exists "team messages: members read" on public.team_messages;
create policy "team messages: members read" on public.team_messages for select to authenticated
using (exists (select 1 from public.team_members tm where tm.team_id = team_messages.team_id and tm.user_id = (select auth.uid())));

drop policy if exists "team messages: members create" on public.team_messages;
create policy "team messages: members create" on public.team_messages for insert to authenticated
with check (
  author_id = (select auth.uid())
  and exists (select 1 from public.team_members tm where tm.team_id = team_messages.team_id and tm.user_id = (select auth.uid()))
);

grant select, insert, update, delete on public.app_messages to authenticated;
grant select, insert on public.app_message_replies to authenticated;
grant select, insert on public.player_notifications to authenticated;
grant select, insert on public.team_messages to authenticated;

-- Realtime: Tabellen erscheinen live in Mitteilungszentrum und Team-Chat.
do $$
declare t text;
begin
  foreach t in array array['app_messages','app_message_replies','player_notifications','team_messages'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end;
$$;
