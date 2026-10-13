-- 046: help new members get going and keep them coming back.
--  * my_checklist(): the "Get started" steps (done / not done) for the signed-in member, worked out from real data
--  * suggested_creators(): who a new follower could follow
--  * nudge_unverified_creators(): a daily nudge (max 2, a week apart) for creators who have not started their 18+ check
--  * send_weekly_summaries(): a Monday round-up (notification + email) for creators and followers, only when there is something to say
--  * user_streaks / touch_streak(): consecutive days a member has opened the app (UK days). Cosmetic only, no money.
--  * admin_overview(): one-screen numbers for the admin console

-- ---------- get started checklist ----------
create or replace function public.my_checklist() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid(); p profiles%rowtype; steps jsonb; pend boolean;
begin
  if v is null then raise exception 'Not signed in'; end if;
  select * into p from profiles where id = v;
  if not found then return null; end if;
  pend := exists (select 1 from age_requests where user_id = v and status = 'pending');
  if p.account_type = 'creator' then
    steps := jsonb_build_array(
      jsonb_build_object('key', 'photo',  'done', p.avatar_url is not null),
      jsonb_build_object('key', 'bio',    'done', length(trim(coalesce(p.bio, ''))) >= 3),
      jsonb_build_object('key', 'age',    'done', p.age_verified, 'pending', pend),
      jsonb_build_object('key', 'post',   'done', exists (select 1 from posts where creator_id = v and deleted_at is null and removed_at is null)),
      jsonb_build_object('key', 'push',   'done', exists (select 1 from push_subscriptions where user_id = v)),
      jsonb_build_object('key', 'payout', 'done', coalesce((select payouts_enabled from payout_accounts where user_id = v), false)));
  else
    steps := jsonb_build_array(
      jsonb_build_object('key', 'photo',    'done', p.avatar_url is not null),
      jsonb_build_object('key', 'follow3',  'done', (select count(*) from follows where follower_id = v) >= 3),
      jsonb_build_object('key', 'giveaway', 'done', exists (select 1 from raffle_entries where user_id = v)),
      jsonb_build_object('key', 'push',     'done', exists (select 1 from push_subscriptions where user_id = v)));
  end if;
  return jsonb_build_object('role', p.account_type::text, 'steps', steps,
    'done', (select count(*) from jsonb_array_elements(steps) s where (s->>'done')::boolean), 'total', jsonb_array_length(steps));
end $$;

-- ---------- creators to follow ----------
create or replace function public.suggested_creators(p_limit int default 8)
returns table (id uuid, username text, display_name text, avatar_url text, follower_count int, category text)
language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'Not signed in'; end if;
  return query
    select p.id, p.username, p.display_name, p.avatar_url, p.follower_count, p.category
      from profiles p
     where p.account_type = 'creator' and not p.is_banned and p.id <> v
       and not exists (select 1 from follows f where f.follower_id = v and f.creator_id = p.id)
       and not exists (select 1 from blocks b where (b.blocker_id = v and b.blocked_id = p.id) or (b.blocker_id = p.id and b.blocked_id = v))
       and exists (select 1 from posts x where x.creator_id = p.id and x.removed_at is null and x.deleted_at is null)
     order by p.follower_count desc, p.created_at desc
     limit least(coalesce(p_limit, 8), 20);
end $$;

-- ---------- nudge creators who have not started the 18+ check ----------
create or replace function public.nudge_unverified_creators() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in
    select p.id, p.email_notifications from profiles p
     where p.account_type = 'creator' and not p.age_verified and not p.is_banned
       and p.created_at < now() - interval '1 day' and p.created_at > now() - interval '30 days'
       and not exists (select 1 from age_requests a where a.user_id = p.id and a.status = 'pending')
       and (select count(*) from notifications nn where nn.user_id = p.id and nn.type = 'age_nudge') < 2
       and not exists (select 1 from notifications nn where nn.user_id = p.id and nn.type = 'age_nudge' and nn.created_at > now() - interval '7 days')
  loop
    insert into notifications(user_id, type, data) values (r.id, 'age_nudge', '{}'::jsonb);
    if r.email_notifications then
      insert into email_queue(user_id, kind, subject, body) values (r.id, 'age_nudge', 'Finish your 18+ check to start posting',
        E'Your OverVibez creator account is ready, but you cannot post or go live until your 18+ check is done.\n\nIt only takes a couple of minutes. Open OverVibez, go to Profile and tap Identity & age verification.');
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- Monday round-up ----------
create or replace function public.send_weekly_summaries() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; nf int; earned bigint; np int; ng int; v_data jsonb; v_body text;
begin
  for r in
    select p.id, p.account_type, p.email_notifications from profiles p
     where not p.is_banned and p.created_at < now() - interval '2 days'
       and not exists (select 1 from notifications nn where nn.user_id = p.id and nn.type = 'weekly_summary' and nn.created_at > now() - interval '5 days')
  loop
    v_data := null;
    if r.account_type = 'creator' then
      select count(*) into nf from follows where creator_id = r.id and created_at > now() - interval '7 days';
      select coalesce(sum(net_cents), 0) into earned from transactions
       where payee_id = r.id and refunded_at is null and created_at > now() - interval '7 days'
         and type in ('subscription', 'post_unlock', 'tip', 'live_entry', 'vibe');
      if nf > 0 or earned > 0 then
        v_data := jsonb_build_object('role', 'creator', 'followers', nf, 'earned_cents', earned);
        v_body := 'Your week on OverVibez: ' || nf || ' new follower' || case when nf = 1 then '' else 's' end || ' and ' || _money(earned) || ' earned.' ||
                  E'\n\nPosting regularly is the best way to keep it growing. Open OverVibez to see what is working.';
      end if;
    else
      select count(*) into np from posts x join follows f on f.creator_id = x.creator_id and f.follower_id = r.id
       where x.created_at > now() - interval '7 days' and x.removed_at is null and x.deleted_at is null;
      select count(*) into ng from raffles where is_free and closes_at > now() and winner_entry_id is null;
      if np > 0 or ng > 0 then
        v_data := jsonb_build_object('role', 'follower', 'posts', np, 'giveaways', ng);
        v_body := 'This week on OverVibez: ' || np || ' new post' || case when np = 1 then '' else 's' end || ' from creators you follow' ||
                  case when ng > 0 then ' and ' || ng || ' free giveaway' || case when ng = 1 then '' else 's' end || ' you can still enter' else '' end || '.' ||
                  E'\n\nOpen OverVibez to catch up.';
      end if;
    end if;
    if v_data is not null then
      insert into notifications(user_id, type, data) values (r.id, 'weekly_summary', v_data);
      if r.email_notifications then insert into email_queue(user_id, kind, subject, body) values (r.id, 'weekly_summary', 'Your week on OverVibez', v_body); end if;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------- login streaks (cosmetic) ----------
create table if not exists public.user_streaks (
  user_id uuid primary key references auth.users(id) on delete cascade,
  current_days int not null default 0, best_days int not null default 0, last_day date);
alter table public.user_streaks enable row level security;
revoke all on public.user_streaks from anon, authenticated;

create or replace function public.touch_streak() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := auth.uid(); today date := (now() at time zone 'Europe/London')::date; s user_streaks%rowtype; changed boolean := false;
begin
  if v is null then raise exception 'Not signed in'; end if;
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

-- ---------- admin overview ----------
create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'users', (select count(*) from profiles),
    'new_24h', (select count(*) from profiles where created_at > now() - interval '1 day'),
    'new_7d', (select count(*) from profiles where created_at > now() - interval '7 days'),
    'new_30d', (select count(*) from profiles where created_at > now() - interval '30 days'),
    'creators', (select count(*) from profiles where account_type = 'creator'),
    'creators_unverified', (select count(*) from profiles where account_type = 'creator' and not age_verified and not is_banned),
    'creators_posting_7d', (select count(distinct creator_id) from posts where created_at > now() - interval '7 days' and deleted_at is null and removed_at is null),
    'open_reports', (select count(*) from reports where status::text = 'open'),
    'open_appeals', (select count(*) from appeals where status = 'open'),
    'overdue_appeals', (select count(*) from appeals where status = 'open' and created_at < now() - interval '48 hours'),
    'age_pending', (select count(*) from age_requests where status = 'pending'),
    'age_overdue', (select count(*) from age_requests where status = 'pending' and created_at < now() - interval '24 hours'),
    'feedback_open', (select count(*) from feedback where handled_at is null),
    'email_help_open', (select count(*) from email_help_requests r where r.handled_at is null and exists (select 1 from auth.users u where u.id = r.user_id and u.email_confirmed_at is null)),
    'payouts_pending', (select count(*) from payouts where status = 'pending'),
    'errors_24h', (select count(*) from client_errors where last_seen_at > now() - interval '1 day'),
    'live_now', (select count(*) from live_streams where status::text = 'live'),
    'sales_7d_cents', (select coalesce(sum(gross_cents), 0) from transactions where refunded_at is null and created_at > now() - interval '7 days' and type in ('subscription', 'post_unlock', 'tip', 'live_entry', 'vibe')),
    'fees_7d_cents', (select coalesce(sum(fee_cents), 0) from transactions where refunded_at is null and created_at > now() - interval '7 days' and type in ('subscription', 'post_unlock', 'tip', 'live_entry', 'vibe')),
    'topups_7d_cents', (select coalesce(sum(gross_cents), 0) from transactions where created_at > now() - interval '7 days' and type = 'wallet_topup'),
    'signups', (select coalesce(jsonb_agg(c order by d), '[]'::jsonb) from (
        select g::date d, (select count(*) from profiles where (created_at at time zone 'Europe/London')::date = g::date) c
          from generate_series((now() at time zone 'Europe/London')::date - 13, (now() at time zone 'Europe/London')::date, interval '1 day') g) x));
end $$;

-- ---------- push wording groups for the two new notification types ----------
create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured','weekly_summary') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help','age_nudge') then 'account'
    else null end;
$$;

revoke execute on function public.my_checklist(), public.suggested_creators(int), public.touch_streak(), public.admin_overview() from public, anon;
grant execute on function public.my_checklist(), public.suggested_creators(int), public.touch_streak(), public.admin_overview() to authenticated;
revoke execute on function public.nudge_unverified_creators(), public.send_weekly_summaries() from public, anon, authenticated;

select cron.schedule('nudge-unverified-creators', '30 10 * * *', 'select public.nudge_unverified_creators()');
select cron.schedule('weekly-summaries', '0 8 * * 1', 'select public.send_weekly_summaries()');
