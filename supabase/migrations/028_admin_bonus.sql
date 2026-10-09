-- 028: pay creators a bonus instead of crediting wallets.
-- A wallet credit was money with nothing behind it that then produced a fake 15% "platform fee" when spent.
-- A bonus goes straight to a creator's withdrawable earnings, with no fee, and is recorded as its own line
-- (the platform pays it out of its own funds when the creator withdraws). Wallet credits are switched off.
-- NOTE: the enum value 'admin_bonus' must be added on its own first (alter type public.tx_type add value if not exists 'admin_bonus').

create or replace function public.admin_pay_bonus(p_user uuid, p_cents int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_cents is null or p_cents < 1 or p_cents > 10000 then raise exception 'A bonus must be between £0.01 and £100.00'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  if p_user = auth.uid() then raise exception 'You cannot pay a bonus to yourself'; end if;
  if not exists (select 1 from profiles where id = p_user and account_type = 'creator') then raise exception 'Bonuses can only be paid to creators'; end if;
  update profiles set earnings_cents = earnings_cents + p_cents where id = p_user;
  insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents) values (p_user, 'admin_bonus', p_cents, 0, p_cents);
  insert into notifications(user_id, actor_id, type, ref_id, data) values (p_user, null, 'bonus', null, jsonb_build_object('cents', p_cents));
  perform _log('pay_bonus', p_user, jsonb_build_object('cents', p_cents, 'reason', left(trim(p_reason), 300)));
end $$;
revoke execute on function public.admin_pay_bonus(uuid, int, text) from public, anon;
grant execute on function public.admin_pay_bonus(uuid, int, text) to authenticated;

create or replace function public.admin_credit_wallet(p_user uuid, p_cents int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Wallet credits are switched off. Use "Pay creator a bonus" instead.';
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
    'gross_cents', (select coalesce(sum(gross_cents),0) from transactions where type in ('post_unlock','subscription','tip')),
    'platform_fees_cents', (select coalesce(sum(fee_cents),0) from transactions where type in ('post_unlock','subscription','tip')),
    'raffle_revenue_cents', (select coalesce(sum(gross_cents),0) from transactions where type = 'raffle_entry'),
    'wallet_liability_cents', (select coalesce(sum(wallet_cents),0) from profiles),
    'creator_earnings_owed_cents', (select coalesce(sum(earnings_cents),0) from profiles),
    'pending_payouts_cents', (select coalesce(sum(amount_cents),0) from payouts where status = 'pending'),
    'pending_payouts', (select count(*) from payouts where status = 'pending'),
    'bonuses_paid_cents', (select coalesce(sum(gross_cents),0) from transactions where type = 'admin_bonus'),
    'wallet_credits_cents', (select coalesce(sum(gross_cents),0) from transactions where type = 'admin_credit'));
end $$;
