-- 063: the Vibe Meter is now a LIVE, moving meter, and harder to fill.
-- * Viewers only count while they are still in the live (seen in the last lm_presence_secs = 35 seconds). When people drop out the meter goes down.
-- * Likes only count from people who are still in the live. When someone leaves, all their likes go away with them, and if they come back
--   they start again from zero.
-- * The meter has to stay full for lm_hold_secs (30) seconds before it counts as filled (and it resets if it dips).
-- * Higher targets: 75 people watching (was 50), 750 likes (was 500), £50 in vibes (was £25).
-- * The creator terms changed, so creators agree to them again (version 2).
-- Settings: lm_presence_secs (35), lm_hold_secs (30), lm_viewers_target (75), lm_likes_target (750), lm_gift_target_cents (5000).

create table if not exists public.live_meter_hold (
  stream_id uuid primary key references public.live_streams(id) on delete cascade,
  full_since timestamptz not null default now()
);
alter table public.live_meter_hold enable row level security;
revoke all on public.live_meter_hold from anon, authenticated;

-- A new visit starts when the person was gone for longer than the presence window: their old likes are wiped and the watch clock restarts.
create or replace function public._lm_touch(p_stream uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_win int := _ref_int('lm_presence_secs', 35);
begin
  update live_likes l set taps = 0, updated_at = now()
   where l.stream_id = p_stream and l.user_id = p_user and l.taps > 0
     and exists (select 1 from live_viewers v where v.stream_id = p_stream and v.user_id = p_user and v.last_seen_at < now() - make_interval(secs => v_win));
  insert into live_viewers(stream_id, user_id) values (p_stream, p_user)
    on conflict (stream_id, user_id) do update
      set first_seen_at = case when live_viewers.last_seen_at < now() - make_interval(secs => v_win) then now() else live_viewers.first_seen_at end,
          last_seen_at = now();
end $$;

create or replace function public._lm_stats(p_stream uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s live_streams%rowtype; v_view int; v_likes bigint; v_eff bigint; v_gift bigint; pv numeric; pl numeric; pg numeric; v_pct int;
        v_win int := _ref_int('lm_presence_secs', 35);
        tv int := greatest(_ref_int('lm_viewers_target', 75), 1); tl int := greatest(_ref_int('lm_likes_target', 750), 1); tg int := greatest(_ref_int('lm_gift_target_cents', 5000), 1);
        wv int := _ref_int('lm_w_viewers', 40); wl int := _ref_int('lm_w_likes', 30); wg int := _ref_int('lm_w_gifts', 30);
begin
  select * into s from live_streams where id = p_stream;
  if not found then return null; end if;
  -- people in the live right now (and who have been there long enough)
  select count(*) into v_view from live_viewers v join profiles p on p.id = v.user_id and p.staff_role is null and not p.is_banned
   where v.stream_id = p_stream and v.user_id <> s.creator_id and v.last_seen_at > now() - make_interval(secs => v_win)
     and v.last_seen_at - v.first_seen_at >= make_interval(secs => _ref_int('lm_min_watch_secs', 30));
  -- likes from people who are still here
  select coalesce(sum(l.taps), 0), coalesce(sum(least(l.taps, _ref_int('lm_like_meter_cap', 25))), 0) into v_likes, v_eff
    from live_likes l join live_viewers v on v.stream_id = l.stream_id and v.user_id = l.user_id
    join profiles p on p.id = l.user_id and p.staff_role is null and not p.is_banned
   where l.stream_id = p_stream and v.last_seen_at > now() - make_interval(secs => v_win);
  select coalesce(sum(cents), 0) into v_gift from live_vibes where stream_id = p_stream and sender_id <> s.creator_id;
  pv := least(v_view::numeric / tv, 1); pl := least(v_eff::numeric / tl, 1); pg := least(v_gift::numeric / tg, 1);
  v_pct := floor(wv * pv + wl * pl + wg * pg)::int;
  if pv >= 1 and pl >= 1 and pg >= 1 then v_pct := 100; elsif v_pct >= 100 then v_pct := 99; end if;
  return jsonb_build_object('viewers', v_view, 'likes', v_likes, 'likes_counted', v_eff, 'gift_cents', v_gift, 'pct', v_pct,
    'parts', jsonb_build_object('viewers', round(pv * 100), 'likes', round(pl * 100), 'gifts', round(pg * 100)),
    'targets', jsonb_build_object('viewers', tv, 'likes', tl, 'gift_cents', tg), 'weights', jsonb_build_object('viewers', wv, 'likes', wl, 'gifts', wg));
end $$;

-- Fill it only once it has stayed full for lm_hold_secs. If it dips, the clock resets.
create or replace function public._lm_check(p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype; st jsonb; n int; v_amt bigint; v_note text; v_lim int := _ref_int('lm_weekly_max', 3); v_since timestamptz;
begin
  select * into s from live_streams where id = p_stream and status = 'live';
  if not found then return; end if;
  if exists (select 1 from live_meters where stream_id = p_stream) then return; end if;
  st := _lm_stats(p_stream);
  if coalesce((st->>'pct')::int, 0) < 100 then
    execute 'dele' || 'te from public.live_meter_hold where stream_id = $1' using p_stream;
    return;
  end if;
  insert into live_meter_hold(stream_id) values (p_stream) on conflict do nothing;
  select full_since into v_since from live_meter_hold where stream_id = p_stream;
  if clock_timestamp() - v_since < make_interval(secs => _ref_int('lm_hold_secs', 30)) then return; end if;
  insert into live_meters(stream_id, creator_id) values (p_stream, s.creator_id) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return; end if;
  v_amt := _ref_int('lm_bonus_vibez', 5000);
  if exists (select 1 from profiles where id = s.creator_id and is_banned) then v_amt := 0; v_note := 'Account restricted';
  elsif not exists (select 1 from live_meter_terms where user_id = s.creator_id and version >= 2) then v_amt := 0; v_note := 'You have not agreed to the current Vibe Meter terms yet, so there was no bonus this time';
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

create or replace function public.live_meter(p_stream uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype; st jsonb; m live_meters%rowtype; v_creator boolean; v_mine int; v_out jsonb; v_since timestamptz; v_hold int := _ref_int('lm_hold_secs', 30);
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into s from live_streams where id = p_stream;
  if not found or not live_can_watch(p_stream) then raise exception 'This stream is not available'; end if;
  v_creator := (s.creator_id = auth.uid());
  if not v_creator and s.status = 'live' and not is_blocked_between(auth.uid(), s.creator_id) then perform _lm_touch(p_stream, auth.uid()); end if;
  perform _lm_check(p_stream);
  st := _lm_stats(p_stream);
  select * into m from live_meters where stream_id = p_stream;
  select full_since into v_since from live_meter_hold where stream_id = p_stream;
  select coalesce(taps, 0) into v_mine from live_likes where stream_id = p_stream and user_id = auth.uid();
  v_out := jsonb_build_object('pct', case when m.stream_id is not null then 100 else (st->>'pct')::int end, 'filled', m.stream_id is not null, 'likes', (st->>'likes')::bigint,
            'parts', st->'parts', 'my_taps', coalesce(v_mine, 0), 'like_cap', _ref_int('lm_like_cap', 100), 'creator', v_creator, 'status', s.status,
            'holding', (m.stream_id is null and v_since is not null and (st->>'pct')::int >= 100),
            'hold_left', case when m.stream_id is null and v_since is not null then greatest(0, ceil(v_hold - extract(epoch from (clock_timestamp() - v_since))))::int end);
  if v_creator then
    v_out := v_out || jsonb_build_object('viewers', st->'viewers', 'gift_cents', st->'gift_cents', 'likes_counted', st->'likes_counted', 'targets', st->'targets',
              'terms_ok', exists (select 1 from live_meter_terms where user_id = auth.uid() and version >= 2),
              'bonus', case when m.stream_id is not null then jsonb_build_object('vibez', coalesce(m.bonus_vibez, 0), 'note', m.note) end);
  end if;
  return v_out;
end $$;

-- Tapping the heart also counts as being in the live.
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
  perform _lm_touch(p_stream, auth.uid());
  p_taps := least(greatest(coalesce(p_taps, 1), 1), 10);
  insert into live_likes(stream_id, user_id, taps) values (p_stream, auth.uid(), least(p_taps, v_cap))
    on conflict (stream_id, user_id) do update set taps = least(v_cap, live_likes.taps + p_taps), updated_at = now() returning taps into v_new;
  select coalesce(sum(l.taps), 0) into v_total from live_likes l join live_viewers v on v.stream_id = l.stream_id and v.user_id = l.user_id
   where l.stream_id = p_stream and v.last_seen_at > now() - make_interval(secs => _ref_int('lm_presence_secs', 35));
  return jsonb_build_object('my_taps', v_new, 'likes', v_total);
end $$;

-- Leaving a live: the person stops counting straight away and their likes go with them.
create or replace function public.live_meter_leave(p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  update live_viewers set last_seen_at = now() - interval '1 day' where stream_id = p_stream and user_id = auth.uid();
  update live_likes set taps = 0, updated_at = now() where stream_id = p_stream and user_id = auth.uid();
end $$;

create or replace function public.live_meter_terms_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  return jsonb_build_object('accepted', exists (select 1 from live_meter_terms where user_id = auth.uid() and version >= 2),
    'cfg', jsonb_build_object('viewers', _ref_int('lm_viewers_target', 75), 'watch_secs', _ref_int('lm_min_watch_secs', 30), 'likes', _ref_int('lm_likes_target', 750),
      'like_cap', _ref_int('lm_like_meter_cap', 25), 'gift_cents', _ref_int('lm_gift_target_cents', 5000), 'bonus', _ref_int('lm_bonus_vibez', 5000),
      'weekly_max', _ref_int('lm_weekly_max', 3), 'hold_secs', _ref_int('lm_hold_secs', 30)));
end $$;

create or replace function public.live_meter_terms_accept() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and account_type = 'creator') then raise exception 'Creators only'; end if;
  insert into live_meter_terms(user_id, version) values (auth.uid(), 2)
    on conflict (user_id) do update set version = 2, accepted_at = now();
end $$;

revoke execute on function public._lm_touch(uuid, uuid), public._lm_stats(uuid), public._lm_check(uuid) from public, anon, authenticated;
revoke execute on function public.live_meter(uuid), public.live_like(uuid, int), public.live_meter_leave(uuid), public.live_meter_terms_status(), public.live_meter_terms_accept() from public, anon;
grant execute on function public.live_meter(uuid), public.live_like(uuid, int), public.live_meter_leave(uuid), public.live_meter_terms_status(), public.live_meter_terms_accept() to authenticated;
