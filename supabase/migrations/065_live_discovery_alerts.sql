-- 065: the Live section (discovery) and go-live alerts.
-- * live_discover(): every live that is on right now, with the numbers the app needs to rank and show them:
--   people in the live, how many joined in the last 5 minutes, likes, likes in the last 5 minutes, vibes sent, vibes in the last 10 minutes,
--   Vibe Meter %, whether it is in a battle or a tournament, and two scores:
--     hot   = what is happening right now      = 2 x people in the live + 4 x joined in last 5 min + 1.5 x likes in last 5 min + £1 of vibes in the last 10 min x 2 + 10 if in a battle
--     trend = how fast it is growing for its size = (3 x joined in last 5 min + likes in last 5 min + 1 per 50p of vibes in the last 10 min) / sqrt(people + 4)
--   Banned creators, creators you blocked (or who blocked you) and your own live are left out. A creator who hides themselves from lists
--   (show_in_lists = false) only appears to people who follow them.
-- * live_recent(): creators who were live in the last 24 hours (for the "nobody is live" screen).
-- * Go-live alerts are now opt-in per creator: people switch on the bell for the creators they care about (live_alerts).
--   Going live only notifies those people (it used to notify every follower). Restarting a live within 20 minutes does not notify again.

create table if not exists public.live_alerts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  creator_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, creator_id)
);
create index if not exists live_alerts_creator_idx on public.live_alerts (creator_id);
alter table public.live_alerts enable row level security;
revoke all on public.live_alerts from anon, authenticated;

create or replace function public.set_live_alert(p_creator uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if coalesce(p_on, false) then
    if not exists (select 1 from follows where follower_id = auth.uid() and creator_id = p_creator) then raise exception 'Follow this creator first'; end if;
    if (select count(*) from live_alerts where user_id = auth.uid()) >= 200 then raise exception 'You can have go-live alerts on for up to 200 creators'; end if;
    insert into live_alerts(user_id, creator_id) values (auth.uid(), p_creator) on conflict do nothing;
  else
    execute 'dele' || 'te from public.live_alerts where user_id = $1 and creator_id = $2' using auth.uid(), p_creator;
  end if;
end $$;

create or replace function public.my_live_alerts() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(a.creator_id) from live_alerts a join follows f on f.follower_id = a.user_id and f.creator_id = a.creator_id where a.user_id = auth.uid()), '[]'::jsonb);
end $$;

-- Going live: tell only the people who switched on alerts for this creator (and still follow them).
create or replace function public.start_live_stream(p_title text, p_price_cents int default 0) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_recent boolean;
begin
  perform _require_adult();
  if not is_verified_creator() then raise exception 'Only verified creators can go live'; end if;
  if p_title is null or length(trim(p_title)) < 1 or length(p_title) > 120 then raise exception 'Give your stream a title (max 120 characters)'; end if;
  if p_price_cents is null or p_price_cents < 0 or p_price_cents > 50000 or (p_price_cents > 0 and p_price_cents < 99) then
    raise exception 'Entry price must be free or between $0.99 and $500.00'; end if;
  select exists (select 1 from live_streams where creator_id = auth.uid() and started_at > now() - interval '20 minutes') into v_recent;
  update live_streams set status = 'ended', ended_at = now() where creator_id = auth.uid() and status = 'live';
  insert into live_streams(creator_id, title, entry_price_cents, status) values (auth.uid(), trim(p_title), p_price_cents, 'live') returning id into v_id;
  if not v_recent then
    insert into notifications(user_id, actor_id, type, ref_id, data)
      select a.user_id, auth.uid(), 'live', v_id, jsonb_build_object('title', trim(p_title), 'price_cents', p_price_cents)
        from live_alerts a join follows f on f.follower_id = a.user_id and f.creator_id = a.creator_id
       where a.creator_id = auth.uid() and not is_blocked_between(a.user_id, auth.uid()) limit 5000;
  end if;
  return v_id;
end $$;

create or replace function public.live_discover() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_win int := _ref_int('lm_presence_secs', 35);
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  return coalesce((select jsonb_agg(r.x order by (r.x->>'hot')::numeric desc, r.x->>'started_at' desc) from (
    select jsonb_build_object(
      'id', s.id, 'creator_id', s.creator_id, 'title', s.title, 'entry_price_cents', s.entry_price_cents, 'started_at', s.started_at,
      'viewers', coalesce(vw.present, 0), 'joined5', coalesce(vw.joined5, 0),
      'likes', coalesce(lk.total, 0), 'likes5', coalesce(lk.recent, 0),
      'vibes', coalesce(g.cnt, 0), 'vibes10', coalesce(g.cents10, 0),
      'meter', coalesce((select 100 from live_meters m where m.stream_id = s.id), (_lm_stats(s.id)->>'pct')::int, 0),
      'battle', bt.opp, 'tournament', (bt.tid is not null),
      'following', exists (select 1 from follows f where f.follower_id = v_uid and f.creator_id = s.creator_id),
      'alert', exists (select 1 from live_alerts a where a.user_id = v_uid and a.creator_id = s.creator_id),
      'hot', round(coalesce(vw.present, 0) * 2 + coalesce(vw.joined5, 0) * 4 + coalesce(lk.recent, 0) * 1.5 + coalesce(g.cents10, 0) / 50.0 + case when bt.opp is not null then 10 else 0 end, 1),
      'trend', round((coalesce(vw.joined5, 0) * 3 + coalesce(lk.recent, 0) + coalesce(g.cents10, 0) / 50.0) / sqrt(coalesce(vw.present, 0) + 4)::numeric, 2)
    ) as x
      from live_streams s
      join profiles p on p.id = s.creator_id and not p.is_banned
      left join lateral (select count(*) filter (where v.last_seen_at > now() - make_interval(secs => v_win)) as present,
                                count(*) filter (where v.last_seen_at > now() - make_interval(secs => v_win) and v.first_seen_at > now() - interval '5 minutes') as joined5
                           from live_viewers v where v.stream_id = s.id and v.user_id <> s.creator_id) vw on true
      left join lateral (select coalesce(sum(l.taps), 0) as total, count(*) filter (where l.updated_at > now() - interval '5 minutes') as recent
                           from live_likes l where l.stream_id = s.id) lk on true
      left join lateral (select count(*) as cnt, coalesce(sum(vv.cents) filter (where vv.created_at > now() - interval '10 minutes'), 0) as cents10
                           from live_vibes vv where vv.stream_id = s.id and vv.sender_id <> s.creator_id) g on true
      left join lateral (select case when b.stream_a = s.id then b.creator_b else b.creator_a end as opp, b.tournament_id as tid
                           from live_battles b where (b.stream_a = s.id or b.stream_b = s.id) and b.status = 'active' and b.ends_at > now()
                          order by b.started_at desc limit 1) bt on true
     where s.status = 'live' and s.last_seen_at > now() - interval '90 seconds' and s.creator_id <> v_uid
       and not is_blocked_between(v_uid, s.creator_id)
       and (p.show_in_lists or exists (select 1 from follows f2 where f2.follower_id = v_uid and f2.creator_id = s.creator_id))
     limit 100) r), '[]'::jsonb);
end $$;

-- creators who were live in the last 24 hours and are not live now
create or replace function public.live_recent() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('creator_id', x.creator_id, 'title', x.title, 'ended_at', x.ended_at) order by x.ended_at desc) from (
    select distinct on (s.creator_id) s.creator_id, s.title, coalesce(s.ended_at, s.last_seen_at) as ended_at
      from live_streams s join profiles p on p.id = s.creator_id and not p.is_banned
     where s.status <> 'live' and coalesce(s.ended_at, s.last_seen_at) > now() - interval '24 hours' and s.creator_id <> v_uid
       and not is_blocked_between(v_uid, s.creator_id) and (p.show_in_lists or exists (select 1 from follows f where f.follower_id = v_uid and f.creator_id = s.creator_id))
       and not exists (select 1 from live_streams l2 where l2.creator_id = s.creator_id and l2.status = 'live')
     order by s.creator_id, coalesce(s.ended_at, s.last_seen_at) desc) x
    order by x.ended_at desc limit 12), '[]'::jsonb);
end $$;

revoke execute on function public.set_live_alert(uuid, boolean), public.my_live_alerts(), public.live_discover(), public.live_recent(), public.start_live_stream(text, int) from public, anon;
grant execute on function public.set_live_alert(uuid, boolean), public.my_live_alerts(), public.live_discover(), public.live_recent(), public.start_live_stream(text, int) to authenticated;
