-- 059: knockout tournaments for live creators (4 or 8 creators).
-- A creator who is live opens a lobby and invites other live creators. When it is full the host starts it.
-- Round 1 pairs everyone up at random and every pair has a normal battle at the same time (same rules as a 1v1 battle:
-- whose audience sends the most vibes wins). Winners go through, the rest are knocked out (their live carries on as normal).
-- After a short break the winners are paired again, until one creator is left. The champion gets bonus Vibez on their meter.
-- To stop friends farming the bonus, it is only paid if the battles raised enough in gifts and a creator can win it only a couple of times a week.
-- Settings (app_settings): tourney_bonus_8 (20000), tourney_bonus_4 (10000), tourney_min_cents (10000 from 060), tourney_weekly_max (2).

alter table public.live_battles add column if not exists tournament_id uuid;
alter table public.live_battles add column if not exists round int;
alter table public.live_battles add column if not exists slot int;
alter table public.live_battles add column if not exists settled boolean not null default false;
create index if not exists live_battles_tournament_idx on public.live_battles (tournament_id, round);

create table if not exists public.live_tournaments (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles(id) on delete cascade,
  host_stream uuid not null references public.live_streams(id) on delete cascade,
  size int not null check (size in (4, 8)),
  minutes int not null check (minutes in (3, 5)),
  rounds int not null,
  status text not null default 'lobby' check (status in ('lobby','running','between','finished','cancelled')),
  round int not null default 0,
  next_at timestamptz,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  ended_at timestamptz,
  champion uuid references public.profiles(id) on delete set null,
  bonus_vibez bigint,
  bonus_note text
);
alter table public.live_tournaments enable row level security;

create table if not exists public.live_tournament_players (
  tournament_id uuid not null references public.live_tournaments(id) on delete cascade,
  creator_id uuid not null references public.profiles(id) on delete cascade,
  stream_id uuid not null references public.live_streams(id) on delete cascade,
  status text not null default 'invited' check (status in ('invited','in','declined','out','champion','left')),
  seed int,
  pos int,
  out_round int,
  invited_at timestamptz not null default now(),
  joined_at timestamptz,
  primary key (tournament_id, creator_id)
);
create index if not exists live_tournament_players_stream_idx on public.live_tournament_players (stream_id);
alter table public.live_tournament_players enable row level security;

-- the tournament bonus is a new kind of Vibez on the meter
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.lb_ledger'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%weekly_bonus%' loop
    execute 'alter table public.lb_ledger dro' || 'p constraint ' || quote_ident(c);
  end loop;
  alter table public.lb_ledger add constraint lb_ledger_kind_check check (kind in ('vibe','tip','weekly_bonus','tournament_bonus'));
end $$;

-- is this creator's live tied up in a tournament right now?
create or replace function public._tourney_busy(p_stream uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from live_tournament_players p join live_tournaments t on t.id = p.tournament_id
                  where p.stream_id = p_stream and p.status = 'in' and t.status in ('lobby','running','between'));
$$;

create or replace function public._tourney_can_see(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (public.is_admin() or exists (
    select 1 from live_tournament_players p where p.tournament_id = p_id
       and (p.creator_id = auth.uid() or (p.status in ('in','out','champion') and public.live_can_watch(p.stream_id)))));
$$;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'live_tournaments' and policyname = 'live_tournaments_read') then
    create policy live_tournaments_read on public.live_tournaments for select using (public._tourney_can_see(id));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'live_tournament_players' and policyname = 'live_tournament_players_read') then
    create policy live_tournament_players_read on public.live_tournament_players for select using (public._tourney_can_see(tournament_id));
  end if;
end $$;
revoke all on public.live_tournaments, public.live_tournament_players from anon, authenticated;
grant select on public.live_tournaments, public.live_tournament_players to authenticated;
alter publication supabase_realtime add table public.live_tournament_players;

-- a battle now also says which tournament and round it belongs to
create or replace function public._battle_json(b live_battles) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a int; c int; v_rounds int;
begin
  if b.status = 'ended' then a := coalesce(b.score_a, 0); c := coalesce(b.score_b, 0);
  else a := _battle_side(b.stream_a, b.started_at, b.ends_at); c := _battle_side(b.stream_b, b.started_at, b.ends_at); end if;
  if b.tournament_id is not null then select rounds into v_rounds from live_tournaments where id = b.tournament_id; end if;
  return jsonb_build_object('id', b.id, 'status', b.status, 'minutes', b.minutes, 'stream_a', b.stream_a, 'stream_b', b.stream_b,
    'creator_a', b.creator_a, 'creator_b', b.creator_b, 'started_at', b.started_at, 'ends_at', b.ends_at, 'score_a', a, 'score_b', c,
    'winner', b.winner, 'tournament', b.tournament_id, 'round', b.round, 'rounds', v_rounds, 'now', clock_timestamp());
end $$;

-- 1v1 challenges are not allowed while a creator is in a tournament
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
  if _tourney_busy(p_stream) or _tourney_busy(p_target) then raise exception 'One of you is in a tournament'; end if;
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

-- ===== the tournament =====
create or replace function public._tourney_json(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t live_tournaments%rowtype;
begin
  select * into t from live_tournaments where id = p_id;
  if not found then return null; end if;
  return jsonb_build_object('id', t.id, 'host', t.host_id, 'host_stream', t.host_stream, 'size', t.size, 'minutes', t.minutes, 'status', t.status,
    'round', t.round, 'rounds', t.rounds, 'next_at', t.next_at, 'champion', t.champion, 'bonus_vibez', t.bonus_vibez, 'bonus_note', t.bonus_note,
    'players', coalesce((select jsonb_agg(jsonb_build_object('creator_id', p.creator_id, 'username', pr.username, 'display_name', pr.display_name,
                'avatar_url', pr.avatar_url, 'stream_id', p.stream_id, 'status', p.status, 'pos', p.pos, 'seed', p.seed, 'out_round', p.out_round)
                order by coalesce(p.seed, 99), p.joined_at nulls last, p.invited_at)
              from live_tournament_players p join profiles pr on pr.id = p.creator_id where p.tournament_id = t.id), '[]'::jsonb),
    'battles', coalesce((select jsonb_agg(_battle_json(b) || jsonb_build_object('slot', b.slot) order by b.round, b.slot)
              from live_battles b where b.tournament_id = t.id), '[]'::jsonb),
    'now', clock_timestamp());
end $$;

create or replace function public.tournament_state(p_tournament uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not _tourney_can_see(p_tournament) then raise exception 'Tournament not found'; end if;
  return _tourney_json(p_tournament);
end $$;

-- The tournament this live is part of (for people who join halfway, and for the creators themselves).
create or replace function public.tournament_active(p_stream uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select t.id into v from live_tournaments t join live_tournament_players p on p.tournament_id = t.id and p.stream_id = p_stream
   where p.status in ('invited','in','out','champion')
     and (t.status in ('lobby','running','between') or (t.status = 'finished' and t.ended_at > now() - interval '90 seconds'))
     and (t.status <> 'lobby' or p.status in ('invited','in'))
   order by t.created_at desc limit 1;
  if v is null or not _tourney_can_see(v) then return null; end if;
  return _tourney_json(v);
end $$;

create or replace function public.tournament_create(p_stream uuid, p_size int, p_minutes int) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  perform _require_adult();
  if not not_banned() then raise exception 'Your account is restricted'; end if;
  if p_size not in (4, 8) then raise exception 'A tournament has 4 or 8 creators'; end if;
  if p_minutes not in (3, 5) then raise exception 'Pick 3 or 5 minutes a round'; end if;
  if not exists (select 1 from live_streams where id = p_stream and creator_id = auth.uid() and status = 'live') then raise exception 'You need to be live to start a tournament'; end if;
  if _tourney_busy(p_stream) then raise exception 'You are already in a tournament'; end if;
  if exists (select 1 from live_battles where status in ('invited','active') and (stream_a = p_stream or stream_b = p_stream)) then raise exception 'Finish your battle first'; end if;
  update live_tournaments set status = 'cancelled', ended_at = now() where host_id = auth.uid() and status = 'lobby';
  insert into live_tournaments(host_id, host_stream, size, minutes, rounds) values (auth.uid(), p_stream, p_size, p_minutes, case p_size when 8 then 3 else 2 end) returning id into v_id;
  insert into live_tournament_players(tournament_id, creator_id, stream_id, status, joined_at) values (v_id, auth.uid(), p_stream, 'in', now());
  return v_id;
end $$;

create or replace function public.tournament_invite(p_tournament uuid, p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t live_tournaments%rowtype; tg live_streams%rowtype;
begin
  select * into t from live_tournaments where id = p_tournament and host_id = auth.uid() and status = 'lobby' for update;
  if not found then raise exception 'This tournament is not open'; end if;
  select * into tg from live_streams where id = p_stream and status = 'live' and last_seen_at > now() - interval '3 minutes';
  if not found then raise exception 'That creator is not live right now'; end if;
  if tg.creator_id = auth.uid() then raise exception 'You are already in'; end if;
  if is_blocked_between(auth.uid(), tg.creator_id) then raise exception 'You cannot invite this creator'; end if;
  if _tourney_busy(p_stream) then raise exception 'That creator is already in a tournament'; end if;
  if exists (select 1 from live_battles where status in ('invited','active') and (stream_a = p_stream or stream_b = p_stream)) then raise exception 'That creator is in a battle'; end if;
  if (select count(*) from live_tournament_players where tournament_id = p_tournament and status in ('invited','in')) >= t.size + 4 then raise exception 'Plenty of invites out already, wait for answers'; end if;
  insert into live_tournament_players(tournament_id, creator_id, stream_id, status) values (p_tournament, tg.creator_id, p_stream, 'invited')
    on conflict (tournament_id, creator_id) do update set status = 'invited', stream_id = excluded.stream_id, invited_at = now()
      where live_tournament_players.status in ('declined','left','invited');
  perform _notify(tg.creator_id, auth.uid(), 'tournament_invite', p_tournament, jsonb_build_object('size', t.size, 'minutes', t.minutes));
end $$;

create or replace function public.tournament_respond(p_tournament uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t live_tournaments%rowtype; p live_tournament_players%rowtype;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into t from live_tournaments where id = p_tournament and status = 'lobby' and created_at > now() - interval '10 minutes' for update;
  if not found then raise exception 'This tournament is no longer open'; end if;
  select * into p from live_tournament_players where tournament_id = p_tournament and creator_id = auth.uid() and status = 'invited' for update;
  if not found then raise exception 'You have not been invited'; end if;
  if not coalesce(p_accept, false) then
    update live_tournament_players set status = 'declined' where tournament_id = p_tournament and creator_id = auth.uid();
    return _tourney_json(p_tournament);
  end if;
  if (select count(*) from live_tournament_players where tournament_id = p_tournament and status = 'in') >= t.size then raise exception 'This tournament is already full'; end if;
  if not exists (select 1 from live_streams where id = p.stream_id and status = 'live') then raise exception 'You need to be live to join'; end if;
  if _tourney_busy(p.stream_id) then raise exception 'You are already in a tournament'; end if;
  if exists (select 1 from live_battles where status in ('invited','active') and (stream_a = p.stream_id or stream_b = p.stream_id)) then raise exception 'Finish your battle first'; end if;
  update live_tournament_players set status = 'in', joined_at = now() where tournament_id = p_tournament and creator_id = auth.uid();
  return _tourney_json(p_tournament);
end $$;

create or replace function public.tournament_leave(p_tournament uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from live_tournaments where id = p_tournament and host_id = auth.uid() and status = 'lobby') then
    update live_tournaments set status = 'cancelled', ended_at = now() where id = p_tournament;
  else
    update live_tournament_players set status = 'left' where tournament_id = p_tournament and creator_id = auth.uid() and status in ('invited','in')
       and exists (select 1 from live_tournaments where id = p_tournament and status = 'lobby');
  end if;
end $$;

-- Build the battles for the current round. Pairs are neighbours in the bracket (1 v 2, 3 v 4 ...).
-- A creator whose live has ended before the round starts loses without a fight.
create or replace function public._tourney_make_round(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t live_tournaments%rowtype; k int; pa live_tournament_players%rowtype; pb live_tournament_players%rowtype; la boolean; lb boolean; v_start timestamptz; v_w uuid;
begin
  select * into t from live_tournaments where id = p_id for update;
  v_start := clock_timestamp() + case when t.round = 1 then interval '10 seconds' else interval '12 seconds' end;
  for k in 1..(t.size >> t.round) loop
    select * into pa from live_tournament_players where tournament_id = p_id and status = 'in' and pos = 2 * k - 1;
    select * into pb from live_tournament_players where tournament_id = p_id and status = 'in' and pos = 2 * k;
    continue when pa.creator_id is null or pb.creator_id is null;
    select exists (select 1 from live_streams where id = pa.stream_id and status = 'live') into la;
    select exists (select 1 from live_streams where id = pb.stream_id and status = 'live') into lb;
    if la and lb then
      insert into live_battles(stream_a, stream_b, creator_a, creator_b, status, minutes, started_at, ends_at, tournament_id, round, slot)
        values (pa.stream_id, pb.stream_id, pa.creator_id, pb.creator_id, 'active', t.minutes, v_start, v_start + make_interval(mins => t.minutes), p_id, t.round, k);
    else
      v_w := case when la then pa.creator_id when lb then pb.creator_id else pa.creator_id end;
      insert into live_battles(stream_a, stream_b, creator_a, creator_b, status, minutes, started_at, ends_at, ended_at, score_a, score_b, winner, tournament_id, round, slot)
        values (pa.stream_id, pb.stream_id, pa.creator_id, pb.creator_id, 'ended', t.minutes, now(), now(), now(), 0, 0, v_w, p_id, t.round, k);
    end if;
  end loop;
end $$;

create or replace function public.tournament_start(p_tournament uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t live_tournaments%rowtype; p record;
begin
  select * into t from live_tournaments where id = p_tournament and host_id = auth.uid() and status = 'lobby' for update;
  if not found then raise exception 'This tournament is not open'; end if;
  if (select count(*) from live_tournament_players where tournament_id = p_tournament and status = 'in') <> t.size then
    raise exception 'You need % creators to start', t.size;
  end if;
  for p in select lp.creator_id, lp.stream_id from live_tournament_players lp where lp.tournament_id = p_tournament and lp.status = 'in' loop
    if not exists (select 1 from live_streams where id = p.stream_id and status = 'live') then raise exception 'One of the creators is no longer live. Remove them and invite someone else'; end if;
    if exists (select 1 from live_battles where status in ('invited','active') and (stream_a = p.stream_id or stream_b = p.stream_id)) then raise exception 'One of the creators is in a battle'; end if;
  end loop;
  update live_tournament_players set status = 'declined' where tournament_id = p_tournament and status = 'invited';
  with o as (select creator_id, row_number() over (order by random()) as rn from live_tournament_players where tournament_id = p_tournament and status = 'in')
    update live_tournament_players lp set seed = o.rn, pos = o.rn from o where lp.tournament_id = p_tournament and lp.creator_id = o.creator_id;
  update live_tournaments set status = 'running', round = 1, started_at = now() where id = p_tournament;
  perform _tourney_make_round(p_tournament);
  return _tourney_json(p_tournament);
end $$;

-- The champion's bonus Vibez, if the tournament earned it.
create or replace function public._tourney_award(p_id uuid, p_champ uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t live_tournaments%rowtype; v_amt bigint; v_note text; v_cents bigint;
begin
  select * into t from live_tournaments where id = p_id;
  v_amt := _ref_int('tourney_bonus_' || t.size, case t.size when 8 then 20000 else 10000 end);
  select coalesce(sum(coalesce(score_a, 0) + coalesce(score_b, 0)), 0) into v_cents from live_battles where tournament_id = p_id and status = 'ended';
  if exists (select 1 from profiles where id = p_champ and is_banned) then v_amt := 0; v_note := 'Account restricted';
  elsif v_cents < _ref_int('tourney_min_cents', 1000) then v_amt := 0; v_note := 'The battles did not raise enough in gifts for a bonus';
  elsif (select count(*) from lb_ledger where creator_id = p_champ and kind = 'tournament_bonus' and created_at > now() - interval '7 days') >= _ref_int('tourney_weekly_max', 2) then
    v_amt := 0; v_note := 'Weekly tournament bonus limit reached';
  end if;
  if v_amt > 0 then
    insert into lb_ledger(creator_id, kind, vibez, month_key, week_start, note) values (p_champ, 'tournament_bonus', v_amt, _lb_month(now()), _lb_week_start(now()), 'Tournament winner (' || t.size || ' creators)');
    perform _log('tournament_bonus', p_champ, jsonb_build_object('tournament', p_id, 'vibez', v_amt, 'gifts_cents', v_cents));
  end if;
  update live_tournaments set bonus_vibez = v_amt, bonus_note = v_note where id = p_id;
  perform _notify(p_champ, null, 'tournament_won', p_id, jsonb_build_object('vibez', v_amt, 'size', t.size));
end $$;

-- Work out who goes through from battles that have finished, and move the tournament on when the round is complete.
create or replace function public._tourney_settle(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t live_tournaments%rowtype; b record; pa live_tournament_players%rowtype; pb live_tournament_players%rowtype; w uuid; l uuid; v_champ uuid;
begin
  select * into t from live_tournaments where id = p_id for update;
  if not found or t.status <> 'running' then return; end if;
  for b in select * from live_battles where tournament_id = p_id and round = t.round and not settled and status = 'ended' order by slot loop
    select * into pa from live_tournament_players where tournament_id = p_id and creator_id = b.creator_a;
    select * into pb from live_tournament_players where tournament_id = p_id and creator_id = b.creator_b;
    -- a draw goes to whoever was higher in the bracket (lower number)
    w := coalesce(b.winner, case when pa.pos <= pb.pos then b.creator_a else b.creator_b end);
    l := case when w = b.creator_a then b.creator_b else b.creator_a end;
    update live_tournament_players set status = 'out', out_round = t.round where tournament_id = p_id and creator_id = l;
    update live_tournament_players set pos = (pos + 1) / 2 where tournament_id = p_id and creator_id = w;
    update live_battles set settled = true where id = b.id;
  end loop;
  if (select count(*) from live_battles where tournament_id = p_id and round = t.round and settled) < (t.size >> t.round) then return; end if;
  if t.round >= t.rounds then
    select creator_id into v_champ from live_tournament_players where tournament_id = p_id and status = 'in' limit 1;
    update live_tournament_players set status = 'champion' where tournament_id = p_id and creator_id = v_champ;
    update live_tournaments set status = 'finished', ended_at = now(), champion = v_champ where id = p_id;
    perform _tourney_award(p_id, v_champ);
  else
    update live_tournaments set status = 'between', next_at = now() + interval '15 seconds' where id = p_id;
  end if;
end $$;

create or replace function public._tourney_sweep() returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  update live_tournaments set status = 'cancelled', ended_at = now()
   where status = 'lobby' and (created_at < now() - interval '10 minutes' or not exists (select 1 from live_streams s where s.id = host_stream and s.status = 'live'));
  for r in select id, status, next_at from live_tournaments where status in ('running','between') loop
    if r.status = 'running' then perform _tourney_settle(r.id);
    elsif r.next_at <= now() then
      update live_tournaments set status = 'running', round = round + 1, next_at = null where id = r.id;
      perform _tourney_make_round(r.id);
    end if;
  end loop;
end $$;

create or replace function public.battle_sweep() returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  update live_battles set status = 'expired' where status = 'invited' and invited_at < now() - interval '90 seconds';
  for r in select id from live_battles where status = 'active' loop perform _battle_close(r.id); end loop;
  perform _tourney_sweep();
end $$;

-- Tournament Vibez count on the monthly meter like the weekly bonuses do.
create or replace function public._lb_scores(p_month text, p_week date)
returns table(creator_id uuid, v bigint, raw bigint, bonus bigint, last_at timestamptz)
language sql stable security definer set search_path = public as $$
  with s as (
    select l.creator_id, l.sender_id, sum(l.vibez)::bigint as sv, max(l.created_at) as la
      from lb_ledger l join profiles p on p.id = l.creator_id and not p.is_banned
     where l.kind in ('vibe', 'tip') and ((p_week is not null and l.week_start = p_week) or (p_week is null and l.month_key = p_month))
     group by l.creator_id, l.sender_id),
  t as (select s.creator_id, sum(s.sv)::bigint as tot from s group by s.creator_id),
  c as (select s.creator_id, sum(least(s.sv, greatest(t.tot * _ref_int('lb_supporter_cap_pct', 25) / 100, _ref_int('lb_supporter_floor_vibez', 10000))))::bigint as v,
               t.tot as raw, max(s.la) as last_at
          from s join t on t.creator_id = s.creator_id group by s.creator_id, t.tot),
  b as (select l.creator_id, sum(l.vibez)::bigint as bv from lb_ledger l
         where p_week is null and l.kind in ('weekly_bonus', 'tournament_bonus') and l.month_key = p_month group by l.creator_id)
  select c.creator_id, (c.v + coalesce(b.bv, 0))::bigint, c.raw, coalesce(b.bv, 0)::bigint, c.last_at
    from c left join b on b.creator_id = c.creator_id
$$;

create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed','leaderboard_prize','leaderboard_prize_held') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured','weekly_summary','download_request','download_ok','download_no','leaderboard_bonus') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result','battle_invite','tournament_invite','tournament_won') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help','age_nudge','held','held_ok','scan_held','urgent_report','referral_reward','leaderboard_prize_review') then 'account'
    else null end;
$$;

revoke execute on function public._tourney_busy(uuid), public._tourney_can_see(uuid), public._tourney_json(uuid), public._tourney_make_round(uuid), public._tourney_award(uuid, uuid),
  public._tourney_settle(uuid), public._tourney_sweep(), public._battle_json(live_battles), public.battle_sweep(), public._lb_scores(text, date) from public, anon, authenticated;
revoke execute on function public.tournament_state(uuid), public.tournament_active(uuid), public.tournament_create(uuid, int, int), public.tournament_invite(uuid, uuid),
  public.tournament_respond(uuid, boolean), public.tournament_leave(uuid), public.tournament_start(uuid), public.battle_invite(uuid, uuid, int) from public, anon;
grant execute on function public.tournament_state(uuid), public.tournament_active(uuid), public.tournament_create(uuid, int, int), public.tournament_invite(uuid, uuid),
  public.tournament_respond(uuid, boolean), public.tournament_leave(uuid), public.tournament_start(uuid), public.battle_invite(uuid, uuid, int) to authenticated;
