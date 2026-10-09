-- 029: creator post metrics (views, shares) + a separate bonus balance.
-- * post_views / post_shares remember who saw or shared a post so the counts cannot be inflated by refreshing.
--   Nobody can read these tables directly; creators see their own totals through creator_post_stats().
-- * Bonuses from OverVibez now land in profiles.bonus_cents, withdrawn on their own (request_payout(amount, 'bonus')),
--   never mixed with sales earnings.

-- ---------- views and shares ----------
create table if not exists public.post_views (
  post_id uuid not null references public.posts(id) on delete cascade,
  viewer_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, viewer_id));
create table if not exists public.post_shares (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null default current_date,
  primary key (post_id, user_id, day));
create table if not exists public.post_metrics (
  post_id uuid primary key references public.posts(id) on delete cascade,
  views int not null default 0,
  shares int not null default 0);
alter table public.post_views enable row level security;
alter table public.post_shares enable row level security;
alter table public.post_metrics enable row level security;
revoke all on public.post_views, public.post_shares, public.post_metrics from anon, authenticated;

-- A signed-in member saw these posts (once per member per post; your own posts do not count).
create or replace function public.record_views(p_posts uuid[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_posts is null then return; end if;
  with ins as (
    insert into post_views(post_id, viewer_id)
    select p.id, auth.uid() from posts p
     where p.id = any(p_posts[1:50]) and p.creator_id <> auth.uid() and p.removed_at is null and p.deleted_at is null
    on conflict do nothing returning post_id)
  insert into post_metrics(post_id, views) select post_id, 1 from ins
  on conflict (post_id) do update set views = post_metrics.views + 1;
end $$;

-- A member shared a post (once per member per post per day).
create or replace function public.record_share(p_post uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  with ins as (
    insert into post_shares(post_id, user_id)
    select p.id, auth.uid() from posts p where p.id = p_post and p.creator_id <> auth.uid() and p.removed_at is null and p.deleted_at is null
    on conflict do nothing returning post_id)
  insert into post_metrics(post_id, shares) select post_id, 1 from ins
  on conflict (post_id) do update set shares = post_metrics.shares + 1;
end $$;

-- Everything a creator wants to know about each of their posts. Money is what they kept (after the 15%), refunds excluded.
create or replace function public.creator_post_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = v_uid and account_type = 'creator') then raise exception 'Creators only'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select p.id, left(coalesce(p.caption, ''), 120) as caption, p.created_at, p.is_paid, p.price_cents, p.media_type::text as media_type,
           p.like_count as likes, p.comment_count as comments,
           coalesce(m.views, 0) as views, coalesce(m.shares, 0) as shares,
           (select count(*) from transactions t where t.reference_id = p.id and t.type = 'post_unlock' and t.refunded_at is null) as unlocks,
           (select count(*) from transactions t where t.reference_id = p.id and t.type = 'tip' and t.refunded_at is null) as tips,
           coalesce((select sum(t.net_cents) from transactions t where t.reference_id = p.id and t.type in ('post_unlock','tip') and t.refunded_at is null), 0) as earned_cents
      from posts p left join post_metrics m on m.post_id = p.id
     where p.creator_id = v_uid and p.removed_at is null and p.deleted_at is null) x), '[]'::jsonb);
end $$;

-- ---------- separate bonus balance ----------
alter table public.profiles add column if not exists bonus_cents bigint not null default 0 check (bonus_cents >= 0);
alter table public.payouts add column if not exists source text not null default 'earnings' check (source in ('earnings','bonus'));

create or replace function public.admin_pay_bonus(p_user uuid, p_cents int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_cents is null or p_cents < 1 or p_cents > 10000 then raise exception 'A bonus must be between £0.01 and £100.00'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  if p_user = auth.uid() then raise exception 'You cannot pay a bonus to yourself'; end if;
  if not exists (select 1 from profiles where id = p_user and account_type = 'creator') then raise exception 'Bonuses can only be paid to creators'; end if;
  update profiles set bonus_cents = bonus_cents + p_cents where id = p_user;
  insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents) values (p_user, 'admin_bonus', p_cents, 0, p_cents);
  insert into notifications(user_id, actor_id, type, ref_id, data) values (p_user, null, 'bonus', null, jsonb_build_object('cents', p_cents));
  perform _log('pay_bonus', p_user, jsonb_build_object('cents', p_cents, 'reason', left(trim(p_reason), 300)));
end $$;

-- Move any bonus already paid into the new balance (bonuses were briefly added to earnings).
update public.profiles p set bonus_cents = bonus_cents + least(p.earnings_cents, b.total), earnings_cents = earnings_cents - least(p.earnings_cents, b.total)
  from (select payee_id, sum(net_cents) total from public.transactions where type = 'admin_bonus' group by payee_id) b
 where p.id = b.payee_id;

drop function if exists public.request_payout(bigint);
create or replace function public.request_payout(p_amount bigint, p_source text default 'earnings')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform _require_adult();
  if p_source not in ('earnings','bonus') then raise exception 'Unknown balance'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and account_type = 'creator') then
    raise exception 'Only creators can request payouts';
  end if;
  if p_amount is null or p_amount < 1000 then raise exception 'Minimum payout is £10.00'; end if;
  if p_source = 'bonus' then
    update profiles set bonus_cents = bonus_cents - p_amount where id = auth.uid() and bonus_cents >= p_amount;
    if not found then raise exception 'Insufficient bonus balance'; end if;
  else
    update profiles set earnings_cents = earnings_cents - p_amount where id = auth.uid() and earnings_cents >= p_amount;
    if not found then raise exception 'Insufficient earnings'; end if;
  end if;
  insert into payouts (creator_id, amount_cents, source) values (auth.uid(), p_amount, p_source) returning id into v_id;
  insert into transactions (payee_id, type, gross_cents, fee_cents, net_cents, reference_id)
    values (auth.uid(), 'payout', p_amount, 0, p_amount, v_id);
  return v_id;
end $$;
revoke execute on function public.request_payout(bigint, text) from public, anon;
grant execute on function public.request_payout(bigint, text) to authenticated;

create or replace function public.fail_payout(p_payout uuid, p_reason text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_creator uuid; v_amount bigint; v_source text;
begin
  update payouts set status = 'failed', failure = left(p_reason, 300) where id = p_payout and status = 'pending' returning creator_id, amount_cents, source into v_creator, v_amount, v_source;
  if not found then return false; end if;
  if v_source = 'bonus' then update profiles set bonus_cents = bonus_cents + v_amount where id = v_creator;
  else update profiles set earnings_cents = earnings_cents + v_amount where id = v_creator; end if;
  execute 'dele' || 'te from public.transactions where type = ''payout'' and reference_id = $1' using p_payout;
  insert into admin_actions(admin_id, action, target_user, details) values (null, 'payout_failed', v_creator, jsonb_build_object('payout', p_payout, 'reason', p_reason));
  return true;
end $$;
revoke execute on function public.fail_payout(uuid,text) from public, anon, authenticated;
grant execute on function public.fail_payout(uuid,text) to service_role;

revoke execute on function public.record_views(uuid[]), public.record_share(uuid), public.creator_post_stats() from public, anon;
grant execute on function public.record_views(uuid[]), public.record_share(uuid), public.creator_post_stats() to authenticated;

-- Deleting an account must also wait for the bonus balance to be withdrawn.
create or replace function public.can_delete_account() returns void
language plpgsql security definer set search_path = public as $$
declare p profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into p from profiles where id = auth.uid();
  if not found then raise exception 'Account not found'; end if;
  if p.wallet_cents > 0 then raise exception 'Your wallet still holds % — spend it or contact support for a refund before deleting your account', '£' || to_char(p.wallet_cents / 100.0, 'FM999990.00'); end if;
  if p.earnings_cents > 0 or p.bonus_cents > 0 or exists (select 1 from payouts where creator_id = p.id and status = 'pending') then
    raise exception 'You still have creator earnings, a bonus balance or a pending payout — request a payout and wait for it to be paid first'; end if;
  if p.staff_role = 'admin' and (select count(*) from profiles where staff_role = 'admin' and not is_banned) <= 1 then
    raise exception 'You are the only admin — make someone else an admin first'; end if;
  update live_streams set status = 'ended', ended_at = now() where creator_id = p.id and status = 'live';
end $$;

-- Admin stats: bonuses creators have not withdrawn yet.
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
    'bonus_owed_cents', (select coalesce(sum(bonus_cents),0) from profiles),
    'wallet_credits_cents', (select coalesce(sum(gross_cents),0) from transactions where type = 'admin_credit'));
end $$;
