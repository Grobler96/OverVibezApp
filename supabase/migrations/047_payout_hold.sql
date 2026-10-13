-- 047: payout hold. Money earned from sales can only be withdrawn once it is 14 days old, so card payments have time to land in
-- our Stripe balance (and refunds or chargebacks can still be taken back) before it is sent on. Bonuses paid by OverVibez are not held.
-- The number of days lives in app_settings ('payout_hold_days') and can be changed by an admin with admin_set_payout_hold().
-- Held amount = what the member earned from sales in the last N days, taken from the transactions table (refunded sales do not count).
insert into public.app_settings(key, value) values ('payout_hold_days', '14'::jsonb) on conflict (key) do nothing;

create or replace function public._hold_days() returns int language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::int from app_settings where key = 'payout_hold_days'), 14) $$;

create or replace function public._held_earnings(p_user uuid) returns bigint language sql stable security definer set search_path = public as $$
  select coalesce(sum(net_cents), 0)::bigint from transactions
   where payee_id = p_user and refunded_at is null and created_at > now() - make_interval(days => _hold_days())
     and type in ('subscription', 'post_unlock', 'tip', 'live_entry', 'vibe') $$;

create or replace function public.my_payout_balance() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid(); e bigint; b bigint; h bigint; d int := _hold_days(); rel timestamptz;
begin
  if v is null then raise exception 'Not signed in'; end if;
  select earnings_cents, bonus_cents into e, b from profiles where id = v;
  h := least(coalesce(e, 0), _held_earnings(v));
  select min(created_at) + make_interval(days => d) into rel from transactions
   where payee_id = v and refunded_at is null and created_at > now() - make_interval(days => d) and type in ('subscription', 'post_unlock', 'tip', 'live_entry', 'vibe');
  return jsonb_build_object('earnings_cents', coalesce(e, 0), 'held_cents', h, 'available_cents', greatest(0, coalesce(e, 0) - h),
                            'hold_days', d, 'release_at', case when h > 0 then rel end, 'bonus_cents', coalesce(b, 0));
end $$;

create or replace function public.request_payout(p_amount bigint) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_earn bigint; v_avail bigint;
begin
  perform _require_adult();
  if not exists (select 1 from profiles where id = auth.uid() and account_type = 'creator') then
    raise exception 'Only creators can request payouts';
  end if;
  if p_amount is null or p_amount < 1000 then raise exception 'Minimum payout is £10.00'; end if;
  select earnings_cents into v_earn from profiles where id = auth.uid() for update;
  v_avail := greatest(0, coalesce(v_earn, 0) - _held_earnings(auth.uid()));
  if p_amount > v_avail then
    raise exception 'Only % is ready to withdraw. Earnings from the last % days are held so payments have time to land.', _money(v_avail), _hold_days();
  end if;
  update profiles set earnings_cents = earnings_cents - p_amount where id = auth.uid() and earnings_cents >= p_amount;
  if not found then raise exception 'Insufficient earnings'; end if;
  insert into payouts (creator_id, amount_cents) values (auth.uid(), p_amount) returning id into v_id;
  insert into transactions (payee_id, type, gross_cents, fee_cents, net_cents, reference_id) values (auth.uid(), 'payout', p_amount, 0, p_amount, v_id);
  return v_id;
end $$;

create or replace function public.admin_set_payout_hold(p_days int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_days is null or p_days < 0 or p_days > 60 then raise exception 'Choose between 0 and 60 days'; end if;
  insert into app_settings(key, value) values ('payout_hold_days', to_jsonb(p_days)) on conflict (key) do update set value = excluded.value;
  perform _log('set_payout_hold', null, jsonb_build_object('days', p_days));
end $$;

revoke execute on function public._hold_days(), public._held_earnings(uuid) from public, anon, authenticated;
revoke execute on function public.my_payout_balance(), public.admin_set_payout_hold(int) from public, anon;
grant execute on function public.my_payout_balance(), public.admin_set_payout_hold(int) to authenticated;
