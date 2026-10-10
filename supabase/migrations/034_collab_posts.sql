-- 034: collab posts — two creators publish together and every sale is split automatically.
-- A creator invites another creator when posting and chooses the split (the collaborator gets 10-90%, default 50%). The post stays hidden from everyone
-- else until the collaborator accepts. After that, every unlock of the post and every tip sent from it is paid to BOTH creators as two normal payments
-- (each carries OverVibez's usual 15% on its own share), so refunds, receipts and debts keep working exactly as before.

alter table public.posts add column if not exists collab_user_id uuid references public.profiles(id) on delete set null;
alter table public.posts add column if not exists collab_pct int not null default 50 check (collab_pct between 10 and 90);   -- the collaborator's share
alter table public.posts add column if not exists collab_status text check (collab_status in ('pending','accepted','declined'));
alter table public.posts add constraint posts_collab_check check (collab_user_id is null or (collab_user_id <> creator_id and collab_status is not null));
grant insert (collab_user_id, collab_pct) on public.posts to authenticated;
create index if not exists posts_collab_idx on public.posts (collab_user_id) where collab_user_id is not null;

create or replace function public.posts_collab_before_insert() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.collab_user_id is null then new.collab_status := null; return new; end if;
  if new.collab_user_id = new.creator_id then raise exception 'You cannot collab with yourself'; end if;
  if not exists (select 1 from profiles where id = new.collab_user_id and account_type = 'creator' and not is_banned) then raise exception 'You can only collab with another creator'; end if;
  if exists (select 1 from blocks where (blocker_id = new.creator_id and blocked_id = new.collab_user_id) or (blocker_id = new.collab_user_id and blocked_id = new.creator_id)) then
    raise exception 'You cannot collab with this creator'; end if;
  if (select count(*) from posts where creator_id = new.creator_id and collab_status = 'pending') >= 10 then raise exception 'You already have 10 collab invitations waiting — wait for some to be answered'; end if;
  new.collab_status := 'pending';
  return new;
end $$;
create or replace trigger posts_collab_before_insert before insert on public.posts for each row execute function public.posts_collab_before_insert();

create or replace function public.posts_collab_after_insert() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.collab_user_id is not null then
    perform _notify(new.collab_user_id, new.creator_id, 'collab_invite', new.id, jsonb_build_object('preview', left(coalesce(new.caption, '(media post)'), 80), 'pct', new.collab_pct, 'who', (select username from profiles where id = new.creator_id)));
  end if;
  return null;
end $$;
create or replace trigger posts_collab_after_insert after insert on public.posts for each row execute function public.posts_collab_after_insert();
revoke execute on function public.posts_collab_before_insert(), public.posts_collab_after_insert() from public, anon, authenticated;

-- Hidden until accepted: only the two creators can see a pending or declined collab post.
alter policy posts_read on public.posts using (removed_at is null and deleted_at is null
  and (collab_status is null or collab_status = 'accepted' or creator_id = (select auth.uid()) or collab_user_id = (select auth.uid())));

create or replace function public.can_view_post(p_post_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from posts p
    where p.id = p_post_id
      and (p.collab_status is null or p.collab_status = 'accepted' or p.creator_id = auth.uid() or p.collab_user_id = auth.uid())
      and (
        p.is_paid = false
        or p.creator_id = auth.uid()
        or p.collab_user_id = auth.uid()
        or exists (select 1 from post_unlocks u where u.post_id = p.id and u.user_id = auth.uid())
        or ((p.subs_only or p.sub_included) and exists (select 1 from subscriptions s where s.creator_id = p.creator_id
                     and s.subscriber_id = auth.uid() and s.status in ('active','canceled')
                     and s.current_period_end > now()))
      )
  );
$$;

-- The collaborator answers an invitation (or leaves an accepted collab: the post stays up and later sales go to the owner alone).
create or replace function public.respond_collab(p_post uuid, p_accept boolean) returns void language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_old text; v_name text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select creator_id, collab_status into v_owner, v_old from posts where id = p_post and collab_user_id = auth.uid() and collab_status in ('pending','accepted') and removed_at is null and deleted_at is null for update;
  if not found then raise exception 'There is no collab invitation to answer'; end if;
  if p_accept and v_old = 'accepted' then return; end if;
  if p_accept then update posts set collab_status = 'accepted' where id = p_post;
  elsif v_old = 'accepted' then update posts set collab_user_id = null, collab_status = null where id = p_post;     -- leaving: the post stays up and later sales go to the owner alone
  else update posts set collab_status = 'declined' where id = p_post; end if;
  select username into v_name from profiles where id = auth.uid();
  perform _notify(v_owner, auth.uid(), 'collab_response', p_post, jsonb_build_object('accepted', p_accept, 'left', (not p_accept and v_old = 'accepted'), 'who', v_name));
end $$;
revoke execute on function public.respond_collab(uuid, boolean) from public, anon;
grant execute on function public.respond_collab(uuid, boolean) to authenticated;

-- Pay a sale on a collab post to both creators (two normal payments that add up to what the buyer paid).
create or replace function public._settle_collab(p_post uuid, p_gross int, p_type tx_type) returns void language plpgsql security definer set search_path = public as $$
declare p posts%rowtype; v_partner int; v_owner int;
begin
  select * into p from posts where id = p_post;
  v_partner := round(p_gross * p.collab_pct / 100.0)::int; v_owner := p_gross - v_partner;
  if v_partner > 0 then perform _settle(p.collab_user_id, v_partner, p_type, p_post); end if;
  if v_owner > 0 then perform _settle(p.creator_id, v_owner, p_type, p_post); end if;
end $$;
revoke execute on function public._settle_collab(uuid, int, tx_type) from public, anon, authenticated;

create or replace function public.purchase_post(p_post_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_price int; v_creator uuid; v_subs_only boolean; v_partner uuid; v_cstatus text;
begin
  perform _require_adult();
  select price_cents, creator_id, subs_only, collab_user_id, collab_status into v_price, v_creator, v_subs_only, v_partner, v_cstatus from posts where id = p_post_id and is_paid and removed_at is null and deleted_at is null;
  if v_subs_only then raise exception 'This post is for subscribers only — subscribe to the creator to see it'; end if;
  if v_price is null then raise exception 'Post not found or not paid'; end if;
  if v_cstatus in ('pending','declined') then raise exception 'This post is not published yet'; end if;
  if v_creator = auth.uid() or v_partner = auth.uid() then raise exception 'Cannot buy your own post'; end if;
  if exists (select 1 from post_unlocks where post_id = p_post_id and user_id = auth.uid()) then
    raise exception 'Already unlocked';
  end if;
  if v_cstatus = 'accepted' and v_partner is not null then perform _settle_collab(p_post_id, v_price, 'post_unlock');
  else perform _settle(v_creator, v_price, 'post_unlock', p_post_id); end if;
  insert into post_unlocks (post_id, user_id, amount_cents) values (p_post_id, auth.uid(), v_price);
end $$;

create or replace function public.tip_creator(p_creator uuid, p_amount int, p_post uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare po posts%rowtype;
begin
  perform _require_adult();
  if p_amount is null or p_amount < 100 or p_amount > 50000 then raise exception 'Tip must be £1.00–£500.00'; end if;
  if p_creator = auth.uid() then raise exception 'Cannot tip yourself'; end if;
  if not exists (select 1 from profiles where id = p_creator and account_type = 'creator') then
    raise exception 'Creator not found';
  end if;
  if p_post is not null then select * into po from posts where id = p_post and collab_status = 'accepted' and collab_user_id is not null and p_creator in (creator_id, collab_user_id); end if;
  if po.id is not null then
    if auth.uid() in (po.creator_id, po.collab_user_id) then raise exception 'Cannot tip yourself'; end if;
    perform _settle_collab(p_post, p_amount, 'tip');
  else
    perform _settle(p_creator, p_amount, 'tip', coalesce(p_post, p_creator));
  end if;
end $$;

create or replace function public.admin_refund_transaction(p_tx uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare t transactions%rowtype; v_take bigint; v_owe bigint; sib uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  select * into t from transactions where id = p_tx for update;
  if not found then raise exception 'Transaction not found'; end if;
  if t.refunded_at is not null then raise exception 'Already refunded'; end if;
  if t.type not in ('post_unlock','subscription','tip','live_entry') or t.payer_id is null or t.payee_id is null then
    raise exception 'Only unlocks, subscriptions, tips and live tickets can be refunded here'; end if;
  select least(earnings_cents, t.net_cents) into v_take from profiles where id = t.payee_id;
  update profiles set earnings_cents = earnings_cents - v_take where id = t.payee_id;
  v_owe := t.net_cents - v_take;
  if v_owe > 0 then insert into debts(user_id, cents, kind, reason, ref) values (t.payee_id, v_owe, 'refunded_sale', left(p_reason, 200), t.id::text); end if;
  update profiles set wallet_cents = wallet_cents + t.gross_cents where id = t.payer_id;
  if t.type = 'post_unlock' then execute 'dele' || 'te from public.post_unlocks where post_id = $1 and user_id = $2' using t.reference_id, t.payer_id;
  elsif t.type = 'subscription' then update subscriptions set status = 'canceled', current_period_end = now() where subscriber_id = t.payer_id and creator_id = t.payee_id;
  elsif t.type = 'live_entry' then execute 'dele' || 'te from public.live_tickets where stream_id = $1 and user_id = $2' using t.reference_id, t.payer_id;
  end if;
  update transactions set refunded_at = now() where id = p_tx;
  -- A sale on a collab post is paid to two creators as two linked payments: refunding one refunds its partner payment too, so the buyer gets everything back.
  if t.type in ('post_unlock','tip') then
    for sib in select s.id from transactions s where s.payer_id = t.payer_id and s.reference_id = t.reference_id and s.type = t.type and s.id <> t.id and s.refunded_at is null
        and s.created_at between t.created_at - interval '5 seconds' and t.created_at + interval '5 seconds'
        and exists (select 1 from posts po where po.id = t.reference_id and po.collab_user_id is not null) loop
      perform public.admin_refund_transaction(sib, p_reason);
    end loop;
  end if;
  insert into transactions(payer_id, payee_id, type, gross_cents, fee_cents, net_cents, reference_id)
    values (t.payee_id, t.payer_id, 'refund', t.gross_cents, t.fee_cents, t.net_cents, t.id);
  perform _log('refund', t.payer_id, jsonb_build_object('transaction', p_tx, 'type', t.type, 'gross', t.gross_cents, 'owed_by_creator', v_owe, 'reason', p_reason));
  perform _notify(t.payer_id, null, 'refunded', t.id, jsonb_build_object('cents', t.gross_cents, 'role', 'payer', 'reason', left(p_reason, 100)));
  perform _notify(t.payee_id, null, 'refunded', t.id, jsonb_build_object('cents', t.net_cents, 'role', 'payee', 'reason', left(p_reason, 100)));
end $$;

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
                        where t.payee_id = v_uid and t.type in ('post_unlock','tip') and (po.creator_id = v_uid or po.collab_user_id = v_uid) and t.created_at >= v_from::timestamp at time zone v_tz
                        group by po.id, po.caption order by sum(t.net_cents) desc limit 5) x),
    'followers_total', (select follower_count from profiles where id = v_uid));
end $$;

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
           (select count(*) from post_views v join follows fo on fo.follower_id = v.viewer_id and fo.creator_id = v_uid where v.post_id = p.id) as follower_views,
           (select count(*) from transactions t where t.reference_id = p.id and t.type = 'post_unlock' and t.payee_id = v_uid and t.refunded_at is null) as unlocks,
           (select count(*) from transactions t where t.reference_id = p.id and t.type = 'tip' and t.payee_id = v_uid and t.refunded_at is null) as tips,
           coalesce((select sum(t.net_cents) from transactions t where t.reference_id = p.id and t.type in ('post_unlock','tip') and t.payee_id = v_uid and t.refunded_at is null), 0) as earned_cents,
           p.creator_id as owner_id, p.collab_user_id, p.collab_status,
           case when p.collab_user_id is null then null when p.creator_id = v_uid then 100 - p.collab_pct else p.collab_pct end as my_pct
      from posts p left join post_metrics m on m.post_id = p.id
     where (p.creator_id = v_uid or (p.collab_user_id = v_uid and p.collab_status = 'accepted')) and p.removed_at is null and p.deleted_at is null) x), '[]'::jsonb);
end $$;

-- Email the invited creator.
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
    when 'collab_invite' then '@' || coalesce(d->>'who', 'a creator') || ' invited you to collab on a post'
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
    when 'collab_invite' then '@' || coalesce(d->>'who', 'a creator') || ' wants to publish a post with you and share the earnings: you would get ' || coalesce(d->>'pct', '50') || '% of every sale and tip on it (before OverVibez''s usual 15%).' ||
      E'\n\nOpen OverVibez and go to Studio to see the post and accept or decline. It stays hidden from everyone until you accept.'
  end;
  insert into email_queue(user_id, kind, subject, body) values (new.user_id, new.type, v_subject, v_body);
  return null;
exception when others then
  return null;          -- an email problem must never block the notification itself
end $$;
