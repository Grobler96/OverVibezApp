-- 030: stronger subscriptions.
--  * Post access: free | pay-per-view (optionally NOT included in the subscription) | subscribers only (cannot be bought one by one).
--  * Auto-renewal: a subscription renews every 30 days from the wallet until the member cancels, with a reminder 3 days before,
--    a "renewed" note, a "wallet too low" note (retried hourly) and an "ended" note. Cancelling turns renewal off; access lasts to the end of the paid period.
--  * Subscribers pay half price for live tickets.

-- ---------- posts ----------
alter table public.posts add column if not exists subs_only boolean not null default false;
alter table public.posts add column if not exists sub_included boolean not null default true;   -- paid posts: does a subscription also unlock it?
alter table public.posts drop constraint if exists posts_check;
alter table public.posts add constraint posts_check check ((not is_paid) or price_cents is not null or subs_only);
alter table public.posts add constraint posts_subs_only_check check ((not subs_only) or (is_paid and price_cents is null));
grant insert (subs_only, sub_included) on public.posts to authenticated;

create or replace function public._is_subscriber(p_creator uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from subscriptions s where s.creator_id = p_creator and s.subscriber_id = p_user
                   and s.status in ('active','canceled') and s.current_period_end > now());
$$;
revoke execute on function public._is_subscriber(uuid, uuid) from public, anon, authenticated;

create or replace function public.can_view_post(p_post_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from posts p
    where p.id = p_post_id
      and (
        p.is_paid = false
        or p.creator_id = auth.uid()
        or exists (select 1 from post_unlocks u where u.post_id = p.id and u.user_id = auth.uid())
        or ((p.subs_only or p.sub_included) and exists (select 1 from subscriptions s where s.creator_id = p.creator_id
                     and s.subscriber_id = auth.uid() and s.status in ('active','canceled')
                     and s.current_period_end > now()))
      )
  );
$$;

create or replace function public.purchase_post(p_post_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_price int; v_creator uuid; v_subs_only boolean;
begin
  perform _require_adult();
  select price_cents, creator_id, subs_only into v_price, v_creator, v_subs_only from posts where id = p_post_id and is_paid;
  if v_subs_only then raise exception 'This post is for subscribers only — subscribe to the creator to see it'; end if;
  if v_price is null then raise exception 'Post not found or not paid'; end if;
  if v_creator = auth.uid() then raise exception 'Cannot buy your own post'; end if;
  if exists (select 1 from post_unlocks where post_id = p_post_id and user_id = auth.uid()) then
    raise exception 'Already unlocked';
  end if;
  perform _settle(v_creator, v_price, 'post_unlock', p_post_id);
  insert into post_unlocks (post_id, user_id, amount_cents) values (p_post_id, auth.uid(), v_price);
end $$;

-- ---------- subscriptions: auto-renew ----------
alter table public.subscriptions add column if not exists auto_renew boolean not null default false;
alter table public.subscriptions add column if not exists renew_failed_at timestamptz;
alter table public.subscriptions add column if not exists renew_reminded_for timestamptz;

create or replace function public.subscribe_to_creator(p_creator uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_price int;
begin
  perform _require_adult();
  select sub_price_cents into v_price from profiles where id = p_creator and account_type = 'creator';
  if v_price is null then raise exception 'Creator has no subscription price set'; end if;
  if p_creator = auth.uid() then raise exception 'Cannot subscribe to yourself'; end if;
  perform _settle(p_creator, v_price, 'subscription', p_creator);
  insert into subscriptions (subscriber_id, creator_id, price_cents, current_period_end, auto_renew)
    values (auth.uid(), p_creator, v_price, now() + interval '30 days', true)
    on conflict (subscriber_id, creator_id) do update
      set status = 'active', price_cents = v_price, auto_renew = true, renew_failed_at = null,
          current_period_end = greatest(subscriptions.current_period_end, now()) + interval '30 days';
end $$;

create or replace function public.cancel_subscription(p_creator uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update subscriptions set status = 'canceled', auto_renew = false
    where subscriber_id = auth.uid() and creator_id = p_creator and status = 'active' and current_period_end > now();
  if not found then raise exception 'No active subscription to cancel'; end if;
end $$;

-- Turn renewal back on before the paid period ends (no charge now; it renews on the end date).
create or replace function public.resume_subscription(p_creator uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update subscriptions set status = 'active', auto_renew = true, renew_failed_at = null
    where subscriber_id = auth.uid() and creator_id = p_creator and status = 'canceled' and current_period_end > now();
  if not found then raise exception 'There is no subscription to resume'; end if;
end $$;
revoke execute on function public.resume_subscription(uuid) from public, anon;
grant execute on function public.resume_subscription(uuid) to authenticated;

-- Runs every hour (pg_cron). Reminds, renews, and gives up after 3 days of the wallet being too low.
create or replace function public.renew_subscriptions() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s record; v_rem int := 0; v_ok int := 0; v_fail int := 0; v_end int := 0; v_name text;
begin
  -- 1) reminder, 3 days before the renewal date
  for s in select sub.id, sub.subscriber_id, sub.creator_id, sub.price_cents, sub.current_period_end, p.username
             from subscriptions sub join profiles p on p.id = sub.creator_id
            where sub.status = 'active' and sub.auto_renew and sub.current_period_end > now() + interval '1 hour' and sub.current_period_end <= now() + interval '3 days'
              and sub.renew_reminded_for is distinct from sub.current_period_end loop
    perform _notify(s.subscriber_id, s.creator_id, 'sub_renew_soon', null, jsonb_build_object('creator', s.username, 'cents', s.price_cents, 'on', s.current_period_end));
    update subscriptions set renew_reminded_for = s.current_period_end where id = s.id;
    v_rem := v_rem + 1;
  end loop;

  -- 2) renew what is due within the hour (or up to 3 days overdue if the wallet was short)
  for s in select sub.id, sub.subscriber_id, sub.creator_id, sub.price_cents, sub.current_period_end, sub.renew_failed_at, p.username
             from subscriptions sub join profiles p on p.id = sub.creator_id
            where sub.status = 'active' and sub.auto_renew and sub.current_period_end <= now() + interval '1 hour'
              and sub.current_period_end > now() - interval '3 days'
            for update of sub skip locked loop
    begin
      if exists (select 1 from profiles where id = s.subscriber_id and (is_banned or not age_verified))
         or not exists (select 1 from profiles where id = s.creator_id and account_type = 'creator' and not is_banned) then
        update subscriptions set auto_renew = false where id = s.id;
        perform _notify(s.subscriber_id, s.creator_id, 'sub_ended', null, jsonb_build_object('creator', s.username));
        v_end := v_end + 1;
      else
        perform set_config('request.jwt.claim.sub', s.subscriber_id::text, true);   -- _settle() charges auth.uid(), so act as the subscriber
        perform _settle(s.creator_id, s.price_cents, 'subscription', s.creator_id);
        update subscriptions set current_period_end = greatest(current_period_end, now()) + interval '30 days', renew_failed_at = null where id = s.id;
        perform _notify(s.subscriber_id, s.creator_id, 'sub_renewed', null, jsonb_build_object('creator', s.username, 'cents', s.price_cents));
        v_ok := v_ok + 1;
      end if;
    exception when others then
      update subscriptions set renew_failed_at = coalesce(renew_failed_at, now()) where id = s.id;
      if s.renew_failed_at is null then
        perform _notify(s.subscriber_id, s.creator_id, 'sub_renew_failed', null, jsonb_build_object('creator', s.username, 'cents', s.price_cents));
      end if;
      v_fail := v_fail + 1;
    end;
  end loop;
  perform set_config('request.jwt.claim.sub', '', true);

  -- 3) still unpaid 3 days after it ran out: stop trying
  for s in select sub.id, sub.subscriber_id, sub.creator_id, p.username from subscriptions sub join profiles p on p.id = sub.creator_id
            where sub.status = 'active' and sub.auto_renew and sub.current_period_end <= now() - interval '3 days' loop
    update subscriptions set auto_renew = false, status = 'canceled' where id = s.id;
    perform _notify(s.subscriber_id, s.creator_id, 'sub_ended', null, jsonb_build_object('creator', s.username));
    v_end := v_end + 1;
  end loop;
  return jsonb_build_object('reminded', v_rem, 'renewed', v_ok, 'failed', v_fail, 'ended', v_end);
end $$;
revoke execute on function public.renew_subscriptions() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from cron.job where jobname = 'renew-subscriptions') then
    perform cron.schedule('renew-subscriptions', '7 * * * *', 'select public.renew_subscriptions()');
  end if;
end $$;

-- ---------- subscribers get half-price live tickets ----------
create or replace function public.buy_live_ticket(p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype; v_price int;
begin
  perform _require_adult();
  select * into s from live_streams where id = p_stream and status = 'live';
  if not found then raise exception 'This stream is not live'; end if;
  if s.creator_id = auth.uid() then raise exception 'You cannot buy a ticket to your own stream'; end if;
  if s.entry_price_cents = 0 then raise exception 'This stream is free'; end if;
  if exists (select 1 from live_tickets where stream_id = p_stream and user_id = auth.uid()) then raise exception 'You already have a ticket'; end if;
  v_price := case when _is_subscriber(s.creator_id, auth.uid()) then (s.entry_price_cents + 1) / 2 else s.entry_price_cents end;   -- subscribers pay half (rounded up)
  perform _settle(s.creator_id, v_price, 'live_entry', p_stream);
  insert into live_tickets(stream_id, user_id, amount_cents) values (p_stream, auth.uid(), v_price);
end $$;

-- ---------- emails for the new notifications ----------
create or replace function public._enqueue_email() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_subject text; v_body text; d jsonb := coalesce(new.data, '{}'::jsonb);
begin
  v_subject := case new.type
    when 'won' then 'You won ' || coalesce(d->>'prize', 'a prize') || '!'
    when 'prize_shipped' then 'Your prize is on its way'
    when 'refunded' then case when d->>'role' = 'payee' then 'A sale was refunded' else 'You have been refunded ' || _money((d->>'cents')::bigint) end
    when 'topup_reversed' then 'A top-up was reversed'
    when 'appeal_result' then case when d->>'action' = 'overturn' then 'Your appeal was accepted' else 'Your appeal has been reviewed' end
    when 'removed' then 'Something you posted was removed'
    when 'payout_paid' then 'Your payout of ' || _money((d->>'amount_cents')::bigint) || ' has been sent'
    when 'sub_renew_soon' then 'Your subscription to ' || coalesce(d->>'creator', 'a creator') || ' renews soon'
    when 'sub_renewed' then 'Your subscription to ' || coalesce(d->>'creator', 'a creator') || ' was renewed'
    when 'sub_renew_failed' then 'We could not renew your subscription to ' || coalesce(d->>'creator', 'a creator')
    when 'sub_ended' then 'Your subscription to ' || coalesce(d->>'creator', 'a creator') || ' has ended'
  end;
  if v_subject is null then return null; end if;
  if not exists (select 1 from profiles where id = new.user_id and email_notifications and not is_banned) then return null; end if;
  if (select count(*) from email_queue where status = 'queued') >= 5000 then return null; end if;
  v_body := case new.type
    when 'won' then 'Congratulations! You won ' || coalesce(d->>'prize', 'a prize') || ' in "' || coalesce(d->>'title', 'a giveaway') || '".' ||
      case when (d->>'free')::boolean then E'\n\nOpen OverVibez, go to Raffles and add your UK delivery address within 14 days so we can send it.' else '' end
    when 'prize_shipped' then 'Good news — your prize has been posted.' || case when coalesce(d->>'tracking', '') <> '' then E'\nTracking: ' || (d->>'tracking') else '' end
    when 'refunded' then case when d->>'role' = 'payee' then _money((d->>'cents')::bigint) || ' was taken from your earnings because a sale was refunded.' else _money((d->>'cents')::bigint) || ' has been returned to your OverVibez wallet.' end ||
      case when coalesce(d->>'reason', '') <> '' then E'\nReason: ' || (d->>'reason') else '' end
    when 'topup_reversed' then 'A top-up of ' || _money((d->>'cents')::bigint) || ' was reversed (' || coalesce(d->>'reason', 'refund') || ').' ||
      case when coalesce((d->>'owed')::bigint, 0) > 0 then E'\nYou now owe ' || _money((d->>'owed')::bigint) || ', which will be taken from your next top-up.' else '' end
    when 'appeal_result' then 'We have looked at your appeal and ' || case when d->>'action' = 'overturn' then 'accepted it — the decision has been put right.' else 'the original decision stands.' end ||
      case when coalesce(d->>'note', '') <> '' then E'\n\nOur reply: ' || (d->>'note') else '' end
    when 'removed' then 'A moderator removed your ' || coalesce(d->>'kind', 'content') || '.' || case when coalesce(d->>'reason', '') <> '' then E'\nReason: ' || (d->>'reason') else '' end ||
      E'\n\nIf you think this was a mistake you can appeal from the notification in the app.'
    when 'payout_paid' then 'We have sent ' || _money((d->>'amount_cents')::bigint) || ' to your payout account. It usually reaches your bank in 1–3 working days.'
    when 'sub_renew_soon' then 'Your subscription to ' || coalesce(d->>'creator', 'a creator') || ' renews on ' || to_char((d->>'on')::timestamptz at time zone 'Europe/London', 'FMDD Mon YYYY') || ' for ' || _money((d->>'cents')::bigint) || ', taken from your OverVibez wallet.' ||
      E'\n\nMake sure your wallet has enough. To stop it renewing, open the creator''s page in OverVibez and cancel — you keep access until the date above.'
    when 'sub_renewed' then _money((d->>'cents')::bigint) || ' was taken from your wallet to renew your subscription to ' || coalesce(d->>'creator', 'a creator') || ' for another 30 days.'
    when 'sub_renew_failed' then 'Your wallet did not have enough to renew your subscription to ' || coalesce(d->>'creator', 'a creator') || ' (' || _money((d->>'cents')::bigint) || '). Add funds in OverVibez and we will try again within the hour; otherwise your access ends on the date it runs out.'
    when 'sub_ended' then 'Your subscription to ' || coalesce(d->>'creator', 'a creator') || ' was not renewed, so it has ended. You can subscribe again any time from their page.'
  end;
  insert into email_queue(user_id, kind, subject, body) values (new.user_id, new.type, v_subject, v_body);
  return null;
exception when others then
  return null;          -- an email problem must never block the notification itself
end $$;

-- Studio needs each post's access type.
create or replace function public.creator_post_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = v_uid and account_type = 'creator') then raise exception 'Creators only'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select p.id, left(coalesce(p.caption, ''), 120) as caption, p.created_at, p.is_paid, p.price_cents, p.subs_only, p.sub_included, p.media_type::text as media_type,
           p.like_count as likes, p.comment_count as comments,
           coalesce(m.views, 0) as views, coalesce(m.shares, 0) as shares,
           (select count(*) from transactions t where t.reference_id = p.id and t.type = 'post_unlock' and t.refunded_at is null) as unlocks,
           (select count(*) from transactions t where t.reference_id = p.id and t.type = 'tip' and t.refunded_at is null) as tips,
           coalesce((select sum(t.net_cents) from transactions t where t.reference_id = p.id and t.type in ('post_unlock','tip') and t.refunded_at is null), 0) as earned_cents
      from posts p left join post_metrics m on m.post_id = p.id
     where p.creator_id = v_uid and p.removed_at is null and p.deleted_at is null) x), '[]'::jsonb);
end $$;
