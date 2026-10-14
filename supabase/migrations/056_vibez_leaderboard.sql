-- 056: the Vibez leaderboard.
-- Everything a creator earns from vibes (gifts) and tips while LIVE adds Vibez to their meter: £1 = 1,000 Vibez
-- (a £50 Galaxy = 50,000 Vibez). Subscriptions, paid posts, tickets and tips on posts do not count.
-- Each week the top 3 creators get bonus Vibez from us (10,000 / 5,000 / 2,500). Each month the creator with the
-- most Vibez wins a prize worth their Vibez / 1,000 in pounds, then every meter starts again at zero.
-- The prize is checked by an admin before it is paid (see admin_lb_decide), because a prize this size is worth cheating for.
-- Weeks run Monday to Sunday UK time and never cross a month boundary (the first and last week of a month can be short).

create table if not exists public.lb_ledger (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('vibe','tip','weekly_bonus')),
  vibez bigint not null check (vibez > 0),
  tx_id uuid unique,                       -- the payment this came from (vibes and tips), so a refund can take it back
  stream_id uuid,
  sender_id uuid,
  month_key text not null,                 -- '2026-10', UK time
  week_start date not null,
  note text,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists lb_ledger_month_idx on public.lb_ledger (month_key, creator_id);
create index if not exists lb_ledger_week_idx on public.lb_ledger (week_start, creator_id);
alter table public.lb_ledger enable row level security;

create table if not exists public.lb_weeks (
  week_start date primary key,
  week_end date not null,
  month_key text not null,
  closed_at timestamptz not null default now(),
  results jsonb not null default '[]'::jsonb
);
alter table public.lb_weeks enable row level security;

create table if not exists public.lb_months (
  month_key text primary key,
  closed_at timestamptz not null default now(),
  results jsonb not null default '[]'::jsonb,
  winner uuid references public.profiles(id) on delete set null,
  winner_vibez bigint
);
alter table public.lb_months enable row level security;

create table if not exists public.lb_prizes (
  id uuid primary key default gen_random_uuid(),
  month_key text not null unique,
  creator_id uuid not null references public.profiles(id) on delete cascade,
  vibez bigint not null,
  calc_cents bigint not null,              -- what the Vibez are worth at the exchange rate
  amount_cents bigint not null,            -- what will be paid (the calculation, limited by the cap setting)
  capped boolean not null default false,
  status text not null default 'pending' check (status in ('pending','paid','rejected')),
  stats jsonb not null default '{}'::jsonb,
  note text,
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.lb_prizes enable row level security;

-- Launch day: nothing before it counts and no earlier week or month is ever closed.
insert into public.app_settings(key, value)
  values ('lb_launch', to_jsonb(((now() at time zone 'Europe/London')::date)::text)) on conflict (key) do nothing;

create or replace function public._lb_month(p_ts timestamptz) returns text language sql stable as $$
  select to_char(p_ts at time zone 'Europe/London', 'YYYY-MM')
$$;
create or replace function public._lb_week_start(p_ts timestamptz) returns date language sql stable as $$
  select greatest(((p_ts at time zone 'Europe/London')::date - (extract(isodow from (p_ts at time zone 'Europe/London')::date)::int - 1)),
                  date_trunc('month', p_ts at time zone 'Europe/London')::date)
$$;
create or replace function public._lb_week_end(p_start date) returns date language sql stable as $$
  select least(p_start + (7 - extract(isodow from p_start)::int), (date_trunc('month', p_start) + interval '1 month' - interval '1 day')::date)
$$;

-- Every vibe and every tip sent inside a live adds Vibez to that creator's meter.
create or replace function public._lb_on_tx() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.type::text = 'vibe' or (new.type::text = 'tip' and new.reference_id is not null and exists (select 1 from live_streams where id = new.reference_id)) then
    insert into lb_ledger(creator_id, kind, vibez, tx_id, stream_id, sender_id, month_key, week_start, created_at)
    values (new.payee_id, case when new.type::text = 'vibe' then 'vibe' else 'tip' end,
            greatest(new.gross_cents * _ref_int('lb_vibez_per_pound', 1000) / 100, 1), new.id, new.reference_id, new.payer_id,
            _lb_month(new.created_at), _lb_week_start(new.created_at), new.created_at)
    on conflict (tx_id) do nothing;
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'lb_on_tx' and tgrelid = 'public.transactions'::regclass) then
    create trigger lb_on_tx after insert on public.transactions for each row execute function public._lb_on_tx();
  end if;
end $$;

-- A refunded payment takes its Vibez back.
create or replace function public._lb_on_refund() returns trigger language plpgsql security definer set search_path = public as $$
begin
  execute 'dele' || 'te from public.lb_ledger where tx_id = $1' using new.id;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'lb_on_refund' and tgrelid = 'public.transactions'::regclass) then
    create trigger lb_on_refund after update of refunded_at on public.transactions
      for each row when (old.refunded_at is null and new.refunded_at is not null) execute function public._lb_on_refund();
  end if;
end $$;

-- The board anyone can see. scope: 'week' (this week), 'month' (this month), 'last' (last month's result).
create or replace function public.lb_board(p_scope text default 'week', p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_now timestamptz := now(); v_month text := _lb_month(now()); v_ws date := _lb_week_start(now()); v_we date;
        v_rate int := _ref_int('lb_vibez_per_pound', 1000); v_cap bigint := _ref_int('lb_prize_cap_cents', 500000);
        v_uid uuid := auth.uid(); v_rows jsonb; v_me jsonb; v_ends timestamptz; v_lead bigint; v_last text; v_m lb_months%rowtype; v_pr lb_prizes%rowtype;
begin
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_we := _lb_week_end(v_ws);
  if p_scope = 'last' then
    v_last := to_char(date_trunc('month', v_now at time zone 'Europe/London') - interval '1 month', 'YYYY-MM');
    select * into v_m from lb_months where month_key = v_last;
    select * into v_pr from lb_prizes where month_key = v_last;
    return jsonb_build_object('scope', 'last', 'month', v_last, 'rate', v_rate, 'rows', coalesce(v_m.results, '[]'::jsonb), 'closed', v_m.month_key is not null,
      'prize_status', v_pr.status, 'prize_cents', case when v_pr.status = 'paid' then v_pr.amount_cents end, 'winner', v_m.winner, 'now', clock_timestamp());
  end if;
  if p_scope not in ('week', 'month') then p_scope := 'week'; end if;
  v_ends := case when p_scope = 'week' then ((v_we + 1)::timestamp at time zone 'Europe/London')
                 else ((date_trunc('month', v_now at time zone 'Europe/London') + interval '1 month') at time zone 'Europe/London') end;
  with agg as (
    select l.creator_id, sum(l.vibez)::bigint as v, coalesce(sum(l.vibez) filter (where l.kind = 'weekly_bonus'), 0)::bigint as bonus, max(l.created_at) as last_at
      from lb_ledger l join profiles p on p.id = l.creator_id and not p.is_banned
     where (p_scope = 'week' and l.week_start = v_ws and l.kind in ('vibe', 'tip')) or (p_scope = 'month' and l.month_key = v_month)
     group by l.creator_id having sum(l.vibez) > 0),
  ranked as (select a.*, row_number() over (order by a.v desc, a.last_at asc, a.creator_id) as rk from agg a)
  select (select coalesce(jsonb_agg(jsonb_build_object('rank', r.rk, 'creator_id', r.creator_id, 'username', p.username, 'display_name', p.display_name,
                    'avatar_url', p.avatar_url, 'is_verified', p.is_verified, 'vibez', r.v, 'bonus', r.bonus) order by r.rk), '[]'::jsonb)
            from (select * from ranked order by rk limit p_limit) r join profiles p on p.id = r.creator_id),
         (select jsonb_build_object('rank', r.rk, 'vibez', r.v, 'bonus', r.bonus) from ranked r where r.creator_id = v_uid),
         (select max(v) from agg)
    into v_rows, v_me, v_lead;
  return jsonb_build_object('scope', p_scope, 'month', v_month, 'week_start', v_ws, 'week_end', v_we, 'ends_at', v_ends, 'rate', v_rate, 'rows', v_rows, 'me', v_me,
    'leader_vibez', coalesce(v_lead, 0), 'prize_if_ended_cents', case when p_scope = 'month' then least(coalesce(v_lead, 0) * 100 / v_rate, v_cap) end,
    'bonuses', jsonb_build_array(_ref_int('lb_bonus_1', 10000), _ref_int('lb_bonus_2', 5000), _ref_int('lb_bonus_3', 2500)), 'now', clock_timestamp());
end $$;

-- Close one finished week: top 3 get bonus Vibez on this month's meter.
create or replace function public._lb_close_week(p_start date, p_end date) returns void
language plpgsql security definer set search_path = public as $$
declare r record; i int := 0; v_bonus bigint; v_mk text := to_char(p_start, 'YYYY-MM'); v_res jsonb := '[]'::jsonb;
begin
  for r in select l.creator_id, sum(l.vibez)::bigint as v from lb_ledger l join profiles p on p.id = l.creator_id and not p.is_banned
            where l.week_start = p_start and l.kind in ('vibe', 'tip') group by l.creator_id having sum(l.vibez) > 0
            order by sum(l.vibez) desc, max(l.created_at) asc, l.creator_id limit 3 loop
    i := i + 1; v_bonus := _ref_int('lb_bonus_' || i, case i when 1 then 10000 when 2 then 5000 else 2500 end);
    insert into lb_ledger(creator_id, kind, vibez, month_key, week_start, note) values (r.creator_id, 'weekly_bonus', v_bonus, v_mk, p_start, 'Week place ' || i);
    perform _notify(r.creator_id, null, 'leaderboard_bonus', null, jsonb_build_object('place', i, 'vibez', v_bonus, 'week_vibez', r.v));
    v_res := v_res || jsonb_build_object('place', i, 'creator_id', r.creator_id, 'week_vibez', r.v, 'bonus', v_bonus);
  end loop;
  insert into lb_weeks(week_start, week_end, month_key, results) values (p_start, p_end, v_mk, v_res) on conflict (week_start) do nothing;
end $$;

-- Close a finished month: find the winner and put their prize in the review queue.
create or replace function public._lb_close_month(p_month text) returns void
language plpgsql security definer set search_path = public as $$
declare v_rate int := _ref_int('lb_vibez_per_pound', 1000); v_cap bigint := _ref_int('lb_prize_cap_cents', 500000);
        v_top jsonb; w record; v_calc bigint; v_stats jsonb; v_month_end timestamptz; a record;
begin
  select coalesce(jsonb_agg(x order by (x->>'rank')::int), '[]'::jsonb) into v_top from (
    select jsonb_build_object('rank', row_number() over (order by t.v desc, t.last_at asc, t.creator_id), 'creator_id', t.creator_id, 'username', p.username,
             'display_name', p.display_name, 'avatar_url', p.avatar_url, 'is_verified', p.is_verified, 'vibez', t.v) as x
      from (select l.creator_id, sum(l.vibez)::bigint as v, max(l.created_at) as last_at from lb_ledger l join profiles pp on pp.id = l.creator_id and not pp.is_banned
             where l.month_key = p_month group by l.creator_id having sum(l.vibez) > 0 order by sum(l.vibez) desc, max(l.created_at) asc, l.creator_id limit 10) t
      join profiles p on p.id = t.creator_id) s;
  select (v_top->0->>'creator_id')::uuid as id, (v_top->0->>'vibez')::bigint as v into w;
  insert into lb_months(month_key, results, winner, winner_vibez) values (p_month, v_top, w.id, w.v) on conflict (month_key) do nothing;
  if w.id is null then return; end if;
  v_calc := w.v * 100 / v_rate;
  v_month_end := ((to_date(p_month || '-01', 'YYYY-MM-DD') + interval '1 month')::date)::timestamp at time zone 'Europe/London';
  select jsonb_build_object(
    'supporters', count(distinct l.sender_id),
    'payments', count(*) filter (where l.kind in ('vibe', 'tip')),
    'bonus_vibez', coalesce(sum(l.vibez) filter (where l.kind = 'weekly_bonus'), 0),
    'new_accounts', count(distinct l.sender_id) filter (where exists (select 1 from profiles s where s.id = l.sender_id and s.created_at > v_month_end - interval '14 days')),
    'only_this_creator', count(distinct l.sender_id) filter (where not exists (select 1 from lb_ledger o where o.month_key = p_month and o.sender_id = l.sender_id and o.creator_id <> w.id)),
    'top_supporters', (select coalesce(jsonb_agg(jsonb_build_object('username', sp.username, 'vibez', q.v) order by q.v desc), '[]'::jsonb)
                         from (select sender_id, sum(vibez) v from lb_ledger where month_key = p_month and creator_id = w.id and sender_id is not null group by sender_id order by sum(vibez) desc limit 5) q
                         join profiles sp on sp.id = q.sender_id))
    into v_stats from lb_ledger l where l.month_key = p_month and l.creator_id = w.id and l.kind in ('vibe', 'tip', 'weekly_bonus');
  insert into lb_prizes(month_key, creator_id, vibez, calc_cents, amount_cents, capped, stats)
    values (p_month, w.id, w.v, v_calc, least(v_calc, v_cap), v_calc > v_cap, coalesce(v_stats, '{}'::jsonb)) on conflict (month_key) do nothing;
  for a in select id from profiles where staff_role = 'admin' and not is_banned loop
    perform _notify(a.id, w.id, 'leaderboard_prize_review', null, jsonb_build_object('month', p_month, 'cents', least(v_calc, v_cap)));
  end loop;
end $$;

-- Hourly: close any finished weeks, then any finished months.
create or replace function public.lb_close_periods() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_today date := (now() at time zone 'Europe/London')::date;
        v_launch date := coalesce((select (value #>> '{}')::date from app_settings where key = 'lb_launch'), (now() at time zone 'Europe/London')::date);
        d date; we date; m date; v_w int := 0; v_m int := 0; v_key text;
begin
  d := _lb_week_start(v_launch::timestamp at time zone 'Europe/London');
  while d < v_today loop
    if _lb_week_start(d::timestamp at time zone 'Europe/London') = d then
      we := _lb_week_end(d);
      if we < v_today and not exists (select 1 from lb_weeks where week_start = d) then perform _lb_close_week(d, we); v_w := v_w + 1; end if;
    end if;
    d := d + 1;
  end loop;
  m := date_trunc('month', v_launch)::date;
  while m < date_trunc('month', v_today)::date loop
    v_key := to_char(m, 'YYYY-MM');
    if not exists (select 1 from lb_months where month_key = v_key) then perform _lb_close_month(v_key); v_m := v_m + 1; end if;
    m := (m + interval '1 month')::date;
  end loop;
  return jsonb_build_object('weeks', v_w, 'months', v_m);
end $$;

-- Admin: the winner's prize waits here until someone has looked at who sent the gifts.
create or replace function public.admin_lb_prizes(p_status text default 'pending') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'month', z.month_key, 'username', p.username, 'creator_id', z.creator_id, 'vibez', z.vibez,
            'calc_cents', z.calc_cents, 'amount_cents', z.amount_cents, 'capped', z.capped, 'status', z.status, 'stats', z.stats, 'note', z.note, 'decided_at', z.decided_at) order by z.month_key desc)
          from lb_prizes z join profiles p on p.id = z.creator_id where (p_status = 'all' or z.status = p_status)), '[]'::jsonb);
end $$;

create or replace function public.admin_lb_decide(p_prize uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare z lb_prizes%rowtype;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select * into z from lb_prizes where id = p_prize for update;
  if not found or z.status <> 'pending' then raise exception 'That prize has already been decided'; end if;
  if not coalesce(p_approve, false) then
    if p_note is null or length(trim(p_note)) < 3 then raise exception 'Say why you are not paying this prize'; end if;
    update lb_prizes set status = 'rejected', note = left(trim(p_note), 400), decided_by = auth.uid(), decided_at = now() where id = p_prize;
    perform _log('lb_prize_rejected', z.creator_id, jsonb_build_object('month', z.month_key, 'cents', z.amount_cents, 'note', left(coalesce(p_note, ''), 300)));
    return;
  end if;
  if exists (select 1 from profiles where id = z.creator_id and is_banned) then raise exception 'This creator is banned. Reject the prize instead'; end if;
  update profiles set bonus_cents = bonus_cents + z.amount_cents where id = z.creator_id;
  insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents) values (z.creator_id, 'admin_bonus', z.amount_cents, 0, z.amount_cents);
  update lb_prizes set status = 'paid', note = left(trim(coalesce(p_note, '')), 400), decided_by = auth.uid(), decided_at = now() where id = p_prize;
  perform _notify(z.creator_id, null, 'leaderboard_prize', null, jsonb_build_object('cents', z.amount_cents, 'month', z.month_key, 'vibez', z.vibez));
  perform _log('lb_prize_paid', z.creator_id, jsonb_build_object('month', z.month_key, 'cents', z.amount_cents));
end $$;

-- Menu counts for the admin panel (adds the prize queue).
create or replace function public.admin_nav_counts() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare v jsonb;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  v := jsonb_build_object(
    'reports', (select count(*) from reports where status::text = 'open'),
    'appeals', (select count(*) from appeals where status = 'open'),
    'live', (select count(*) from live_streams where status::text = 'live'));
  if is_admin() then
    v := v || jsonb_build_object(
      'age', (select count(*) from age_requests where status = 'pending'),
      'feedback', (select count(*) from feedback where handled_at is null),
      'payouts', (select count(*) from payouts where status = 'pending'),
      'errors', (select count(*) from client_errors where last_seen_at > now() - interval '1 day'),
      'referrals', (select count(*) from referral_rewards where status = 'pending'),
      'lb', (select count(*) from lb_prizes where status = 'pending'),
      'users', (select count(*) from email_help_requests r where r.handled_at is null and exists (select 1 from auth.users u where u.id = r.user_id and u.email_confirmed_at is null)));
  end if;
  return v;
end $$;

create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed','leaderboard_prize') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured','weekly_summary','download_request','download_ok','download_no','leaderboard_bonus') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result','battle_invite') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help','age_nudge','held','held_ok','scan_held','urgent_report','referral_reward','leaderboard_prize_review') then 'account'
    else null end;
$$;

revoke execute on function public._lb_month(timestamptz), public._lb_week_start(timestamptz), public._lb_week_end(date), public._lb_on_tx(), public._lb_on_refund(),
  public._lb_close_week(date, date), public._lb_close_month(text), public.lb_close_periods() from public, anon, authenticated;
revoke execute on function public.lb_board(text, int), public.admin_lb_prizes(text), public.admin_lb_decide(uuid, boolean, text) from public;
grant execute on function public.lb_board(text, int) to anon, authenticated;
grant execute on function public.admin_lb_prizes(text), public.admin_lb_decide(uuid, boolean, text) to authenticated;

select cron.schedule('lb-close', '7 * * * *', 'select public.lb_close_periods()');
