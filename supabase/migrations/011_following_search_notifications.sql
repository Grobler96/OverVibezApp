-- 011: follower counts, creator categories, people search, notifications.

-- ---------- follower counts (maintained by trigger, so the app never has to download every follow) ----------
alter table public.profiles add column if not exists follower_count int not null default 0;
alter table public.profiles add column if not exists category text
  check (category in ('music','fitness','art','food','photography','fashion','gaming','comedy','lifestyle','other'));
grant select (follower_count, category) on public.profiles to anon, authenticated;
grant update (category) on public.profiles to authenticated;
update public.profiles p set follower_count = (select count(*) from public.follows f where f.creator_id = p.id);

create or replace function public.bump_follower_count() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update profiles set follower_count = follower_count + 1 where id = new.creator_id;
  else update profiles set follower_count = greatest(follower_count - 1, 0) where id = old.creator_id; end if;
  return null;
end $$;
create trigger follows_count after insert or delete on public.follows for each row execute function public.bump_follower_count();

-- ---------- notifications ----------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  type text not null,            -- new_follower, new_subscriber, subscription_renewed, tip, unlock, ticket, comment, like, live, payout_paid, removed
  ref_id uuid,                   -- post / stream the notification is about
  data jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);
create index if not exists notifications_unread_idx on public.notifications (user_id) where read_at is null;
alter table public.notifications enable row level security;
create policy "notifications_read_own" on public.notifications for select using (auth.uid() = user_id);
revoke insert, update, delete on public.notifications from anon, authenticated;     -- created only by the triggers below

create or replace function public._notify(p_user uuid, p_actor uuid, p_type text, p_ref uuid, p_data jsonb) returns void
language sql security definer set search_path = public as $$
  insert into notifications(user_id, actor_id, type, ref_id, data)
  select p_user, p_actor, p_type, p_ref, p_data where p_user is not null and p_user is distinct from p_actor;
$$;

create or replace function public.notify_follow() returns trigger language plpgsql security definer set search_path = public as $$
begin perform _notify(new.creator_id, new.follower_id, 'new_follower', null, null); return null; end $$;
create trigger notify_follow after insert on public.follows for each row execute function public.notify_follow();

create or replace function public.notify_subscription() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then perform _notify(new.creator_id, new.subscriber_id, 'new_subscriber', null, jsonb_build_object('price_cents', new.price_cents));
  elsif new.current_period_end > old.current_period_end then perform _notify(new.creator_id, new.subscriber_id, 'subscription_renewed', null, jsonb_build_object('price_cents', new.price_cents)); end if;
  return null;
end $$;
create trigger notify_subscription after insert or update on public.subscriptions for each row execute function public.notify_subscription();

create or replace function public.notify_payment() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.payee_id is not null and new.payer_id is not null and new.type in ('tip','post_unlock','live_entry') then
    perform _notify(new.payee_id, new.payer_id,
      case new.type when 'tip' then 'tip' when 'post_unlock' then 'unlock' else 'ticket' end,
      new.reference_id, jsonb_build_object('gross_cents', new.gross_cents, 'net_cents', new.net_cents));
  end if;
  return null;
end $$;
create trigger notify_payment after insert on public.transactions for each row execute function public.notify_payment();

create or replace function public.notify_comment() returns trigger language plpgsql security definer set search_path = public as $$
begin perform _notify((select creator_id from posts where id = new.post_id), new.user_id, 'comment', new.post_id, jsonb_build_object('preview', left(new.body, 80))); return null; end $$;
create trigger notify_comment after insert on public.comments for each row execute function public.notify_comment();

create or replace function public.notify_like() returns trigger language plpgsql security definer set search_path = public as $$
begin perform _notify((select creator_id from posts where id = new.post_id), new.user_id, 'like', new.post_id, null); return null; end $$;
create trigger notify_like after insert on public.likes for each row execute function public.notify_like();

create or replace function public.mark_notifications_read() returns void
language sql security definer set search_path = public as $$
  update notifications set read_at = now() where user_id = auth.uid() and read_at is null;
$$;

-- go-live fan-out (followers, up to 1000), payout paid, content removed
create or replace function public.start_live_stream(p_title text, p_price_cents int default 0) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform _require_adult();
  if not is_verified_creator() then raise exception 'Only verified creators can go live'; end if;
  if p_title is null or length(trim(p_title)) < 1 or length(p_title) > 120 then raise exception 'Give your stream a title (max 120 characters)'; end if;
  if p_price_cents is null or p_price_cents < 0 or p_price_cents > 50000 or (p_price_cents > 0 and p_price_cents < 99) then
    raise exception 'Entry price must be free or between $0.99 and $500.00'; end if;
  update live_streams set status = 'ended', ended_at = now() where creator_id = auth.uid() and status = 'live';
  insert into live_streams(creator_id, title, entry_price_cents, status) values (auth.uid(), trim(p_title), p_price_cents, 'live') returning id into v_id;
  insert into notifications(user_id, actor_id, type, ref_id, data)
    select f.follower_id, auth.uid(), 'live', v_id, jsonb_build_object('title', trim(p_title), 'price_cents', p_price_cents)
    from follows f where f.creator_id = auth.uid() limit 1000;
  return v_id;
end $$;

create or replace function public.admin_mark_payout_paid(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_creator uuid; v_amount bigint;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update payouts set status = 'paid', paid_at = now() where id = p_id and status = 'pending' returning creator_id, amount_cents into v_creator, v_amount;
  if not found then raise exception 'Pending payout not found'; end if;
  perform _log('payout_paid', v_creator, jsonb_build_object('payout', p_id));
  insert into notifications(user_id, actor_id, type, ref_id, data) values (v_creator, null, 'payout_paid', p_id, jsonb_build_object('amount_cents', v_amount));
end $$;

create or replace function public._remove(p_kind text, p_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_post uuid;
begin
  if p_kind = 'post' then
    update posts set removed_at = now(), removed_reason = left(p_reason,300) where id = p_id and removed_at is null returning creator_id into v_owner;
  elsif p_kind = 'comment' then
    update comments set removed_at = now(), removed_reason = left(p_reason,300) where id = p_id and removed_at is null returning user_id, post_id into v_owner, v_post;
    if found then update posts set comment_count = greatest(comment_count - 1, 0) where id = v_post; end if;
  elsif p_kind = 'message' then
    update messages set removed_at = now() where id = p_id and removed_at is null returning sender_id into v_owner;
  elsif p_kind = 'stream' then
    update live_streams set status = 'ended', ended_at = now() where id = p_id and status = 'live' returning creator_id into v_owner;
  else raise exception 'Unknown content type'; end if;
  if v_owner is null then raise exception 'Content not found or already removed'; end if;
  perform _log('remove_' || p_kind, v_owner, jsonb_build_object('id', p_id, 'reason', p_reason));
  if p_kind in ('post','comment','stream') then
    insert into notifications(user_id, actor_id, type, ref_id, data) values (v_owner, null, 'removed', p_id, jsonb_build_object('kind', p_kind, 'reason', left(p_reason, 200)));
  end if;
  return v_owner;
end $$;

-- ---------- people search ----------
create or replace function public.search_people(p_q text)
returns table (id uuid, username text, display_name text, bio text, avatar_url text, cover_url text, account_type text, is_verified boolean,
               sub_price_cents int, follower_count int, category text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  with q as (select replace(replace(replace(trim(coalesce(p_q, '')), '\', '\\'), '%', '\%'), '_', '\_') as t)
  select p.id, p.username, p.display_name, p.bio, p.avatar_url, p.cover_url, p.account_type::text, p.is_verified,
         p.sub_price_cents, p.follower_count, p.category, p.created_at
  from profiles p, q
  where length(q.t) >= 2 and not p.is_banned and (p.username ilike '%' || q.t || '%' or p.display_name ilike '%' || q.t || '%')
  order by p.follower_count desc, p.username limit 20;
$$;

-- ---------- privileges + realtime ----------
revoke execute on function public._notify(uuid,uuid,text,uuid,jsonb), public.bump_follower_count(), public.notify_follow(), public.notify_subscription(),
  public.notify_payment(), public.notify_comment(), public.notify_like() from public, anon, authenticated;
revoke execute on function public.mark_notifications_read(), public.search_people(text) from public, anon;
grant execute on function public.mark_notifications_read(), public.search_people(text) to authenticated;
alter publication supabase_realtime add table public.notifications;
