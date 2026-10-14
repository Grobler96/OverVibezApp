-- 054: creator vs creator battles in live streams.
-- Two creators who are both live face off for a few minutes. Each side's score is the value of the vibes (gifts)
-- their own live audience sends during the round. Highest score wins. Nobody loses their gifts: creators keep
-- everything they earn as normal, the battle only decides who gets the crown.

create table if not exists public.live_battles (
  id uuid primary key default gen_random_uuid(),
  stream_a uuid not null references public.live_streams(id) on delete cascade,   -- the creator who challenged
  stream_b uuid not null references public.live_streams(id) on delete cascade,   -- the creator who was challenged
  creator_a uuid not null references public.profiles(id) on delete cascade,
  creator_b uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'invited' check (status in ('invited','active','ended','declined','cancelled','expired')),
  minutes int not null check (minutes in (3, 5, 10)),
  invited_at timestamptz not null default now(),
  started_at timestamptz,
  ends_at timestamptz,
  ended_at timestamptz,
  score_a int,
  score_b int,
  winner uuid references public.profiles(id) on delete set null,
  check (stream_a <> stream_b)
);
create index if not exists live_battles_a_idx on public.live_battles (stream_a, status);
create index if not exists live_battles_b_idx on public.live_battles (stream_b, status);
alter table public.live_battles enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'live_battles' and policyname = 'live_battles_read') then
    create policy live_battles_read on public.live_battles for select
      using (auth.uid() in (creator_a, creator_b) or public.live_can_watch(stream_a) or public.live_can_watch(stream_b));
  end if;
end $$;
revoke all on public.live_battles from anon, authenticated;
grant select on public.live_battles to authenticated;
alter publication supabase_realtime add table public.live_battles;

-- Score of one side: the vibes its own audience sent while the round was running.
create or replace function public._battle_side(p_stream uuid, p_from timestamptz, p_to timestamptz) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(cents), 0)::int from live_vibes where stream_id = p_stream and p_from is not null
    and created_at >= p_from and created_at <= least(coalesce(p_to, now()), now());
$$;

create or replace function public._battle_json(b live_battles) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a int; c int;
begin
  if b.status = 'ended' then a := coalesce(b.score_a, 0); c := coalesce(b.score_b, 0);
  else a := _battle_side(b.stream_a, b.started_at, b.ends_at); c := _battle_side(b.stream_b, b.started_at, b.ends_at); end if;
  return jsonb_build_object('id', b.id, 'status', b.status, 'minutes', b.minutes, 'stream_a', b.stream_a, 'stream_b', b.stream_b,
    'creator_a', b.creator_a, 'creator_b', b.creator_b, 'started_at', b.started_at, 'ends_at', b.ends_at, 'score_a', a, 'score_b', c,
    'winner', b.winner, 'now', clock_timestamp());
end $$;

create or replace function public._battle_can_see(b live_battles) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (auth.uid() in (b.creator_a, b.creator_b) or public.live_can_watch(b.stream_a) or public.live_can_watch(b.stream_b));
$$;

-- Challenge another live creator.
create or replace function public.battle_invite(p_stream uuid, p_target uuid, p_minutes int) returns uuid
language plpgsql security definer set search_path = public as $$
declare me live_streams%rowtype; tg live_streams%rowtype; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  perform _require_adult();
  if not not_banned() then raise exception 'Your account is restricted'; end if;
  if p_minutes not in (3, 5, 10) then raise exception 'Pick 3, 5 or 10 minutes'; end if;
  select * into me from live_streams where id = p_stream and creator_id = auth.uid() and status = 'live';
  if not found then raise exception 'You need to be live to start a battle'; end if;
  select * into tg from live_streams where id = p_target and status = 'live' and last_seen_at > now() - interval '3 minutes';
  if not found then raise exception 'That creator is not live right now'; end if;
  if tg.creator_id = auth.uid() then raise exception 'You cannot battle yourself'; end if;
  if is_blocked_between(auth.uid(), tg.creator_id) then raise exception 'You cannot battle this creator'; end if;
  if exists (select 1 from live_battles where status in ('invited','active')
              and (stream_a in (p_stream, p_target) or stream_b in (p_stream, p_target))) then
    raise exception 'One of you is already in a battle';
  end if;
  if (select count(*) from live_battles where creator_a = auth.uid() and invited_at > now() - interval '10 minutes') >= 6 then
    raise exception 'That is a lot of challenges, give it a few minutes';
  end if;
  insert into live_battles(stream_a, stream_b, creator_a, creator_b, minutes)
    values (p_stream, p_target, auth.uid(), tg.creator_id, p_minutes) returning id into v_id;
  perform _notify(tg.creator_id, auth.uid(), 'battle_invite', v_id, jsonb_build_object('minutes', p_minutes));
  return v_id;
end $$;

create or replace function public.battle_respond(p_battle uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b live_battles%rowtype;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into b from live_battles where id = p_battle and creator_b = auth.uid() and status = 'invited' for update;
  if not found or b.invited_at < now() - interval '90 seconds' then raise exception 'This challenge has expired'; end if;
  if not coalesce(p_accept, false) then
    update live_battles set status = 'declined' where id = p_battle returning * into b;
    return _battle_json(b);
  end if;
  if (select count(*) from live_streams where id in (b.stream_a, b.stream_b) and status = 'live') < 2 then
    update live_battles set status = 'expired' where id = p_battle;
    raise exception 'One of you is no longer live';
  end if;
  update live_battles set status = 'active', started_at = clock_timestamp() + interval '5 seconds',
         ends_at = clock_timestamp() + interval '5 seconds' + make_interval(mins => minutes)
   where id = p_battle returning * into b;
  return _battle_json(b);
end $$;

create or replace function public.battle_cancel(p_battle uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update live_battles set status = 'cancelled' where id = p_battle and creator_a = auth.uid() and status = 'invited';
end $$;

-- Close a battle when its time is up, or when either creator has ended their live (the one who left forfeits).
create or replace function public._battle_close(p_battle uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b live_battles%rowtype; sa int; sb int; w uuid; a_live boolean; b_live boolean;
begin
  select * into b from live_battles where id = p_battle for update;
  if not found then return null; end if;
  if b.status <> 'active' then return _battle_json(b); end if;
  select (status = 'live') into a_live from live_streams where id = b.stream_a;
  select (status = 'live') into b_live from live_streams where id = b.stream_b;
  if clock_timestamp() < b.ends_at and coalesce(a_live, false) and coalesce(b_live, false) then return _battle_json(b); end if;
  sa := _battle_side(b.stream_a, b.started_at, b.ends_at); sb := _battle_side(b.stream_b, b.started_at, b.ends_at);
  if clock_timestamp() < b.ends_at and not coalesce(a_live, false) and coalesce(b_live, false) then w := b.creator_b;
  elsif clock_timestamp() < b.ends_at and not coalesce(b_live, false) and coalesce(a_live, false) then w := b.creator_a;
  elsif sa > sb then w := b.creator_a; elsif sb > sa then w := b.creator_b; else w := null; end if;
  update live_battles set status = 'ended', ended_at = clock_timestamp(), score_a = sa, score_b = sb, winner = w where id = p_battle returning * into b;
  return _battle_json(b);
end $$;

create or replace function public.battle_finish(p_battle uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b live_battles%rowtype;
begin
  select * into b from live_battles where id = p_battle;
  if not found or not _battle_can_see(b) then raise exception 'Battle not found'; end if;
  return _battle_close(p_battle);
end $$;

create or replace function public.battle_scores(p_battle uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b live_battles%rowtype;
begin
  select * into b from live_battles where id = p_battle;
  if not found or not _battle_can_see(b) then raise exception 'Battle not found'; end if;
  return _battle_json(b);
end $$;

-- The challenge or battle happening in a live right now (for people who join halfway through).
create or replace function public.battle_active(p_stream uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b live_battles%rowtype;
begin
  select * into b from live_battles where (stream_a = p_stream or stream_b = p_stream)
     and (status = 'active' or (status = 'invited' and invited_at > now() - interval '90 seconds')) order by invited_at desc limit 1;
  if not found or not _battle_can_see(b) then return null; end if;
  return _battle_json(b);
end $$;

-- Lets someone in one live watch the other creator during a battle (subscribe only, never publish).
create or replace function public.live_battle_access(p_battle uuid, p_stream uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b live_battles%rowtype; s live_streams%rowtype; v_other uuid;
begin
  perform _require_adult();
  select * into b from live_battles where id = p_battle and status = 'active' and ends_at > now() - interval '30 seconds';
  if not found then raise exception 'This battle is not on'; end if;
  if p_stream not in (b.stream_a, b.stream_b) then raise exception 'This battle is not on'; end if;
  v_other := case when p_stream = b.stream_a then b.stream_b else b.stream_a end;
  select * into s from live_streams where id = p_stream and status = 'live';
  if not found then raise exception 'This stream is not live'; end if;
  if not (auth.uid() in (b.creator_a, b.creator_b) or live_can_watch(v_other) or is_admin()) then raise exception 'This battle is not on'; end if;
  return jsonb_build_object('room', s.room_name, 'role', 'viewer', 'title', s.title);
end $$;

-- Housekeeping every 10 seconds: expire unanswered challenges and finish battles whose time is up.
create or replace function public.battle_sweep() returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  update live_battles set status = 'expired' where status = 'invited' and invited_at < now() - interval '90 seconds';
  for r in select id from live_battles where status = 'active' loop perform _battle_close(r.id); end loop;
end $$;

create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured','weekly_summary','download_request','download_ok','download_no') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result','battle_invite') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help','age_nudge','held','held_ok','scan_held','urgent_report','referral_reward') then 'account'
    else null end;
$$;

revoke execute on function public._battle_side(uuid, timestamptz, timestamptz), public._battle_json(live_battles), public._battle_can_see(live_battles),
  public._battle_close(uuid), public.battle_sweep() from public, anon, authenticated;
revoke execute on function public.battle_invite(uuid, uuid, int), public.battle_respond(uuid, boolean), public.battle_cancel(uuid), public.battle_finish(uuid),
  public.battle_scores(uuid), public.battle_active(uuid), public.live_battle_access(uuid, uuid) from public, anon;
grant execute on function public.battle_invite(uuid, uuid, int), public.battle_respond(uuid, boolean), public.battle_cancel(uuid), public.battle_finish(uuid),
  public.battle_scores(uuid), public.battle_active(uuid), public.live_battle_access(uuid, uuid) to authenticated;

select cron.schedule('battle-sweep', '10 seconds', 'select public.battle_sweep()');
