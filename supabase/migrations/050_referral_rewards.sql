-- 050: opt-in referral rewards.
-- A creator chooses to join (accepting short rules) and gets a personal link. Someone who signs up through it becomes a "qualified follower"
-- only once they are real and settled in: email confirmed, 18+ check passed, account at least 14 days old, active on at least 3 different
-- days, and still following the creator. Every 1,000 qualified followers earns the creator a £10 reward. Rewards are NOT paid automatically:
-- each one waits as "pending" until an admin has looked at the accounts and approves it, and then it is paid into the creator's bonus balance.
-- Admins can reject a reward or remove a creator from the programme. All numbers below are settings in app_settings with safe defaults:
--   referral_unit (1000), referral_reward_cents (1000), referral_min_age_days (14), referral_min_active_days (3), referral_require_age (true), referral_daily_cap (300)

create or replace function public._ref_int(p_key text, p_default int) returns int language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::int from app_settings where key = p_key), p_default) $$;
create or replace function public._ref_require_age() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::boolean from app_settings where key = 'referral_require_age'), true) $$;

create table if not exists public.referral_members (
  creator_id uuid primary key references public.profiles(id) on delete cascade,
  code text not null unique,
  joined_at timestamptz not null default now(),
  terms_version int not null default 1,
  active boolean not null default true,
  removed_reason text);
create table if not exists public.referrals (
  referred_id uuid primary key references auth.users(id) on delete cascade,
  creator_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  voided_at timestamptz, void_reason text);
create index if not exists referrals_creator on public.referrals (creator_id, created_at desc);
create table if not exists public.referral_rewards (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  milestone int not null,
  amount_cents int not null,
  qualified_count int not null,
  status text not null default 'pending' check (status in ('pending', 'paid', 'rejected')),
  note text,
  created_at timestamptz not null default now(),
  decided_at timestamptz, decided_by uuid,
  unique (creator_id, milestone));
create table if not exists public.user_active_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  primary key (user_id, day));
alter table public.referral_members enable row level security;
alter table public.referrals enable row level security;
alter table public.referral_rewards enable row level security;
alter table public.user_active_days enable row level security;
revoke all on public.referral_members, public.referrals, public.referral_rewards, public.user_active_days from anon, authenticated;

-- opening the app now also records the day (for "active on at least 3 different days")
create or replace function public.touch_streak() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := auth.uid(); today date := (now() at time zone 'Europe/London')::date; s user_streaks%rowtype; changed boolean := false;
begin
  if v is null then raise exception 'Not signed in'; end if;
  insert into user_active_days(user_id, day) values (v, today) on conflict do nothing;
  insert into user_streaks(user_id, current_days, best_days, last_day) values (v, 0, 0, null) on conflict do nothing;
  select * into s from user_streaks where user_id = v for update;
  if s.last_day is distinct from today then
    s.current_days := case when s.last_day = today - 1 then s.current_days + 1 else 1 end;
    s.best_days := greatest(s.best_days, s.current_days); s.last_day := today; changed := true;
    update user_streaks set current_days = s.current_days, best_days = s.best_days, last_day = s.last_day where user_id = v;
  end if;
  return jsonb_build_object('current', s.current_days, 'best', s.best_days,
    'milestone', case when changed and s.current_days in (3, 7, 14, 30, 60, 100) then s.current_days end);
end $$;

-- how many of a creator's referred people count right now
create or replace function public._referral_qualified_count(p_creator uuid) returns int
language sql stable security definer set search_path = public, auth as $$
  select count(*)::int from referrals r
    join profiles p on p.id = r.referred_id
    join auth.users u on u.id = r.referred_id
   where r.creator_id = p_creator and r.voided_at is null
     and not p.is_banned
     and p.created_at <= now() - make_interval(days => _ref_int('referral_min_age_days', 14))
     and u.email_confirmed_at is not null
     and (not _ref_require_age() or p.age_verified)
     and exists (select 1 from follows f where f.follower_id = r.referred_id and f.creator_id = p_creator)
     and (select count(*) from user_active_days d where d.user_id = r.referred_id) >= _ref_int('referral_min_active_days', 3) $$;

-- joining is a deliberate choice
create or replace function public.join_referral_program(p_accept boolean) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m referral_members%rowtype; v_code text; v_try int := 0;
begin
  perform _require_adult();
  if p_accept is not true then raise exception 'Please accept the rules to join'; end if;
  if not exists (select 1 from profiles where id = v_uid and account_type = 'creator' and not is_banned) then raise exception 'Only creators can join'; end if;
  select * into m from referral_members where creator_id = v_uid;
  if found then
    if m.removed_reason is not null then raise exception 'You cannot rejoin the referral programme'; end if;
    update referral_members set active = true where creator_id = v_uid;
    return m.code;
  end if;
  loop
    v_code := lower(substr(md5(random()::text || clock_timestamp()::text || v_uid::text), 1, 8));
    begin
      insert into referral_members(creator_id, code) values (v_uid, v_code); exit;
    exception when unique_violation then v_try := v_try + 1; if v_try > 4 then raise; end if;
    end;
  end loop;
  perform _log('join_referrals', v_uid, '{}'::jsonb);
  return v_code;
end $$;

create or replace function public.leave_referral_program() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update referral_members set active = false where creator_id = auth.uid();
end $$;

create or replace function public.my_referral() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid(); m referral_members%rowtype; q int; t int; u int := _ref_int('referral_unit', 1000);
begin
  if v is null then raise exception 'Not signed in'; end if;
  select * into m from referral_members where creator_id = v;
  if not found or m.removed_reason is not null then
    return jsonb_build_object('member', false, 'removed', found and m.removed_reason is not null, 'unit', u, 'reward_cents', _ref_int('referral_reward_cents', 1000),
      'min_age_days', _ref_int('referral_min_age_days', 14), 'min_active_days', _ref_int('referral_min_active_days', 3), 'require_age', _ref_require_age());
  end if;
  q := _referral_qualified_count(v); select count(*) into t from referrals where creator_id = v and voided_at is null;
  return jsonb_build_object('member', true, 'active', m.active, 'code', m.code, 'signed_up', t, 'qualified', q, 'unit', u,
    'next_at', (q / u + 1) * u, 'reward_cents', _ref_int('referral_reward_cents', 1000),
    'min_age_days', _ref_int('referral_min_age_days', 14), 'min_active_days', _ref_int('referral_min_active_days', 3), 'require_age', _ref_require_age(),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('milestone', milestone, 'amount_cents', amount_cents, 'status', status, 'created_at', created_at) order by milestone desc)
                           from referral_rewards where creator_id = v), '[]'::jsonb));
end $$;

-- shown on the sign-up screen: who invited you (only the username, only for a live code)
create or replace function public.referral_info(p_code text) returns text
language sql stable security definer set search_path = public as $$
  select p.username from referral_members m join profiles p on p.id = m.creator_id
   where m.code = lower(trim(coalesce(p_code, ''))) and m.active and not p.is_banned $$;

-- called once after a new member logs in with a referral link. Returns the creator's id, or null if it does not count.
create or replace function public.claim_referral(p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid := auth.uid(); m referral_members%rowtype; me_created timestamptz;
begin
  if v is null then raise exception 'Not signed in'; end if;
  select created_at into me_created from profiles where id = v;
  if me_created is null or me_created < now() - interval '3 days' then return null; end if;                  -- only brand new accounts
  if exists (select 1 from referrals where referred_id = v) then return null; end if;
  select * into m from referral_members where code = lower(trim(coalesce(p_code, ''))) and active;
  if not found or m.creator_id = v then return null; end if;
  if me_created < m.joined_at then return null; end if;                                                      -- must have signed up after the creator joined
  if not exists (select 1 from profiles where id = m.creator_id and not is_banned) then return null; end if;
  if (select count(*) from referrals where creator_id = m.creator_id and created_at > now() - interval '1 day') >= _ref_int('referral_daily_cap', 300) then return null; end if;
  insert into referrals(referred_id, creator_id) values (v, m.creator_id);
  return m.creator_id;
end $$;

-- daily: create a pending reward each time a creator passes another 1,000 qualified followers, and tell the admins
create or replace function public.referral_sweep() returns int
language plpgsql security definer set search_path = public as $$
declare r record; q int; k int; n int := 0; u int := _ref_int('referral_unit', 1000);
begin
  for r in select m.creator_id, p.username from referral_members m join profiles p on p.id = m.creator_id where m.active and not p.is_banned and p.age_verified loop
    q := _referral_qualified_count(r.creator_id);
    for k in 1 .. (q / u) loop
      if not exists (select 1 from referral_rewards where creator_id = r.creator_id and milestone = k) then
        insert into referral_rewards(creator_id, milestone, amount_cents, qualified_count) values (r.creator_id, k, _ref_int('referral_reward_cents', 1000), q) on conflict do nothing;
        insert into notifications(user_id, actor_id, type, ref_id, data)
          select a.id, null, 'referral_reward', r.creator_id, jsonb_build_object('username', r.username, 'milestone', k * u)
            from profiles a where a.staff_role = 'admin' and not a.is_banned;
        n := n + 1;
      end if;
    end loop;
  end loop;
  return n;
end $$;

-- admin: rewards waiting (or decided), with the evidence needed to judge them
create or replace function public.admin_list_referral_rewards(p_status text default 'pending')
returns table (id uuid, creator_id uuid, username text, milestone int, amount_cents int, qualified_count int, status text, created_at timestamptz, note text,
               signed_up bigint, signed_up_7d bigint, busiest_day bigint, verified_share int, creator_age_days int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query
    select w.id, w.creator_id, p.username, w.milestone, w.amount_cents, w.qualified_count, w.status, w.created_at, w.note,
           (select count(*) from referrals r where r.creator_id = w.creator_id and r.voided_at is null),
           (select count(*) from referrals r where r.creator_id = w.creator_id and r.voided_at is null and r.created_at > now() - interval '7 days'),
           coalesce((select max(c) from (select count(*) c from referrals r where r.creator_id = w.creator_id group by r.created_at::date) x), 0),
           coalesce((select round(100.0 * count(*) filter (where pp.age_verified) / nullif(count(*), 0))::int from referrals r join profiles pp on pp.id = r.referred_id where r.creator_id = w.creator_id and r.voided_at is null), 0),
           extract(day from now() - p.created_at)::int
      from referral_rewards w join profiles p on p.id = w.creator_id
     where (p_status = 'all' or w.status = p_status) order by w.created_at desc limit 100;
end $$;

create or replace function public.admin_decide_referral_reward(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare w referral_rewards%rowtype;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select * into w from referral_rewards where id = p_id for update;
  if not found or w.status <> 'pending' then raise exception 'This reward is not waiting for a decision'; end if;
  if p_approve then
    if not exists (select 1 from referral_members where creator_id = w.creator_id and active) then raise exception 'This creator has left or been removed from the programme'; end if;
    perform admin_pay_bonus(w.creator_id, w.amount_cents, 'Referral reward for ' || (w.milestone * _ref_int('referral_unit', 1000)) || ' qualified followers');
    update referral_rewards set status = 'paid', decided_at = now(), decided_by = auth.uid(), note = left(p_note, 300) where id = p_id;
  else
    if p_note is null or length(trim(p_note)) < 3 then raise exception 'A reason is required'; end if;
    update referral_rewards set status = 'rejected', decided_at = now(), decided_by = auth.uid(), note = left(trim(p_note), 300) where id = p_id;
    perform _log('referral_reward_rejected', w.creator_id, jsonb_build_object('reward', p_id, 'reason', left(trim(p_note), 300)));
  end if;
end $$;

create or replace function public.admin_referral_members()
returns table (creator_id uuid, username text, active boolean, removed_reason text, joined_at timestamptz, signed_up bigint, qualified int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select m.creator_id, p.username, m.active, m.removed_reason, m.joined_at,
                      (select count(*) from referrals r where r.creator_id = m.creator_id and r.voided_at is null), _referral_qualified_count(m.creator_id)
                 from referral_members m join profiles p on p.id = m.creator_id order by m.joined_at desc limit 200;
end $$;

create or replace function public.admin_remove_from_referrals(p_creator uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  update referral_members set active = false, removed_reason = left(trim(p_reason), 300) where creator_id = p_creator;
  if not found then raise exception 'Not a member'; end if;
  update referral_rewards set status = 'rejected', decided_at = now(), decided_by = auth.uid(), note = 'Removed from the programme' where creator_id = p_creator and status = 'pending';
  perform _log('referral_removed', p_creator, jsonb_build_object('reason', left(trim(p_reason), 300)));
end $$;

-- push wording group: the admin alert is an account notice
create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured','weekly_summary') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help','age_nudge','held','held_ok','scan_held','urgent_report','referral_reward') then 'account'
    else null end;
$$;

revoke execute on function public._ref_int(text, int), public._ref_require_age(), public._referral_qualified_count(uuid), public.referral_sweep() from public, anon, authenticated;
revoke execute on function public.join_referral_program(boolean), public.leave_referral_program(), public.my_referral(), public.claim_referral(text),
  public.admin_list_referral_rewards(text), public.admin_decide_referral_reward(uuid, boolean, text), public.admin_referral_members(), public.admin_remove_from_referrals(uuid, text) from public, anon;
grant execute on function public.join_referral_program(boolean), public.leave_referral_program(), public.my_referral(), public.claim_referral(text),
  public.admin_list_referral_rewards(text), public.admin_decide_referral_reward(uuid, boolean, text), public.admin_referral_members(), public.admin_remove_from_referrals(uuid, text) to authenticated;
revoke execute on function public.referral_info(text) from public;
grant execute on function public.referral_info(text) to anon, authenticated;

select cron.schedule('referral-sweep', '15 9 * * *', 'select public.referral_sweep()');
