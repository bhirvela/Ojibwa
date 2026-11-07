-- Camp Ojibwa Leaderboard — database schema (Supabase / Postgres 15+)
--
-- Run once in the Supabase SQL Editor on a new project.
-- Security model: the browser only ever holds the public "anon" key, so every
-- permission below is enforced here with Row Level Security (RLS), never in the page.
--
--   Parents (anon)     read sessions marked public; never see deleted results.
--   Scorers (staff)    log results and rounds while a session is 'live';
--                      can correct only what they logged.
--   Admins  (staff)    everything: session setup, teams, events, points, staff, deletes.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- types
create type public.level       as enum ('SV', 'JV', 'Prep', 'Team', 'Special');
create type public.staff_role  as enum ('admin', 'scorer');
create type public.result_kind as enum ('matchup', 'placement', 'adjustment');
create type public.session_status as enum ('setup', 'live', 'final', 'archived');

-- ---------------------------------------------------------------- staff
-- One row per approved counselor/staff login. The first admin is inserted by hand
-- in the SQL Editor (see docs/SETUP.md); after that admins manage this table in the app.
create table public.staff (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  role         public.staff_role not null default 'scorer',
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff where user_id = auth.uid() and active);
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff
                 where user_id = auth.uid() and active and role = 'admin');
$$;

-- ---------------------------------------------------------------- sessions
create table public.sessions (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,                       -- e.g. "The Week 2027"
  start_date date,
  end_date   date,
  status     public.session_status not null default 'setup',
  is_public  boolean not null default false,      -- parents can see it
  created_at timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);

create or replace function public.session_visible(p_session uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_staff()
      or exists (select 1 from public.sessions where id = p_session and is_public);
$$;

create or replace function public.session_live(p_session uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.sessions where id = p_session and status = 'live');
$$;

-- ---------------------------------------------------------------- session setup
create table public.teams (
  id              uuid primary key default gen_random_uuid(),
  session_id      uuid not null references public.sessions (id) on delete cascade,
  name            text not null,
  short_name      text,
  primary_color   text not null default '#555555' check (primary_color   ~ '^#[0-9A-Fa-f]{6}$'),
  secondary_color text not null default '#DDDDDD' check (secondary_color ~ '^#[0-9A-Fa-f]{6}$'),
  sort_order      int  not null default 0,
  unique (session_id, name),
  unique (id, session_id)                         -- target for same-session foreign keys
);

-- Regular events (Basketball, Tug of War, ...) are played at SV/JV/Prep/Team.
-- Special events (Song, Swimming, ...) are placements at the Special level.
create table public.event_types (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions (id) on delete cascade,
  name       text not null,
  is_special boolean not null default false,
  sort_order int not null default 0,
  unique (session_id, name),
  unique (id, session_id)
);

-- Default points per level, optionally overridden for one event type
-- (e.g. Team = 15, but Team + Tug of War = 20). Special usually has no rule: entered per place.
create table public.point_rules (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references public.sessions (id) on delete cascade,
  level         public.level not null,
  event_type_id uuid,
  points        numeric not null check (points >= 0),
  foreign key (event_type_id, session_id) references public.event_types (id, session_id) on delete cascade,
  unique nulls not distinct (session_id, level, event_type_id)
);

create or replace function public.default_points(p_session uuid, p_level public.level, p_event_type uuid)
returns numeric language sql stable set search_path = '' as $$
  select points from public.point_rules
   where session_id = p_session and level = p_level
     and (event_type_id = p_event_type or event_type_id is null)
   order by event_type_id nulls last
   limit 1;
$$;

-- ---------------------------------------------------------------- rounds & results
create table public.rounds (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions (id) on delete cascade,
  number     int  not null check (number > 0),   -- the "Event #" staff call out
  day        date not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique (session_id, number),
  unique (id, session_id)
);

create table public.results (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null,
  round_id      uuid not null,
  level         public.level not null,
  event_type_id uuid not null,
  kind          public.result_kind not null,
  winner_team_id uuid,                            -- matchup only
  loser_team_id  uuid,                            -- matchup only
  is_tie        boolean not null default false,  -- matchup only: no W/L recorded
  note          text,
  replaces_id   uuid references public.results (id),  -- an edit = new row replacing old
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  deleted_by    uuid,
  foreign key (session_id) references public.sessions (id) on delete cascade,
  foreign key (round_id, session_id)       references public.rounds (id, session_id) on delete cascade,
  foreign key (event_type_id, session_id)  references public.event_types (id, session_id),
  foreign key (winner_team_id, session_id) references public.teams (id, session_id),
  foreign key (loser_team_id, session_id)  references public.teams (id, session_id),
  check (kind <> 'matchup' or (winner_team_id is not null and loser_team_id is not null
                               and winner_team_id <> loser_team_id)),
  check (kind =  'matchup' or (winner_team_id is null and loser_team_id is null and not is_tie)),
  check (kind <> 'placement' or level = 'Special'),
  check (kind <> 'adjustment' or coalesce(trim(note), '') <> '')
);
create index on public.results (session_id) where deleted_at is null;

-- Points actually awarded. One row per team that scored from a result; ties and
-- split points (2.5 + 2.5) are just two awards.
create table public.awards (
  id         uuid primary key default gen_random_uuid(),
  result_id  uuid not null references public.results (id) on delete cascade,
  session_id uuid not null,
  team_id    uuid not null,
  points     numeric not null default 0,
  extras     numeric not null default 0,
  place      int check (place > 0),               -- Special placements
  foreign key (team_id, session_id) references public.teams (id, session_id),
  unique (result_id, team_id)
);
create index on public.awards (session_id);

-- ---------------------------------------------------------------- audit log
create table public.audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      uuid default auth.uid(),
  table_name text not null,
  action     text not null,
  old_row    jsonb,
  new_row    jsonb
);

create or replace function public.audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_log (table_name, action, old_row, new_row)
  values (tg_table_name, tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create trigger audit_results after insert or update or delete on public.results
  for each row execute function public.audit();
create trigger audit_awards  after insert or update or delete on public.awards
  for each row execute function public.audit();
create trigger audit_teams   after insert or update or delete on public.teams
  for each row execute function public.audit();
create trigger audit_staff   after insert or update or delete on public.staff
  for each row execute function public.audit();

-- ---------------------------------------------------------------- write API
-- Logs one result and its awards in a single transaction (creating the round if
-- needed). This is the ONLY way results and awards are written: the tables
-- themselves are read-only to the browser, so every rule below always applies.
--
-- p_awards: [{"team_id": "...", "points": 15, "extras": 0, "place": 1}, ...]
create or replace function public.save_result(
  p_session      uuid,
  p_round_number int,
  p_day          date,
  p_level        public.level,
  p_event_type   uuid,
  p_kind         public.result_kind,
  p_awards       jsonb,
  p_winner       uuid    default null,
  p_loser        uuid    default null,
  p_is_tie       boolean default false,
  p_note         text    default null,
  p_replaces     uuid    default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_round  uuid;
  v_result uuid;
  v_special boolean;
  a jsonb;
begin
  if not public.is_staff() then
    raise exception 'Only signed-in staff can log results' using errcode = '42501';
  end if;
  if not public.session_live(p_session) then
    raise exception 'This session is not live' using errcode = '42501';
  end if;

  select is_special into v_special from public.event_types
   where id = p_event_type and session_id = p_session;
  if v_special is null then
    raise exception 'Unknown event for this session';
  elsif v_special <> (p_level = 'Special') then
    raise exception 'Special events are logged at the Special level only';
  end if;

  if jsonb_typeof(p_awards) <> 'array' or jsonb_array_length(p_awards) = 0 then
    raise exception 'At least one award is required';
  end if;
  if p_kind = 'matchup' then
    for a in select * from jsonb_array_elements(p_awards) loop
      if (a->>'team_id')::uuid not in (p_winner, p_loser) then
        raise exception 'Matchup points can only go to the two teams that played';
      end if;
    end loop;
  elsif p_kind = 'adjustment' and jsonb_array_length(p_awards) <> 1 then
    raise exception 'An adjustment applies to exactly one team';
  end if;

  select id into v_round from public.rounds
   where session_id = p_session and number = p_round_number;
  if v_round is null then
    insert into public.rounds (session_id, number, day, created_by)
    values (p_session, p_round_number, p_day, auth.uid()) returning id into v_round;
  end if;

  if p_replaces is not null then
    update public.results set deleted_at = now(), deleted_by = auth.uid()
     where id = p_replaces and session_id = p_session and deleted_at is null
       and (public.is_admin() or created_by = auth.uid());
    if not found then
      raise exception 'The result being corrected was not found or you cannot change it';
    end if;
  end if;

  insert into public.results (session_id, round_id, level, event_type_id, kind,
                              winner_team_id, loser_team_id, is_tie, note, replaces_id, created_by)
  values (p_session, v_round, p_level, p_event_type, p_kind,
          p_winner, p_loser, coalesce(p_is_tie, false), p_note, p_replaces, auth.uid())
  returning id into v_result;

  insert into public.awards (result_id, session_id, team_id, points, extras, place)
  select v_result, p_session, (x->>'team_id')::uuid,
         coalesce((x->>'points')::numeric, 0), coalesce((x->>'extras')::numeric, 0),
         (x->>'place')::int
    from jsonb_array_elements(p_awards) x;

  return v_result;
end $$;

-- Soft delete (hidden from parents and standings, kept in the audit trail).
-- Admins can delete anything; scorers only their own entries while the session is live.
create or replace function public.delete_result(p_result uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.results r set deleted_at = now(), deleted_by = auth.uid()
   where r.id = p_result and r.deleted_at is null
     and (public.is_admin()
          or (public.is_staff() and r.created_by = auth.uid() and public.session_live(r.session_id)));
  if not found then
    raise exception 'Result not found or you cannot delete it' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------- read API
create view public.standings with (security_invoker = true) as
select t.session_id,
       t.id   as team_id,
       t.name as team_name,
       t.primary_color,
       t.secondary_color,
       coalesce(sum(a.points + a.extras) filter (where r.id is not null and r.deleted_at is null), 0) as total
  from public.teams t
  left join public.awards  a on a.team_id = t.id
  left join public.results r on r.id = a.result_id
 group by t.id;

-- ---------------------------------------------------------------- row level security
alter table public.staff       enable row level security;
alter table public.sessions    enable row level security;
alter table public.teams       enable row level security;
alter table public.event_types enable row level security;
alter table public.point_rules enable row level security;
alter table public.rounds      enable row level security;
alter table public.results     enable row level security;
alter table public.awards      enable row level security;
alter table public.audit_log   enable row level security;

-- staff: staff can see who's on staff; only admins change it
create policy staff_read  on public.staff for select using (public.is_staff());
create policy staff_admin on public.staff for all    using (public.is_admin()) with check (public.is_admin());

-- sessions
create policy sessions_read  on public.sessions for select using (is_public or public.is_staff());
create policy sessions_admin on public.sessions for all    using (public.is_admin()) with check (public.is_admin());

-- setup tables: readable with their session, admin-only writes
create policy teams_read        on public.teams       for select using (public.session_visible(session_id));
create policy teams_admin       on public.teams       for all    using (public.is_admin()) with check (public.is_admin());
create policy event_types_read  on public.event_types for select using (public.session_visible(session_id));
create policy event_types_admin on public.event_types for all    using (public.is_admin()) with check (public.is_admin());
create policy point_rules_read  on public.point_rules for select using (public.session_visible(session_id));
create policy point_rules_admin on public.point_rules for all    using (public.is_admin()) with check (public.is_admin());

-- rounds: created by save_result; admins can fix a round's number or day
create policy rounds_read  on public.rounds for select using (public.session_visible(session_id));
create policy rounds_admin on public.rounds for all using (public.is_admin()) with check (public.is_admin());

-- results & awards: read-only tables (writes go through save_result / delete_result).
-- Parents see non-deleted results of public sessions; staff see everything.
create policy results_read on public.results for select
  using (public.is_staff() or (deleted_at is null and public.session_visible(session_id)));
create policy awards_read on public.awards for select
  using (exists (select 1 from public.results r where r.id = result_id));  -- results RLS applies

-- audit log: admins only
create policy audit_read on public.audit_log for select using (public.is_admin());

-- ---------------------------------------------------------------- privileges
-- Supabase grants table access to anon/authenticated by default; RLS above is the gate.
-- Make the intent explicit and keep parents off things they never need.
revoke all on public.audit_log from anon;
revoke all on public.staff     from anon;
revoke insert, update, delete on all tables in schema public from anon;
revoke insert, update, delete on public.results, public.awards, public.audit_log from authenticated;
revoke execute on function public.save_result, public.delete_result from anon, public;
grant  execute on function public.save_result, public.delete_result to authenticated;
grant  select on public.standings to anon, authenticated;

-- ---------------------------------------------------------------- realtime
-- Live updates for the public board and scorer screens.
alter publication supabase_realtime add table public.rounds, public.results, public.awards;
