-- 031: "Sending Vibez" — viewers send animated gifts ("vibes") to a creator during a live stream; they become earnings (creator keeps 85%).
-- NOTE: the enum value must be added on its own first:  alter type public.tx_type add value if not exists 'vibe';

-- The menu of vibes. Prices are in pence. (Add or retune rows here; the app reads this table.)
create table if not exists public.vibe_types (
  key text primary key,
  label text not null,
  emoji text not null,
  price_cents int not null check (price_cents between 50 and 10000),
  sort int not null default 0,
  active boolean not null default true);
insert into public.vibe_types(key, label, emoji, price_cents, sort) values
  ('spark',  'Spark',  '✨', 100, 1),
  ('love',   'Love',   '💜', 200, 2),
  ('fire',   'Fire',   '🔥', 500, 3),
  ('rocket', 'Rocket', '🚀', 1000, 4),
  ('crown',  'Crown',  '👑', 2500, 5),
  ('galaxy', 'Galaxy', '🌌', 5000, 6)
on conflict (key) do nothing;
alter table public.vibe_types enable row level security;
create policy vibe_types_read on public.vibe_types for select using (true);
revoke insert, update, delete on public.vibe_types from anon, authenticated;
grant select on public.vibe_types to anon, authenticated;

-- Every vibe sent, so everyone in the room sees it (realtime) and the creator can see totals.
create table if not exists public.live_vibes (
  id uuid primary key default gen_random_uuid(),
  stream_id uuid not null references public.live_streams(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  vibe_key text not null references public.vibe_types(key),
  qty int not null check (qty between 1 and 50),
  cents int not null check (cents > 0),
  created_at timestamptz not null default now());
create index if not exists live_vibes_stream_idx on public.live_vibes (stream_id, created_at);
create index if not exists live_vibes_sender_idx on public.live_vibes (sender_id);
alter table public.live_vibes enable row level security;
create policy live_vibes_read on public.live_vibes for select using (public.live_can_watch(stream_id));
revoke all on public.live_vibes from anon, authenticated;
grant select on public.live_vibes to authenticated;
alter publication supabase_realtime add table public.live_vibes;

-- Send vibes: charged to the wallet, 85% to the creator, 15% to OverVibez. Only while the stream is live.
create or replace function public.send_vibe(p_stream uuid, p_vibe text, p_qty int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype; v vibe_types%rowtype; v_total int; v_id uuid;
begin
  perform _require_adult();
  if not not_banned() then raise exception 'Account suspended'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 50 then raise exception 'You can send between 1 and 50 at a time'; end if;
  select * into s from live_streams where id = p_stream and status = 'live';
  if not found then raise exception 'This stream is not live'; end if;
  if s.creator_id = auth.uid() then raise exception 'You cannot send vibes to yourself'; end if;
  if not live_can_watch(p_stream) then raise exception 'Get a ticket to join this stream first'; end if;
  select * into v from vibe_types where key = p_vibe and active;
  if not found then raise exception 'That vibe is not available'; end if;
  v_total := v.price_cents * p_qty;
  perform _settle(s.creator_id, v_total, 'vibe', p_stream);
  insert into live_vibes(stream_id, sender_id, vibe_key, qty, cents) values (p_stream, auth.uid(), v.key, p_qty, v_total) returning id into v_id;
  return jsonb_build_object('id', v_id, 'cents', v_total);
end $$;

-- What the room shows: how many vibes so far, the top three senders (names only, no amounts), and for the creator what they earned.
create or replace function public.live_vibe_summary(p_stream uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s live_streams%rowtype;
begin
  select * into s from live_streams where id = p_stream;
  if not found or not live_can_watch(p_stream) then return jsonb_build_object('count', 0, 'top', '[]'::jsonb); end if;
  return jsonb_build_object(
    'count', (select coalesce(sum(qty), 0) from live_vibes where stream_id = p_stream),
    'top', (select coalesce(jsonb_agg(x.sender_id order by x.t desc), '[]'::jsonb) from (select sender_id, sum(cents) t from live_vibes where stream_id = p_stream group by sender_id order by sum(cents) desc limit 3) x),
    'earned_cents', case when s.creator_id = auth.uid() then (select coalesce(sum(cents), 0) - coalesce(sum(round(cents * 0.15)), 0) from live_vibes where stream_id = p_stream) else null end);
end $$;

revoke execute on function public.send_vibe(uuid, text, int), public.live_vibe_summary(uuid) from public, anon;
grant execute on function public.send_vibe(uuid, text, int), public.live_vibe_summary(uuid) to authenticated;

-- The stream-ended summary also reports vibes.
create or replace function public.end_live_stream(p_stream uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype;
begin
  update live_streams set status = 'ended', ended_at = now() where id = p_stream and creator_id = auth.uid() and status = 'live' returning * into s;
  if not found then raise exception 'This stream has already ended'; end if;
  return jsonb_build_object('tickets', (select count(*) from live_tickets where stream_id = p_stream),
    'ticket_gross_cents', (select coalesce(sum(amount_cents),0) from live_tickets where stream_id = p_stream),
    'vibes', (select coalesce(sum(qty),0) from live_vibes where stream_id = p_stream),
    'vibe_gross_cents', (select coalesce(sum(cents),0) from live_vibes where stream_id = p_stream),
    'duration_seconds', extract(epoch from (s.ended_at - s.started_at))::int);
end $$;

-- Vibes count in the creator's analytics and in the admin sales figures.
create or replace function public.creator_analytics(p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_days int := least(greatest(coalesce(p_days, 30), 7), 365); v_from date; v_tz text := 'Europe/London';
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = v_uid and account_type = 'creator') then raise exception 'Creators only'; end if;
  v_from := (now() at time zone v_tz)::date - (v_days - 1);
  return jsonb_build_object(
    'days', v_days,
    'series', (select coalesce(jsonb_agg(jsonb_build_object('d', to_char(g.d, 'YYYY-MM-DD'), 'net', coalesce(s.net, 0), 'followers', coalesce(f.n, 0)) order by g.d), '[]'::jsonb)
               from generate_series(v_from, (now() at time zone v_tz)::date, interval '1 day') as g(d)
               left join (select (created_at at time zone v_tz)::date d, sum(net_cents) net from transactions
                          where payee_id = v_uid and type in ('subscription','post_unlock','tip','live_entry','vibe') and created_at >= v_from::timestamp at time zone v_tz group by 1) s on s.d = g.d::date
               left join (select (created_at at time zone v_tz)::date d, count(*) n from follows
                          where creator_id = v_uid and created_at >= v_from::timestamp at time zone v_tz group by 1) f on f.d = g.d::date),
    'by_type', (select coalesce(jsonb_object_agg(type, jsonb_build_object('net', net, 'count', n)), '{}'::jsonb)
                from (select type::text, sum(net_cents) net, count(*) n from transactions
                      where payee_id = v_uid and type in ('subscription','post_unlock','tip','live_entry','vibe') and created_at >= v_from::timestamp at time zone v_tz group by type) t),
    'top_posts', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'caption', left(coalesce(x.caption, '(media post)'), 80), 'net', x.net, 'sales', x.n) order by x.net desc), '[]'::jsonb)
                  from (select po.id, po.caption, sum(t.net_cents) net, count(*) n from transactions t join posts po on po.id = t.reference_id
                        where t.payee_id = v_uid and t.type in ('post_unlock','tip') and po.creator_id = v_uid and t.created_at >= v_from::timestamp at time zone v_tz
                        group by po.id, po.caption order by sum(t.net_cents) desc limit 5) x),
    'followers_total', (select follower_count from profiles where id = v_uid));
end $$;

create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'users', (select count(*) from profiles),
    'creators', (select count(*) from profiles where account_type = 'creator'),
    'followers', (select count(*) from profiles where account_type = 'follower'),
    'age_verified', (select count(*) from profiles where age_verified),
    'banned', (select count(*) from profiles where is_banned),
    'new_users_7d', (select count(*) from profiles where created_at > now() - interval '7 days'),
    'posts', (select count(*) from posts where removed_at is null),
    'posts_removed', (select count(*) from posts where removed_at is not null),
    'comments', (select count(*) from comments where removed_at is null),
    'open_reports', (select count(*) from reports where status = 'open'),
    'gross_cents', (select coalesce(sum(gross_cents),0) from transactions where type in ('post_unlock','subscription','tip','live_entry','vibe')),
    'platform_fees_cents', (select coalesce(sum(fee_cents),0) from transactions where type in ('post_unlock','subscription','tip','live_entry','vibe')),
    'raffle_revenue_cents', (select coalesce(sum(gross_cents),0) from transactions where type = 'raffle_entry'),
    'wallet_liability_cents', (select coalesce(sum(wallet_cents),0) from profiles),
    'creator_earnings_owed_cents', (select coalesce(sum(earnings_cents),0) from profiles),
    'pending_payouts_cents', (select coalesce(sum(amount_cents),0) from payouts where status = 'pending'),
    'pending_payouts', (select count(*) from payouts where status = 'pending'),
    'bonuses_paid_cents', (select coalesce(sum(gross_cents),0) from transactions where type = 'admin_bonus'),
    'bonus_owed_cents', (select coalesce(sum(bonus_cents),0) from profiles),
    'wallet_credits_cents', (select coalesce(sum(gross_cents),0) from transactions where type = 'admin_credit'));
end $$;

