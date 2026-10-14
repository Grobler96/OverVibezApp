-- 057: no prize cap, and runner-up prizes.
-- At the end of each month the top 3 creators are paid (after an admin has checked the gifts):
--   1st  100% of their Vibez value (£1 per 1,000 Vibez)
--   2nd   25% of their Vibez value
--   3rd   10% of their Vibez value
-- There is no cap unless the setting lb_prize_cap_cents is set above 0. Percentages are the settings lb_prize_pct_1/2/3.

alter table public.lb_prizes add column if not exists place int not null default 1;
alter table public.lb_prizes add column if not exists pct int not null default 100;
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'lb_prizes_month_key_key' and conrelid = 'public.lb_prizes'::regclass) then
    execute 'alter table public.lb_prizes dro' || 'p constraint lb_prizes_month_key_key';
  end if;
end $$;
create unique index if not exists lb_prizes_month_place_idx on public.lb_prizes (month_key, place);

-- the checks shown to the admin for one creator's month
create or replace function public._lb_prize_stats(p_month text, p_creator uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_month_end timestamptz := ((to_date(p_month || '-01', 'YYYY-MM-DD') + interval '1 month')::date)::timestamp at time zone 'Europe/London'; v_stats jsonb;
begin
  select jsonb_build_object(
    'supporters', count(distinct l.sender_id),
    'payments', count(*) filter (where l.kind in ('vibe', 'tip')),
    'bonus_vibez', coalesce(sum(l.vibez) filter (where l.kind = 'weekly_bonus'), 0),
    'new_accounts', count(distinct l.sender_id) filter (where exists (select 1 from profiles s where s.id = l.sender_id and s.created_at > v_month_end - interval '14 days')),
    'only_this_creator', count(distinct l.sender_id) filter (where not exists (select 1 from lb_ledger o where o.month_key = p_month and o.sender_id = l.sender_id and o.creator_id <> p_creator)),
    'top_supporters', (select coalesce(jsonb_agg(jsonb_build_object('username', sp.username, 'vibez', q.v) order by q.v desc), '[]'::jsonb)
                         from (select sender_id, sum(vibez) v from lb_ledger where month_key = p_month and creator_id = p_creator and sender_id is not null group by sender_id order by sum(vibez) desc limit 5) q
                         join profiles sp on sp.id = q.sender_id))
    into v_stats from lb_ledger l where l.month_key = p_month and l.creator_id = p_creator and l.kind in ('vibe', 'tip', 'weekly_bonus');
  return coalesce(v_stats, '{}'::jsonb);
end $$;

create or replace function public._lb_prize_cents(p_vibez bigint, p_place int) returns bigint
language sql stable security definer set search_path = public as $$
  select case when _ref_int('lb_prize_cap_cents', 0) > 0
              then least(p_vibez * _ref_int('lb_prize_pct_' || p_place, case p_place when 1 then 100 when 2 then 25 else 10 end) / _ref_int('lb_vibez_per_pound', 1000), _ref_int('lb_prize_cap_cents', 0))
              else p_vibez * _ref_int('lb_prize_pct_' || p_place, case p_place when 1 then 100 when 2 then 25 else 10 end) / _ref_int('lb_vibez_per_pound', 1000) end
$$;

create or replace function public._lb_close_month(p_month text) returns void
language plpgsql security definer set search_path = public as $$
declare v_rate int := _ref_int('lb_vibez_per_pound', 1000); v_cap bigint := _ref_int('lb_prize_cap_cents', 0);
        v_top jsonb; i int; tp jsonb; v_v bigint; v_pct int; v_calc bigint; v_amt bigint; v_total bigint := 0; v_first uuid; a record;
begin
  select coalesce(jsonb_agg(x order by (x->>'rank')::int), '[]'::jsonb) into v_top from (
    select jsonb_build_object('rank', row_number() over (order by t.v desc, t.last_at asc, t.creator_id), 'creator_id', t.creator_id, 'username', p.username,
             'display_name', p.display_name, 'avatar_url', p.avatar_url, 'is_verified', p.is_verified, 'vibez', t.v) as x
      from (select l.creator_id, sum(l.vibez)::bigint as v, max(l.created_at) as last_at from lb_ledger l join profiles pp on pp.id = l.creator_id and not pp.is_banned
             where l.month_key = p_month group by l.creator_id having sum(l.vibez) > 0 order by sum(l.vibez) desc, max(l.created_at) asc, l.creator_id limit 10) t
      join profiles p on p.id = t.creator_id) s;
  insert into lb_months(month_key, results, winner, winner_vibez) values (p_month, v_top, (v_top->0->>'creator_id')::uuid, (v_top->0->>'vibez')::bigint) on conflict (month_key) do nothing;
  for i in 1..3 loop
    tp := v_top->(i - 1); exit when tp is null;
    v_v := (tp->>'vibez')::bigint; v_pct := _ref_int('lb_prize_pct_' || i, case i when 1 then 100 when 2 then 25 else 10 end);
    v_calc := v_v * v_pct / v_rate; v_amt := case when v_cap > 0 then least(v_calc, v_cap) else v_calc end;
    continue when v_amt <= 0;
    insert into lb_prizes(month_key, place, pct, creator_id, vibez, calc_cents, amount_cents, capped, stats)
      values (p_month, i, v_pct, (tp->>'creator_id')::uuid, v_v, v_calc, v_amt, v_cap > 0 and v_calc > v_cap, _lb_prize_stats(p_month, (tp->>'creator_id')::uuid)) on conflict (month_key, place) do nothing;
    v_total := v_total + v_amt; if i = 1 then v_first := (tp->>'creator_id')::uuid; end if;
  end loop;
  if v_total > 0 then
    for a in select id from profiles where staff_role = 'admin' and not is_banned loop
      perform _notify(a.id, v_first, 'leaderboard_prize_review', null, jsonb_build_object('month', p_month, 'cents', v_total));
    end loop;
  end if;
end $$;

-- the board: prizes if the month ended now, and last month's prizes per place
create or replace function public.lb_board(p_scope text default 'week', p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_now timestamptz := now(); v_month text := _lb_month(now()); v_ws date := _lb_week_start(now()); v_we date;
        v_rate int := _ref_int('lb_vibez_per_pound', 1000);
        v_uid uuid := auth.uid(); v_rows jsonb; v_me jsonb; v_ends timestamptz; v_lead bigint; v_last text; v_m lb_months%rowtype; v_prizes jsonb;
        v_pcts jsonb := jsonb_build_array(_ref_int('lb_prize_pct_1', 100), _ref_int('lb_prize_pct_2', 25), _ref_int('lb_prize_pct_3', 10));
begin
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_we := _lb_week_end(v_ws);
  if p_scope = 'last' then
    v_last := to_char(date_trunc('month', v_now at time zone 'Europe/London') - interval '1 month', 'YYYY-MM');
    select * into v_m from lb_months where month_key = v_last;
    select coalesce(jsonb_agg(jsonb_build_object('place', z.place, 'status', case when z.status = 'paid' then 'paid' else 'pending' end, 'cents', case when z.status = 'paid' then z.amount_cents end, 'creator_id', z.creator_id) order by z.place), '[]'::jsonb)
      into v_prizes from lb_prizes z where z.month_key = v_last;
    return jsonb_build_object('scope', 'last', 'month', v_last, 'rate', v_rate, 'rows', coalesce(v_m.results, '[]'::jsonb), 'closed', v_m.month_key is not null,
      'prizes', v_prizes, 'prize_pcts', v_pcts, 'winner', v_m.winner, 'now', clock_timestamp());
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
                    'avatar_url', p.avatar_url, 'is_verified', p.is_verified, 'vibez', r.v, 'bonus', r.bonus,
                    'prize_cents', case when p_scope = 'month' and r.rk <= 3 then _lb_prize_cents(r.v, r.rk::int) end) order by r.rk), '[]'::jsonb)
            from (select * from ranked order by rk limit p_limit) r join profiles p on p.id = r.creator_id),
         (select jsonb_build_object('rank', r.rk, 'vibez', r.v, 'bonus', r.bonus) from ranked r where r.creator_id = v_uid),
         (select max(v) from agg)
    into v_rows, v_me, v_lead;
  return jsonb_build_object('scope', p_scope, 'month', v_month, 'week_start', v_ws, 'week_end', v_we, 'ends_at', v_ends, 'rate', v_rate, 'rows', v_rows, 'me', v_me,
    'leader_vibez', coalesce(v_lead, 0), 'prize_pcts', v_pcts,
    'bonuses', jsonb_build_array(_ref_int('lb_bonus_1', 10000), _ref_int('lb_bonus_2', 5000), _ref_int('lb_bonus_3', 2500)), 'now', clock_timestamp());
end $$;

create or replace function public.admin_lb_prizes(p_status text default 'pending') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'month', z.month_key, 'place', z.place, 'pct', z.pct, 'username', p.username, 'creator_id', z.creator_id, 'vibez', z.vibez,
            'calc_cents', z.calc_cents, 'amount_cents', z.amount_cents, 'capped', z.capped, 'status', z.status, 'stats', z.stats, 'note', z.note, 'decided_at', z.decided_at) order by z.month_key desc, z.place)
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
    perform _log('lb_prize_rejected', z.creator_id, jsonb_build_object('month', z.month_key, 'place', z.place, 'cents', z.amount_cents, 'note', left(coalesce(p_note, ''), 300)));
    return;
  end if;
  if exists (select 1 from profiles where id = z.creator_id and is_banned) then raise exception 'This creator is banned. Reject the prize instead'; end if;
  update profiles set bonus_cents = bonus_cents + z.amount_cents where id = z.creator_id;
  insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents) values (z.creator_id, 'admin_bonus', z.amount_cents, 0, z.amount_cents);
  update lb_prizes set status = 'paid', note = left(trim(coalesce(p_note, '')), 400), decided_by = auth.uid(), decided_at = now() where id = p_prize;
  perform _notify(z.creator_id, null, 'leaderboard_prize', null, jsonb_build_object('cents', z.amount_cents, 'month', z.month_key, 'vibez', z.vibez, 'place', z.place));
  perform _log('lb_prize_paid', z.creator_id, jsonb_build_object('month', z.month_key, 'place', z.place, 'cents', z.amount_cents));
end $$;

revoke execute on function public._lb_prize_stats(text, uuid), public._lb_prize_cents(bigint, int), public._lb_close_month(text) from public, anon, authenticated;
revoke execute on function public.lb_board(text, int), public.admin_lb_prizes(text), public.admin_lb_decide(uuid, boolean, text) from public;
grant execute on function public.lb_board(text, int) to anon, authenticated;
grant execute on function public.admin_lb_prizes(text), public.admin_lb_decide(uuid, boolean, text) to authenticated;
