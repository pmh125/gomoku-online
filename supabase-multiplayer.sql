-- Gomoku room membership for Supabase RPC + Broadcast.
-- Run this file once in Supabase Dashboard -> SQL Editor.

create table if not exists public.gomoku_members (
  room_code text not null check (room_code ~ '^[A-Z0-9]{6}$'),
  session_id text not null check (char_length(session_id) between 10 and 100),
  role text not null check (role in ('black', 'white', 'spectator')),
  last_seen timestamptz not null default now(),
  primary key (room_code, session_id)
);

alter table public.gomoku_members
  add column if not exists display_name text not null default '匿名棋手';

create index if not exists gomoku_members_room_seen_idx
  on public.gomoku_members (room_code, last_seen desc);

create unique index if not exists gomoku_members_one_black_idx
  on public.gomoku_members (room_code) where role = 'black';

create unique index if not exists gomoku_members_one_white_idx
  on public.gomoku_members (room_code) where role = 'white';

alter table public.gomoku_members enable row level security;

create or replace function public.gomoku_room_members(p_room_code text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object('session_id', session_id, 'role', role, 'display_name', display_name, 'last_seen', last_seen)
      order by role, session_id
    ),
    '[]'::jsonb
  )
  from public.gomoku_members
  where room_code = upper(trim(p_room_code))
    and last_seen >= now() - interval '45 seconds';
$$;

create or replace function public.get_gomoku_room_members(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.gomoku_members
  where room_code = upper(trim(p_room_code))
    and last_seen < now() - interval '45 seconds';
  return public.gomoku_room_members(p_room_code);
end;
$$;

create or replace function public.join_gomoku_room(
  p_room_code text,
  p_session_id text,
  p_role text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(trim(p_room_code));
  v_role text := lower(trim(p_role));
  v_existing_role text;
  v_members jsonb;
begin
  if v_code !~ '^[A-Z0-9]{6}$' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_room');
  end if;
  if p_session_id is null or char_length(p_session_id) not between 10 and 100 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_session');
  end if;
  if v_role not in ('black', 'white', 'spectator') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_role');
  end if;

  delete from public.gomoku_members
  where room_code = v_code
    and last_seen < now() - interval '45 seconds';

  select role into v_existing_role
  from public.gomoku_members
  where room_code = v_code and session_id = p_session_id;

  -- A new visitor who enters as spectator receives the first available seat.
  -- Existing members can still explicitly switch to spectator before the first move.
  if v_role = 'spectator' and v_existing_role is null then
    if not exists (select 1 from public.gomoku_members where room_code = v_code and role = 'black') then
      v_role := 'black';
    elsif not exists (select 1 from public.gomoku_members where room_code = v_code and role = 'white') then
      v_role := 'white';
    end if;
  end if;

  if v_role in ('black', 'white') and exists (
    select 1 from public.gomoku_members
    where room_code = v_code and role = v_role and session_id <> p_session_id
  ) then
    return jsonb_build_object('ok', false, 'reason', 'seat_taken', 'members', public.gomoku_room_members(v_code));
  end if;

  insert into public.gomoku_members(room_code, session_id, role, last_seen)
  values (v_code, p_session_id, v_role, now())
  on conflict (room_code, session_id)
  do update set role = excluded.role, last_seen = excluded.last_seen;

  v_members := public.gomoku_room_members(v_code);
  return jsonb_build_object('ok', true, 'role', v_role, 'members', v_members);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'seat_taken', 'members', public.gomoku_room_members(v_code));
end;
$$;

create or replace function public.set_gomoku_display_name(
  p_room_code text,
  p_session_id text,
  p_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := left(trim(coalesce(p_display_name, '')), 16);
begin
  if v_name = '' then v_name := '匿名棋手'; end if;
  update public.gomoku_members
  set display_name = v_name, last_seen = now()
  where room_code = upper(trim(p_room_code)) and session_id = p_session_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_in_room');
  end if;
  return jsonb_build_object('ok', true, 'display_name', v_name, 'members', public.gomoku_room_members(p_room_code));
end;
$$;

create or replace function public.heartbeat_gomoku_room(p_room_code text, p_session_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.gomoku_members
  set last_seen = now()
  where room_code = upper(trim(p_room_code)) and session_id = p_session_id;
  return public.gomoku_room_members(p_room_code);
end;
$$;

create or replace function public.leave_gomoku_room(p_room_code text, p_session_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.gomoku_members
  where room_code = upper(trim(p_room_code)) and session_id = p_session_id;
  return true;
end;
$$;

grant execute on function public.gomoku_room_members(text) to anon, authenticated;
grant execute on function public.get_gomoku_room_members(text) to anon, authenticated;
grant execute on function public.join_gomoku_room(text, text, text) to anon, authenticated;
grant execute on function public.set_gomoku_display_name(text, text, text) to anon, authenticated;
grant execute on function public.heartbeat_gomoku_room(text, text) to anon, authenticated;
grant execute on function public.leave_gomoku_room(text, text) to anon, authenticated;
