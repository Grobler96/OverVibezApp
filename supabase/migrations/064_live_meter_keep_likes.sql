-- 064: when a viewer leaves, their likes stop counting towards the METER, but the live keeps its like total.
-- (063 wiped a leaver's likes completely. Now the taps stay on the live, and the meter only counts taps from people who are in the live right now.
--  Someone who leaves and comes back counts again, because they are back in the live; their taps are still limited to lm_like_cap per live.)

create or replace function public._lm_touch(p_stream uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_win int := _ref_int('lm_presence_secs', 35);
begin
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
  select count(*) into v_view from live_viewers v join profiles p on p.id = v.user_id and p.staff_role is null and not p.is_banned
   where v.stream_id = p_stream and v.user_id <> s.creator_id and v.last_seen_at > now() - make_interval(secs => v_win)
     and v.last_seen_at - v.first_seen_at >= make_interval(secs => _ref_int('lm_min_watch_secs', 30));
  -- the live's total likes: everyone who ever liked it, whether they are still here or not
  select coalesce(sum(taps), 0) into v_likes from live_likes where stream_id = p_stream;
  -- likes that count towards the METER: only from people who are in the live right now
  select coalesce(sum(least(l.taps, _ref_int('lm_like_meter_cap', 25))), 0) into v_eff
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
  select coalesce(sum(taps), 0) into v_total from live_likes where stream_id = p_stream;
  return jsonb_build_object('my_taps', v_new, 'likes', v_total);
end $$;

-- Leaving a live: the person stops counting towards the meter straight away. Their likes stay on the live's total.
create or replace function public.live_meter_leave(p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  update live_viewers set last_seen_at = now() - interval '1 day' where stream_id = p_stream and user_id = auth.uid();
end $$;

revoke execute on function public._lm_touch(uuid, uuid), public._lm_stats(uuid) from public, anon, authenticated;
revoke execute on function public.live_like(uuid, int), public.live_meter_leave(uuid) from public, anon;
grant execute on function public.live_like(uuid, int), public.live_meter_leave(uuid) to authenticated;
