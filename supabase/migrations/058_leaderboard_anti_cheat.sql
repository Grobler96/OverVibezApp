-- 058: make the leaderboard harder to cheat.
-- 1) One supporter can only count for 25% of a creator's total for the week or month (setting lb_supporter_cap_pct),
--    but every supporter always counts up to 10,000 Vibez in full (setting lb_supporter_floor_vibez), so small creators are not hurt.
-- 2) An approved prize is not paid straight away. It waits 14 days (setting lb_prize_hold_days) so refunds and chargebacks
--    can land first. When the wait ends the prize is recalculated and can only go down, never up. An admin can still cancel it before then.

alter table public.lb_prizes add column if not exists release_at timestamptz;
alter table public.lb_prizes add column if not exists raw_vibez bigint;
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.lb_prizes'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%status%' loop
    execute 'alter table public.lb_prizes dro' || 'p constraint ' || quote_ident(c);
  end loop;
  alter table public.lb_prizes add constraint lb_prizes_status_check check (status in ('pending','approved','paid','rejected'));
end $$;

-- Each creator's score for one week (p_week) or one month (p_week null), with the per-supporter limit applied.
-- raw is the total before the limit (shown to admins).
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
         where p_week is null and l.kind = 'weekly_bonus' and l.month_key = p_month group by l.creator_id)
  select c.creator_id, (c.v + coalesce(b.bv, 0))::bigint, c.raw, coalesce(b.bv, 0)::bigint, c.last_at
    from c left join b on b.creator_id = c.creator_id
$$;

-- The week closes on the limited score.
create or replace function public._lb_close_week(p_start date, p_end date) returns void
language plpgsql security definer set search_path = public as $$
declare r record; i int := 0; v_bonus bigint; v_mk text := to_char(p_start, 'YYYY-MM'); v_res jsonb := '[]'::jsonb;
begin
  for r in select sc.creator_id, sc.v from _lb_scores(v_mk, p_start) sc where sc.v > 0 order by sc.v desc, sc.last_at asc, sc.creator_id limit 3 loop
    i := i + 1; v_bonus := _ref_int('lb_bonus_' || i, case i when 1 then 10000 when 2 then 5000 else 2500 end);
    insert into lb_ledger(creator_id, kind, vibez, month_key, week_start, note) values (r.creator_id, 'weekly_bonus', v_bonus, v_mk, p_start, 'Week place ' || i);
    perform _notify(r.creator_id, null, 'leaderboard_bonus', null, jsonb_build_object('place', i, 'vibez', v_bonus, 'week_vibez', r.v));
    v_res := v_res || jsonb_build_object('place', i, 'creator_id', r.creator_id, 'week_vibez', r.v, 'bonus', v_bonus);
  end loop;
  insert into lb_weeks(week_start, week_end, month_key, results) values (p_start, p_end, v_mk, v_res) on conflict (week_start) do nothing;
end $$;

-- The month closes on the limited score. The prize row keeps the unlimited total too, so the admin can see the difference.
create or replace function public._lb_close_month(p_month text) returns void
language plpgsql security definer set search_path = public as $$
declare v_rate int := _ref_int('lb_vibez_per_pound', 1000); v_cap bigint := _ref_int('lb_prize_cap_cents', 0);
        v_top jsonb; i int; tp jsonb; v_v bigint; v_pct int; v_calc bigint; v_amt bigint; v_total bigint := 0; v_first uuid; a record; v_cid uuid; v_raw bigint;
begin
  select coalesce(jsonb_agg(x order by (x->>'rank')::int), '[]'::jsonb) into v_top from (
    select jsonb_build_object('rank', row_number() over (order by t.v desc, t.last_at asc, t.creator_id), 'creator_id', t.creator_id, 'username', p.username,
             'display_name', p.display_name, 'avatar_url', p.avatar_url, 'is_verified', p.is_verified, 'vibez', t.v, 'raw', t.raw) as x
      from (select sc.creator_id, sc.v, sc.raw, sc.last_at from _lb_scores(p_month, null) sc where sc.v > 0 order by sc.v desc, sc.last_at asc, sc.creator_id limit 10) t
      join profiles p on p.id = t.creator_id) s;
  insert into lb_months(month_key, results, winner, winner_vibez) values (p_month, v_top, (v_top->0->>'creator_id')::uuid, (v_top->0->>'vibez')::bigint) on conflict (month_key) do nothing;
  for i in 1..3 loop
    tp := v_top->(i - 1); exit when tp is null;
    v_cid := (tp->>'creator_id')::uuid; v_v := (tp->>'vibez')::bigint; v_raw := (tp->>'raw')::bigint;
    v_pct := _ref_int('lb_prize_pct_' || i, case i when 1 then 100 when 2 then 25 else 10 end);
    v_calc := v_v * v_pct / v_rate; v_amt := case when v_cap > 0 then least(v_calc, v_cap) else v_calc end;
    continue when v_amt <= 0;
    insert into lb_prizes(month_key, place, pct, creator_id, vibez, raw_vibez, calc_cents, amount_cents, capped, stats)
      values (p_month, i, v_pct, v_cid, v_v, v_raw, v_calc, v_amt, v_cap > 0 and v_calc > v_cap, _lb_prize_stats(p_month, v_cid)) on conflict (month_key, place) do nothing;
    v_total := v_total + v_amt; if i = 1 then v_first := v_cid; end if;
  end loop;
  if v_total > 0 then
    for a in select id from profiles where staff_role = 'admin' and not is_banned loop
      perform _notify(a.id, v_first, 'leaderboard_prize_review', null, jsonb_build_object('month', p_month, 'cents', v_total));
    end loop;
  end if;
end $$;

-- The board uses the limited score as well.
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
    select coalesce(jsonb_agg(jsonb_build_object('place', z.place, 'status', case when z.status = 'paid' then 'paid' else 'pending' end,
             'cents', case when z.status = 'paid' then z.amount_cents end, 'creator_id', z.creator_id) order by z.place), '[]'::jsonb)
      into v_prizes from lb_prizes z where z.month_key = v_last;
    return jsonb_build_object('scope', 'last', 'month', v_last, 'rate', v_rate, 'rows', coalesce(v_m.results, '[]'::jsonb) , 'closed', v_m.month_key is not null,
      'prizes', v_prizes, 'prize_pcts', v_pcts, 'winner', v_m.winner, 'now', clock_timestamp());
  end if;
  if p_scope not in ('week', 'month') then p_scope := 'week'; end if;
  v_ends := case when p_scope = 'week' then ((v_we + 1)::timestamp at time zone 'Europe/London')
                 else ((date_trunc('month', v_now at time zone 'Europe/London') + interval '1 month') at time zone 'Europe/London') end;
  with agg as (select sc.creator_id, sc.v, sc.bonus, sc.last_at from _lb_scores(v_month, case when p_scope = 'week' then v_ws end) sc where sc.v > 0),
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
            'raw_vibez', coalesce(z.raw_vibez, z.vibez), 'release_at', z.release_at,
            'calc_cents', z.calc_cents, 'amount_cents', z.amount_cents, 'capped', z.capped, 'status', z.status, 'stats', z.stats, 'note', z.note, 'decided_at', z.decided_at) order by z.month_key desc, z.place)
          from lb_prizes z join profiles p on p.id = z.creator_id where (p_status = 'all' or z.status = p_status)), '[]'::jsonb);
end $$;

-- Approving no longer pays. It starts the wait. Rejecting also works on a prize that is waiting (for example after a chargeback).
create or replace function public.admin_lb_decide(p_prize uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare z lb_prizes%rowtype; v_days int := _ref_int('lb_prize_hold_days', 14); v_at timestamptz;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select * into z from lb_prizes where id = p_prize for update;
  if not found or z.status not in ('pending', 'approved') then raise exception 'That prize has already been decided'; end if;
  if not coalesce(p_approve, false) then
    if p_note is null or length(trim(p_note)) < 3 then raise exception 'Say why you are not paying this prize'; end if;
    update lb_prizes set status = 'rejected', note = left(trim(p_note), 400), decided_by = auth.uid(), decided_at = now() where id = p_prize;
    perform _log('lb_prize_rejected', z.creator_id, jsonb_build_object('month', z.month_key, 'place', z.place, 'cents', z.amount_cents, 'note', left(coalesce(p_note, ''), 300)));
    return;
  end if;
  if z.status <> 'pending' then raise exception 'That prize is already approved and waiting'; end if;
  if exists (select 1 from profiles where id = z.creator_id and is_banned) then raise exception 'This creator is banned. Reject the prize instead'; end if;
  v_at := now() + make_interval(days => v_days);
  update lb_prizes set status = 'approved', release_at = v_at, note = left(trim(coalesce(p_note, '')), 400), decided_by = auth.uid(), decided_at = now() where id = p_prize;
  perform _notify(z.creator_id, null, 'leaderboard_prize_held', null, jsonb_build_object('cents', z.amount_cents, 'month', z.month_key, 'place', z.place, 'release_at', v_at));
  perform _log('lb_prize_approved', z.creator_id, jsonb_build_object('month', z.month_key, 'place', z.place, 'cents', z.amount_cents, 'release_at', v_at));
end $$;

-- Hourly: pay approved prizes whose wait is over. The prize is recalculated first (refunds may have removed gifts) and can only go down.
create or replace function public.lb_release_prizes() returns int
language plpgsql security definer set search_path = public as $$
declare z record; v_now bigint; v_amt bigint; n int := 0;
begin
  for z in select * from lb_prizes where status = 'approved' and release_at <= now() order by release_at for update skip locked loop
    if exists (select 1 from profiles where id = z.creator_id and is_banned) then
      update lb_prizes set status = 'rejected', note = 'Creator was banned before the prize was released' where id = z.id;
      continue;
    end if;
    select coalesce((select sc.v from _lb_scores(z.month_key, null) sc where sc.creator_id = z.creator_id), 0) into v_now;
    -- scores skip banned creators and only count payments that were not refunded
    v_amt := least(z.amount_cents, _lb_prize_cents(least(z.vibez, v_now), z.place));
    if v_amt <= 0 then
      update lb_prizes set status = 'rejected', note = 'Nothing left to pay after refunds' where id = z.id;
      continue;
    end if;
    update profiles set bonus_cents = bonus_cents + v_amt where id = z.creator_id;
    insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents) values (z.creator_id, 'admin_bonus', v_amt, 0, v_amt);
    update lb_prizes set status = 'paid', amount_cents = v_amt, decided_at = now() where id = z.id;
    perform _notify(z.creator_id, null, 'leaderboard_prize', null, jsonb_build_object('cents', v_amt, 'month', z.month_key, 'vibez', z.vibez, 'place', z.place));
    perform _log('lb_prize_paid', z.creator_id, jsonb_build_object('month', z.month_key, 'place', z.place, 'cents', v_amt, 'approved_cents', z.amount_cents));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed','leaderboard_prize','leaderboard_prize_held') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured','weekly_summary','download_request','download_ok','download_no','leaderboard_bonus') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result','battle_invite') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help','age_nudge','held','held_ok','scan_held','urgent_report','referral_reward','leaderboard_prize_review') then 'account'
    else null end;
$$;

revoke execute on function public._lb_scores(text, date), public.lb_release_prizes() from public, anon, authenticated;
revoke execute on function public._lb_close_week(date, date), public._lb_close_month(text) from public, anon, authenticated;
revoke execute on function public.lb_board(text, int), public.admin_lb_prizes(text), public.admin_lb_decide(uuid, boolean, text) from public;
grant execute on function public.lb_board(text, int) to anon, authenticated;
grant execute on function public.admin_lb_prizes(text), public.admin_lb_decide(uuid, boolean, text) to authenticated;

select cron.schedule('lb-release', '17 * * * *', 'select public.lb_release_prizes()');
