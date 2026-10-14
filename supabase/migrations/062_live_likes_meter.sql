-- 062: likes on lives, and the Vibe Meter.
-- Anyone watching a live can tap the heart to like it (taps build up, like TikTok). Each person's taps are capped per live.
-- Every live has a Vibe Meter that fills from three things: how many people watch, how many likes, and how much in vibes (gifts) arrives.
-- The meter only reaches 100% when all three have hit their target, and it can fill once per live. When it fills, the creator gets bonus
-- Vibez that count towards the weekly AND monthly leaderboards, if they accepted the meter terms and have not used up the weekly limit.
-- Everyone in the live sees that the meter is full. Only the creator sees their bonus (or why there was none).
-- Settings (app_settings, all optional, defaults in brackets):
--   lm_viewers_target (50)        people who have watched for at least lm_min_watch_secs (30) seconds
--   lm_likes_target (500)         likes, where each person's first lm_like_meter_cap (25) taps count
--   lm_gift_target_cents (2500)   vibes sent into the live, in pence
--   lm_w_viewers / lm_w_likes / lm_w_gifts (40 / 30 / 30)   how much of the bar each part is worth (should add up to 100)
--   lm_like_cap (100)             most taps one person can leave on one live
--   lm_bonus_vibez (5000)         bonus when the meter fills
--   lm_weekly_max (3)             most meter bonuses one creator can earn in 7 days

create table if not exists public.live_viewers (
  stream_id uuid not null references public.live_streams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (stream_id, user_id)
);
alter table public.live_viewers enable row level security;

create table if not exists public.live_likes (
  stream_id uuid not null references public.live_streams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  taps int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (stream_id, user_id)
);
alter table public.live_likes enable row level security;

create table if not exists public.live_meters (
  stream_id uuid primary key references public.live_streams(id) on delete cascade,
  creator_id uuid not null references public.profiles(id) on delete cascade,
  filled_at timestamptz not null default now(),
  bonus_vibez bigint,
  note text
);
alter table public.live_meters enable row level security;

create table if not exists public.live_meter_terms (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  accepted_at timestamptz not null default now(),
  version int not null default 1
);
alter table public.live_meter_terms enable row level security;
revoke all on public.live_viewers, public.live_likes, public.live_meters, public.live_meter_terms from anon, authenticated;

-- new kinds: the meter bonus on the leaderboard ledger, and "meter full" as a live event everyone in the room sees
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.lb_ledger'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%weekly_bonus%' loop
    execute 'alter table public.lb_ledger dro' || 'p constraint ' || quote_ident(c);
  end loop;
  alter table public.lb_ledger add constraint lb_ledger_kind_check check (kind in ('vibe','tip','weekly_bonus','tournament_bonus','live_meter_bonus'));
  for c in select conname from pg_constraint where conrelid = 'public.live_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%owner_joined%' loop
    execute 'alter table public.live_events dro' || 'p constraint ' || quote_ident(c);
  end loop;
  alter table public.live_events add constraint live_events_kind_check check (kind in ('owner_joined','owner_left','bonus','meter_full'));
end $$;

-- the numbers behind the meter
create or replace function public._lm_stats(p_stream uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s live_streams%rowtype; v_view int; v_likes bigint; v_eff bigint; v_gift bigint; pv numeric; pl numeric; pg numeric; v_pct int;
        tv int := greatest(_ref_int('lm_viewers_target', 50), 1); tl int := greatest(_ref_int('lm_likes_target', 500), 1); tg int := greatest(_ref_int('lm_gift_target_cents', 2500), 1);
        wv int := _ref_int('lm_w_viewers', 40); wl int := _ref_int('lm_w_likes', 30); wg int := _ref_int('lm_w_gifts', 30);
begin
  select * into s from live_streams where id = p_stream;
  if not found then return null; end if;
  select count(*) into v_view from live_viewers v join profiles p on p.id = v.user_id and p.staff_role is null and not p.is_banned
   where v.stream_id = p_stream and v.user_id <> s.creator_id and v.last_seen_at - v.first_seen_at >= make_interval(secs => _ref_int('lm_min_watch_secs', 30));
  select coalesce(sum(taps), 0), coalesce(sum(least(taps, _ref_int('lm_like_meter_cap', 25))), 0) into v_likes, v_eff from live_likes where stream_id = p_stream;
  select coalesce(sum(cents), 0) into v_gift from live_vibes where stream_id = p_stream and sender_id <> s.creator_id;
  pv := least(v_view::numeric / tv, 1); pl := least(v_eff::numeric / tl, 1); pg := least(v_gift::numeric / tg, 1);
  v_pct := floor(wv * pv + wl * pl + wg * pg)::int;
  if pv >= 1 and pl >= 1 and pg >= 1 then v_pct := 100; elsif v_pct >= 100 then v_pct := 99; end if;
  return jsonb_build_object('viewers', v_view, 'likes', v_likes, 'likes_counted', v_eff, 'gift_cents', v_gift, 'pct', v_pct,
    'parts', jsonb_build_object('viewers', round(pv * 100), 'likes', round(pl * 100), 'gifts', round(pg * 100)),
    'targets', jsonb_build_object('viewers', tv, 'likes', tl, 'gift_cents', tg), 'weights', jsonb_build_object('viewers', wv, 'likes', wl, 'gifts', wg));
end $$;

-- If the meter is full, fill it (once per live), pay the bonus if the creator is eligible and tell the room.
create or replace function public._lm_check(p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype; st jsonb; n int; v_amt bigint; v_note text; v_lim int := _ref_int('lm_weekly_max', 3);
begin
  select * into s from live_streams where id = p_stream and status = 'live';
  if not found then return; end if;
  if exists (select 1 from live_meters where stream_id = p_stream) then return; end if;
  st := _lm_stats(p_stream);
  if coalesce((st->>'pct')::int, 0) < 100 then return; end if;
  insert into live_meters(stream_id, creator_id) values (p_stream, s.creator_id) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return; end if;
  v_amt := _ref_int('lm_bonus_vibez', 5000);
  if exists (select 1 from profiles where id = s.creator_id and is_banned) then v_amt := 0; v_note := 'Account restricted';
  elsif not exists (select 1 from live_meter_terms where user_id = s.creator_id) then v_amt := 0; v_note := 'You have not agreed to the Vibe Meter terms yet, so there was no bonus this time';
  elsif (select count(*) from lb_ledger where creator_id = s.creator_id and kind = 'live_meter_bonus' and created_at > now() - interval '7 days') >= v_lim then
    v_amt := 0; v_note := 'You have already earned ' || v_lim || ' meter bonuses in the last 7 days';
  end if;
  if v_amt > 0 then
    insert into lb_ledger(creator_id, kind, vibez, stream_id, month_key, week_start, note)
      values (s.creator_id, 'live_meter_bonus', v_amt, p_stream, _lb_month(now()), _lb_week_start(now()), 'Vibe Meter full');
    perform _log('live_meter_bonus', s.creator_id, jsonb_build_object('stream', p_stream, 'vibez', v_amt, 'stats', st));
  end if;
  update live_meters set bonus_vibez = v_amt, note = v_note where stream_id = p_stream;
  perform _notify(s.creator_id, null, 'live_meter_full', p_stream, jsonb_build_object('vibez', v_amt, 'note', v_note, 'title', left(s.title, 60)));
  insert into live_events(stream_id, kind, actor_id) values (p_stream, 'meter_full', s.creator_id);
end $$;

-- Everyone in a live asks this every few seconds. It also records that the caller is watching (that is how viewers are counted).
create or replace function public.live_meter(p_stream uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype; st jsonb; m live_meters%rowtype; v_creator boolean; v_mine int; v_out jsonb;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into s from live_streams where id = p_stream;
  if not found or not live_can_watch(p_stream) then raise exception 'This stream is not available'; end if;
  v_creator := (s.creator_id = auth.uid());
  if not v_creator and s.status = 'live' and not is_blocked_between(auth.uid(), s.creator_id) then
    insert into live_viewers(stream_id, user_id) values (p_stream, auth.uid())
      on conflict (stream_id, user_id) do update set last_seen_at = now();
  end if;
  perform _lm_check(p_stream);
  st := _lm_stats(p_stream);
  select * into m from live_meters where stream_id = p_stream;
  select coalesce(taps, 0) into v_mine from live_likes where stream_id = p_stream and user_id = auth.uid();
  v_out := jsonb_build_object('pct', case when m.stream_id is not null then 100 else (st->>'pct')::int end, 'filled', m.stream_id is not null, 'likes', (st->>'likes')::bigint,
            'parts', st->'parts', 'my_taps', coalesce(v_mine, 0), 'like_cap', _ref_int('lm_like_cap', 100), 'creator', v_creator, 'status', s.status);
  if v_creator then
    v_out := v_out || jsonb_build_object('viewers', st->'viewers', 'gift_cents', st->'gift_cents', 'likes_counted', st->'likes_counted', 'targets', st->'targets',
              'terms_ok', exists (select 1 from live_meter_terms where user_id = auth.uid()),
              'bonus', case when m.stream_id is not null then jsonb_build_object('vibez', coalesce(m.bonus_vibez, 0), 'note', m.note) end);
  end if;
  return v_out;
end $$;

-- Tap the heart. Taps are capped per person per live.
create or replace function public.live_like(p_stream uuid, p_taps int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype; v_cap int := _ref_int('lm_like_cap', 100); v_new int; v_total bigint;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  perform _require_adult();
  if not not_banned() then raise exception 'Your account is restricted'; end if;
  select * into s from live_streams where id = p_stream and status = 'live';
  if not found then raise exception 'This stream is not live'; end if;
  if s.creator_id = auth.uid() then raise exception 'You cannot like your own live'; end if;
  if not live_can_watch(p_stream) or is_blocked_between(auth.uid(), s.creator_id) then raise exception 'You cannot like this live'; end if;
  p_taps := least(greatest(coalesce(p_taps, 1), 1), 10);
  insert into live_likes(stream_id, user_id, taps) values (p_stream, auth.uid(), least(p_taps, v_cap))
    on conflict (stream_id, user_id) do update set taps = least(v_cap, live_likes.taps + p_taps), updated_at = now() returning taps into v_new;
  select coalesce(sum(taps), 0) into v_total from live_likes where stream_id = p_stream;
  return jsonb_build_object('my_taps', v_new, 'likes', v_total);
end $$;

-- Creator terms. The creator agrees once; without it a full meter pays nothing.
create or replace function public.live_meter_terms_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  return jsonb_build_object('accepted', exists (select 1 from live_meter_terms where user_id = auth.uid()),
    'cfg', jsonb_build_object('viewers', _ref_int('lm_viewers_target', 50), 'watch_secs', _ref_int('lm_min_watch_secs', 30), 'likes', _ref_int('lm_likes_target', 500),
      'like_cap', _ref_int('lm_like_meter_cap', 25), 'gift_cents', _ref_int('lm_gift_target_cents', 2500), 'bonus', _ref_int('lm_bonus_vibez', 5000), 'weekly_max', _ref_int('lm_weekly_max', 3)));
end $$;

create or replace function public.live_meter_terms_accept() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and account_type = 'creator') then raise exception 'Creators only'; end if;
  insert into live_meter_terms(user_id) values (auth.uid()) on conflict (user_id) do nothing;
end $$;

-- The creator's heartbeat also checks the meter, so it fills even if nobody is polling at that moment.
create or replace function public.live_heartbeat(p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update live_streams set last_seen_at = now() where id = p_stream and creator_id = auth.uid() and status = 'live';
  if not found then raise exception 'This stream has ended'; end if;
  perform _lm_check(p_stream);
end $$;

-- Meter bonuses count on BOTH the weekly and the monthly board. (Weekly top 3 and tournament bonuses stay monthly, as before.)
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
  b as (select l.creator_id, sum(l.vibez)::bigint as bv from lb_ledger l join profiles p on p.id = l.creator_id and not p.is_banned
         where (p_week is null and l.kind in ('weekly_bonus', 'tournament_bonus', 'live_meter_bonus') and l.month_key = p_month)
            or (p_week is not null and l.kind = 'live_meter_bonus' and l.week_start = p_week)
         group by l.creator_id)
  select coalesce(c.creator_id, b.creator_id), (coalesce(c.v, 0) + coalesce(b.bv, 0))::bigint, coalesce(c.raw, 0)::bigint, coalesce(b.bv, 0)::bigint, c.last_at
    from c full join b on b.creator_id = c.creator_id
$$;

-- the admin prize card counts the meter bonus in "bonus Vibez" too
create or replace function public._lb_prize_stats(p_month text, p_creator uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_month_end timestamptz := ((to_date(p_month || '-01', 'YYYY-MM-DD') + interval '1 month')::date)::timestamp at time zone 'Europe/London'; v_stats jsonb;
begin
  select jsonb_build_object(
    'supporters', count(distinct l.sender_id),
    'payments', count(*) filter (where l.kind in ('vibe', 'tip')),
    'bonus_vibez', coalesce(sum(l.vibez) filter (where l.kind in ('weekly_bonus', 'tournament_bonus', 'live_meter_bonus')), 0),
    'new_accounts', count(distinct l.sender_id) filter (where exists (select 1 from profiles s where s.id = l.sender_id and s.created_at > v_month_end - interval '14 days')),
    'only_this_creator', count(distinct l.sender_id) filter (where not exists (select 1 from lb_ledger o where o.month_key = p_month and o.sender_id = l.sender_id and o.creator_id <> p_creator)),
    'top_supporters', (select coalesce(jsonb_agg(jsonb_build_object('username', sp.username, 'vibez', q.v) order by q.v desc), '[]'::jsonb)
                         from (select sender_id, sum(vibez) v from lb_ledger where month_key = p_month and creator_id = p_creator and sender_id is not null group by sender_id order by sum(vibez) desc limit 5) q
                         join profiles sp on sp.id = q.sender_id))
    into v_stats from lb_ledger l where l.month_key = p_month and l.creator_id = p_creator and l.kind in ('vibe', 'tip', 'weekly_bonus', 'tournament_bonus', 'live_meter_bonus');
  return coalesce(v_stats, '{}'::jsonb);
end $$;

create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed','leaderboard_prize','leaderboard_prize_held') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured','weekly_summary','download_request','download_ok','download_no','leaderboard_bonus') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result','battle_invite','tournament_invite','tournament_won','live_meter_full') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help','age_nudge','held','held_ok','scan_held','urgent_report','referral_reward','leaderboard_prize_review') then 'account'
    else null end;
$$;

revoke execute on function public._lm_stats(uuid), public._lm_check(uuid), public._lb_scores(text, date), public._lb_prize_stats(text, uuid) from public, anon, authenticated;
revoke execute on function public.live_meter(uuid), public.live_like(uuid, int), public.live_meter_terms_status(), public.live_meter_terms_accept(), public.live_heartbeat(uuid) from public, anon;
grant execute on function public.live_meter(uuid), public.live_like(uuid, int), public.live_meter_terms_status(), public.live_meter_terms_accept(), public.live_heartbeat(uuid) to authenticated;
