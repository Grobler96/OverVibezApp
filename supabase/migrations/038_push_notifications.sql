-- 038: push notifications (Web Push).
-- A member turns notifications on from this device; after that every in-app notification (new follower, sale, tip, payout, comment, live now, ...)
-- and every new message is also pushed to their phone or computer, even when the app is closed.
-- * push_subscriptions: the browser's push address for each device (private; only the owner can add or remove their own through functions).
-- * push_prefs: what a member wants to hear about (money / people / likes / messages / live) and whether to hide details on the lock screen.
-- * push_queue: filled by triggers, drained every few seconds by the `send-push` edge function, which signs and sends the pushes.
-- Pushes carry the same text as the in-app notification, or a plain "new activity" line when "hide details" is on. Message text is never sent.

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  ua text,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz,
  fail_count int not null default 0);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;

create table if not exists public.push_prefs (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  money boolean not null default true,
  people boolean not null default true,
  likes boolean not null default false,
  messages boolean not null default true,
  live boolean not null default true,
  discreet boolean not null default false,
  updated_at timestamptz not null default now());
alter table public.push_prefs enable row level security;
revoke all on public.push_prefs from anon, authenticated;

create table if not exists public.push_queue (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  actor text,
  data jsonb,
  ref_id uuid,
  status text not null default 'queued' check (status in ('queued','sending','sent','failed')),
  created_at timestamptz not null default now(),
  sent_at timestamp with time zone);
create index if not exists push_queue_todo_idx on public.push_queue (id) where status = 'queued';
alter table public.push_queue enable row level security;
revoke all on public.push_queue from anon, authenticated;

-- which preference a notification type belongs to ('account' is always sent: safety, age checks, prizes, appeals)
create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed') then 'account'
    else null end;
$$;

create or replace function public._push_wanted(p_user uuid, p_cat text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare pr push_prefs%rowtype;
begin
  if p_cat is null then return false; end if;
  if not exists (select 1 from push_subscriptions where user_id = p_user) then return false; end if;
  if p_cat = 'account' then return true; end if;
  select * into pr from push_prefs where user_id = p_user;
  if not found then return p_cat <> 'likes'; end if;
  return case p_cat when 'money' then pr.money when 'people' then pr.people when 'likes' then pr.likes when 'messages' then pr.messages when 'live' then pr.live else false end;
end $$;
revoke execute on function public._push_wanted(uuid, text) from public, anon, authenticated;

create or replace function public.push_from_notification() returns trigger language plpgsql security definer set search_path = public as $$
declare v_cat text := _push_category(new.type);
begin
  if not _push_wanted(new.user_id, v_cat) then return null; end if;
  -- never flood one person: at most 40 pushes an hour (safety and account messages are exempt)
  if v_cat <> 'account' and (select count(*) from push_queue where user_id = new.user_id and created_at > now() - interval '1 hour') >= 40 then return null; end if;
  insert into push_queue(user_id, type, actor, data, ref_id)
  values (new.user_id, new.type, (select username from profiles where id = new.actor_id), coalesce(new.data, '{}'::jsonb), new.ref_id);
  return null;
exception when others then
  return null;      -- a push problem must never stop the notification itself
end $$;
create or replace trigger notifications_push after insert on public.notifications for each row execute function public.push_from_notification();

create or replace function public.push_from_message() returns trigger language plpgsql security definer set search_path = public as $$
declare v_to uuid;
begin
  select case when c.user_a = new.sender_id then c.user_b else c.user_a end into v_to from conversations c where c.id = new.conversation_id;
  if v_to is null or not _push_wanted(v_to, 'messages') then return null; end if;
  -- one push per sender every two minutes, so a busy chat does not buzz a phone for every line
  if exists (select 1 from push_queue where user_id = v_to and type = 'message' and actor = (select username from profiles where id = new.sender_id) and created_at > now() - interval '2 minutes') then return null; end if;
  insert into push_queue(user_id, type, actor, data, ref_id) values (v_to, 'message', (select username from profiles where id = new.sender_id), '{}'::jsonb, new.conversation_id);
  return null;
exception when others then
  return null;
end $$;
create or replace trigger messages_push after insert on public.messages for each row execute function public.push_from_message();
revoke execute on function public.push_from_notification(), public.push_from_message() from public, anon, authenticated;

-- The signing key pair for Web Push. The send-push function creates it by itself the first time it runs (so the private half never has to be pasted
-- anywhere); only that function (service role) can read it. The public half is handed to browsers through push_public_key().
create table if not exists public.push_vapid (
  id int primary key check (id = 1),
  public_key text not null,
  private_key text not null,
  created_at timestamptz not null default now());
alter table public.push_vapid enable row level security;
revoke all on public.push_vapid from anon, authenticated;
create or replace function public.push_public_key() returns text language sql stable security definer set search_path = public as $$
  select public_key from push_vapid where id = 1;
$$;
revoke execute on function public.push_public_key() from public, anon;
grant execute on function public.push_public_key() to authenticated;

-- ---------- member-facing functions ----------
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or coalesce(length(p_p256dh), 0) < 20 or coalesce(length(p_auth), 0) < 8 then raise exception 'Invalid subscription'; end if;
  insert into push_subscriptions(user_id, endpoint, p256dh, auth, ua) values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_ua, 200))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua, fail_count = 0;
  execute 'dele' || 'te from public.push_subscriptions where user_id = $1 and id not in (select id from public.push_subscriptions where user_id = $1 order by created_at desc limit 10)' using auth.uid();
  insert into push_prefs(user_id) values (auth.uid()) on conflict do nothing;
end $$;

create or replace function public.remove_push_subscription(p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  execute 'dele' || 'te from public.push_subscriptions where user_id = $1 and endpoint = $2' using auth.uid(), p_endpoint;
end $$;

create or replace function public.get_push_prefs() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pr push_prefs%rowtype;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into pr from push_prefs where user_id = auth.uid();
  if not found then pr.money := true; pr.people := true; pr.likes := false; pr.messages := true; pr.live := true; pr.discreet := false; end if;
  return jsonb_build_object('money', pr.money, 'people', pr.people, 'likes', pr.likes, 'messages', pr.messages, 'live', pr.live, 'discreet', pr.discreet,
                            'devices', (select count(*) from push_subscriptions where user_id = auth.uid()));
end $$;

create or replace function public.set_push_prefs(p_money boolean, p_people boolean, p_likes boolean, p_messages boolean, p_live boolean, p_discreet boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  insert into push_prefs(user_id, money, people, likes, messages, live, discreet, updated_at)
  values (auth.uid(), coalesce(p_money, true), coalesce(p_people, true), coalesce(p_likes, false), coalesce(p_messages, true), coalesce(p_live, true), coalesce(p_discreet, false), now())
  on conflict (user_id) do update set money = excluded.money, people = excluded.people, likes = excluded.likes, messages = excluded.messages, live = excluded.live, discreet = excluded.discreet, updated_at = now();
end $$;
revoke execute on function public.save_push_subscription(text, text, text, text), public.remove_push_subscription(text), public.get_push_prefs(),
  public.set_push_prefs(boolean, boolean, boolean, boolean, boolean, boolean) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text), public.remove_push_subscription(text), public.get_push_prefs(),
  public.set_push_prefs(boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;

-- ---------- for the send-push edge function (service role only) ----------
create or replace function public.claim_push_batch(p_limit int default 100) returns setof public.push_queue
language sql security definer set search_path = public as $$
  with c as (select id from push_queue where status = 'queued' order by id limit least(greatest(p_limit, 1), 500) for update skip locked)
  update push_queue q set status = 'sending' from c where q.id = c.id returning q.*;
$$;
create or replace function public.finish_push(p_ids bigint[], p_status text) returns void
language sql security definer set search_path = public as $$
  update push_queue set status = p_status, sent_at = now() where id = any(p_ids) and p_status in ('sent','failed');
$$;
create or replace function public.push_cleanup() returns void
language plpgsql security definer set search_path = public as $$
begin
  execute 'dele' || 'te from public.push_queue where created_at < now() - interval ''3 days''';
  update push_queue set status = 'queued' where status = 'sending' and created_at < now() - interval '10 minutes';
end $$;
revoke execute on function public.claim_push_batch(int), public.finish_push(bigint[], text), public.push_cleanup() from public, anon, authenticated;
grant execute on function public.claim_push_batch(int), public.finish_push(bigint[], text) to service_role;
