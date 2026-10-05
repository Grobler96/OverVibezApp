-- OverVibez core schema (hardened). Apply as migration 1 of 2.
-- Principle: clients may only write low-risk columns directly; every money or
-- entitlement change goes through SECURITY DEFINER functions.

-- ---------- Enums ----------
create type account_type as enum ('creator','follower');
create type media_type as enum ('image','video','text');
create type sub_status as enum ('active','canceled','past_due');
create type tx_type as enum ('subscription','post_unlock','tip','live_entry','raffle_entry','payout','wallet_topup');
create type report_status as enum ('open','reviewing','actioned','dismissed');
create type live_status as enum ('scheduled','live','ended');

-- ---------- Profiles ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (username ~ '^[a-z0-9_\.]{3,24}$'),
  display_name text check (length(display_name) <= 60),
  bio text check (length(bio) <= 500),
  avatar_url text,
  account_type account_type not null default 'follower',
  is_verified boolean not null default false,
  age_verified boolean not null default false,   -- set ONLY by the verification webhook (service role)
  sub_price_cents int check (sub_price_cents between 199 and 9999),
  wallet_cents bigint not null default 0 check (wallet_cents >= 0),
  earnings_cents bigint not null default 0 check (earnings_cents >= 0),
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, display_name, account_type)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', 'user_' || left(new.id::text, 8)),
    coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'username'),
    coalesce((new.raw_user_meta_data->>'account_type')::account_type, 'follower')
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Social graph ----------
create table public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  creator_id  uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, creator_id),
  check (follower_id <> creator_id)
);
create index on public.follows (creator_id);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  subscriber_id uuid not null references public.profiles(id) on delete cascade,
  creator_id    uuid not null references public.profiles(id) on delete cascade,
  price_cents int not null,
  status sub_status not null default 'active',
  current_period_end timestamptz not null,
  created_at timestamptz not null default now(),
  unique (subscriber_id, creator_id)
);
create index on public.subscriptions (creator_id);

-- ---------- Content ----------
create table public.posts (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  caption text check (length(caption) <= 2200),
  media_type media_type not null default 'image',
  media_path text,   -- convention: {creator_id}/{post_id}/{file}; paid media lives in the PRIVATE bucket
  is_paid boolean not null default false,
  price_cents int check (price_cents between 99 and 49999),
  like_count int not null default 0,
  comment_count int not null default 0,
  created_at timestamptz not null default now(),
  check (not is_paid or price_cents is not null)
);
create index on public.posts (creator_id, created_at desc);
create index on public.posts (created_at desc);

create table public.post_unlocks (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount_cents int not null,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create index on public.post_unlocks (user_id);

create table public.likes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key (post_id, user_id)
);
create index on public.likes (user_id);

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index on public.comments (post_id, created_at);
create index on public.comments (user_id);

create table public.stories (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  media_path text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);
create index on public.stories (creator_id, expires_at);

create table public.live_streams (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (length(title) <= 120),
  entry_price_cents int not null default 0 check (entry_price_cents >= 0),
  status live_status not null default 'live',
  started_at timestamptz not null default now(),
  ended_at timestamptz
);
create index on public.live_streams (creator_id);

-- ---------- Messaging ----------
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references public.profiles(id) on delete cascade,
  user_b uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_a, user_b),
  check (user_a < user_b)
);
create index on public.conversations (user_b);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (length(body) between 1 and 4000),
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index on public.messages (conversation_id, created_at);
create index on public.messages (sender_id);

-- ---------- Raffles ----------
create table public.raffles (
  id uuid primary key default gen_random_uuid(),
  host_id uuid references public.profiles(id) on delete set null,
  title text not null,
  prize text not null,
  entry_price_cents int not null check (entry_price_cents > 0),
  seed_hash text not null,
  revealed_seed text,
  closes_at timestamptz not null,
  winner_entry_id uuid,
  created_at timestamptz not null default now()
);

create table public.raffle_entries (
  id uuid primary key default gen_random_uuid(),
  raffle_id uuid not null references public.raffles(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  qty int not null check (qty > 0),
  amount_cents int not null check (amount_cents > 0),
  created_at timestamptz not null default now()
);
create index on public.raffle_entries (raffle_id);
create index on public.raffle_entries (user_id);

-- ---------- Money ----------
create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  payer_id uuid references public.profiles(id) on delete set null,
  payee_id uuid references public.profiles(id) on delete set null,
  type tx_type not null,
  gross_cents bigint not null,
  fee_cents bigint not null default 0,
  net_cents bigint not null,
  reference_id uuid,
  created_at timestamptz not null default now()
);
create index on public.transactions (payee_id, created_at desc);
create index on public.transactions (payer_id, created_at desc);

create table public.payouts (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  amount_cents bigint not null check (amount_cents > 0),
  status text not null default 'pending',
  created_at timestamptz not null default now()
);
create index on public.payouts (creator_id);

-- ---------- Safety ----------
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  target_type text not null check (target_type in ('post','profile','message','stream','comment')),
  target_id uuid not null,
  reason text not null check (length(reason) between 1 and 1000),
  status report_status not null default 'open',
  created_at timestamptz not null default now()
);

-- ═══════════════ Counter triggers (clients cannot write counters) ═══════════════
create or replace function public.bump_like_count() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update posts set like_count = like_count + 1 where id = new.post_id;
  else update posts set like_count = greatest(like_count - 1, 0) where id = old.post_id; end if;
  return null;
end $$;
create trigger likes_count after insert or delete on public.likes
  for each row execute function public.bump_like_count();

create or replace function public.bump_comment_count() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update posts set comment_count = comment_count + 1 where id = new.post_id;
  else update posts set comment_count = greatest(comment_count - 1, 0) where id = old.post_id; end if;
  return null;
end $$;
create trigger comments_count after insert or delete on public.comments
  for each row execute function public.bump_comment_count();

-- ═══════════════ Access helper ═══════════════
create or replace function public.can_view_post(p_post_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from posts p
    where p.id = p_post_id
      and (
        p.is_paid = false
        or p.creator_id = auth.uid()
        or exists (select 1 from post_unlocks u where u.post_id = p.id and u.user_id = auth.uid())
        or exists (select 1 from subscriptions s where s.creator_id = p.creator_id
                     and s.subscriber_id = auth.uid() and s.status = 'active'
                     and s.current_period_end > now())
      )
  );
$$;

-- ═══════════════ Internal money helpers (not callable by clients) ═══════════════
create or replace function public._require_adult() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and age_verified) then
    raise exception 'Age verification required';
  end if;
end $$;

-- Debit payer wallet, credit creator 85%, log transaction. Returns nothing; raises on failure.
create or replace function public._settle(p_creator uuid, p_gross int, p_type tx_type, p_ref uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_fee int; v_net int;
begin
  update profiles set wallet_cents = wallet_cents - p_gross
    where id = auth.uid() and wallet_cents >= p_gross;
  if not found then raise exception 'Insufficient wallet balance'; end if;
  v_fee := round(p_gross * 0.15); v_net := p_gross - v_fee;
  update profiles set earnings_cents = earnings_cents + v_net where id = p_creator;
  insert into transactions (payer_id, payee_id, type, gross_cents, fee_cents, net_cents, reference_id)
    values (auth.uid(), p_creator, p_type, p_gross, v_fee, v_net, p_ref);
end $$;

-- ═══════════════ Public RPCs ═══════════════
create or replace function public.purchase_post(p_post_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_price int; v_creator uuid;
begin
  perform _require_adult();
  select price_cents, creator_id into v_price, v_creator from posts where id = p_post_id and is_paid;
  if v_price is null then raise exception 'Post not found or not paid'; end if;
  if v_creator = auth.uid() then raise exception 'Cannot buy your own post'; end if;
  if exists (select 1 from post_unlocks where post_id = p_post_id and user_id = auth.uid()) then
    raise exception 'Already unlocked';
  end if;
  perform _settle(v_creator, v_price, 'post_unlock', p_post_id);
  insert into post_unlocks (post_id, user_id, amount_cents) values (p_post_id, auth.uid(), v_price);
end $$;

create or replace function public.subscribe_to_creator(p_creator uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_price int;
begin
  perform _require_adult();
  select sub_price_cents into v_price from profiles where id = p_creator and account_type = 'creator';
  if v_price is null then raise exception 'Creator has no subscription price set'; end if;
  if p_creator = auth.uid() then raise exception 'Cannot subscribe to yourself'; end if;
  perform _settle(p_creator, v_price, 'subscription', p_creator);
  insert into subscriptions (subscriber_id, creator_id, price_cents, current_period_end)
    values (auth.uid(), p_creator, v_price, now() + interval '30 days')
    on conflict (subscriber_id, creator_id) do update
      set status = 'active', price_cents = v_price,
          current_period_end = greatest(subscriptions.current_period_end, now()) + interval '30 days';
end $$;

create or replace function public.tip_creator(p_creator uuid, p_amount int, p_post uuid default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_adult();
  if p_amount is null or p_amount < 100 or p_amount > 50000 then raise exception 'Tip must be $1.00–$500.00'; end if;
  if p_creator = auth.uid() then raise exception 'Cannot tip yourself'; end if;
  if not exists (select 1 from profiles where id = p_creator and account_type = 'creator') then
    raise exception 'Creator not found';
  end if;
  perform _settle(p_creator, p_amount, 'tip', coalesce(p_post, p_creator));
end $$;

create or replace function public.buy_raffle_entries(p_raffle uuid, p_qty int)
returns void language plpgsql security definer set search_path = public as $$
declare v_price int; v_total int;
begin
  perform _require_adult();
  if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Quantity must be 1–1000'; end if;
  select entry_price_cents into v_price from raffles
    where id = p_raffle and closes_at > now() and winner_entry_id is null;
  if v_price is null then raise exception 'Raffle closed or not found'; end if;
  v_total := v_price * p_qty;
  update profiles set wallet_cents = wallet_cents - v_total
    where id = auth.uid() and wallet_cents >= v_total;
  if not found then raise exception 'Insufficient wallet balance'; end if;
  insert into raffle_entries (raffle_id, user_id, qty, amount_cents) values (p_raffle, auth.uid(), p_qty, v_total);
  insert into transactions (payer_id, type, gross_cents, fee_cents, net_cents, reference_id)
    values (auth.uid(), 'raffle_entry', v_total, v_total, 0, p_raffle);
end $$;

create or replace function public.request_payout(p_amount bigint)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform _require_adult();
  if not exists (select 1 from profiles where id = auth.uid() and account_type = 'creator') then
    raise exception 'Only creators can request payouts';
  end if;
  if p_amount is null or p_amount < 1000 then raise exception 'Minimum payout is $10.00'; end if;
  update profiles set earnings_cents = earnings_cents - p_amount
    where id = auth.uid() and earnings_cents >= p_amount;
  if not found then raise exception 'Insufficient earnings'; end if;
  insert into payouts (creator_id, amount_cents) values (auth.uid(), p_amount) returning id into v_id;
  insert into transactions (payee_id, type, gross_cents, fee_cents, net_cents, reference_id)
    values (auth.uid(), 'payout', p_amount, 0, p_amount, v_id);
  return v_id;
end $$;

-- The caller's own full profile (includes wallet, earnings, age_verified).
create or replace function public.get_my_profile()
returns public.profiles language sql stable security definer set search_path = public as $$
  select * from profiles where id = auth.uid();
$$;

create or replace function public.get_or_create_conversation(p_other uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_a uuid; v_b uuid; v_id uuid;
begin
  if auth.uid() is null or p_other = auth.uid() then raise exception 'Invalid conversation'; end if;
  if not exists (select 1 from profiles where id = p_other) then raise exception 'User not found'; end if;
  v_a := least(auth.uid(), p_other); v_b := greatest(auth.uid(), p_other);
  insert into conversations (user_a, user_b) values (v_a, v_b)
    on conflict (user_a, user_b) do nothing;
  select id into v_id from conversations where user_a = v_a and user_b = v_b;
  return v_id;
end $$;

-- Aggregate raffle stats without exposing other users' entries.
create or replace function public.raffle_totals(p_raffle uuid)
returns table (entries bigint, players bigint) language sql stable security definer set search_path = public as $$
  select coalesce(sum(qty),0)::bigint, count(distinct user_id)::bigint from raffle_entries where raffle_id = p_raffle;
$$;

-- ═══════════════ Function privileges ═══════════════
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.can_view_post(uuid), public.purchase_post(uuid), public.subscribe_to_creator(uuid),
  public.tip_creator(uuid,int,uuid), public.buy_raffle_entries(uuid,int), public.request_payout(bigint),
  public.get_my_profile(), public.get_or_create_conversation(uuid), public.raffle_totals(uuid)
  to authenticated;
grant execute on function public.can_view_post(uuid), public.raffle_totals(uuid) to anon;

-- ═══════════════ Row Level Security ═══════════════
alter table public.profiles enable row level security;
alter table public.follows enable row level security;
alter table public.subscriptions enable row level security;
alter table public.posts enable row level security;
alter table public.post_unlocks enable row level security;
alter table public.likes enable row level security;
alter table public.comments enable row level security;
alter table public.stories enable row level security;
alter table public.live_streams enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.raffles enable row level security;
alter table public.raffle_entries enable row level security;
alter table public.transactions enable row level security;
alter table public.payouts enable row level security;
alter table public.reports enable row level security;

create policy "profiles_read"   on public.profiles for select using (true);
create policy "profiles_update" on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id and (sub_price_cents is null or account_type = 'creator'));

create policy "follows_read"   on public.follows for select using (true);
create policy "follows_insert" on public.follows for insert with check (auth.uid() = follower_id);
create policy "follows_delete" on public.follows for delete using (auth.uid() = follower_id);

create policy "subs_read" on public.subscriptions for select using (auth.uid() in (subscriber_id, creator_id));

create policy "posts_read" on public.posts for select using (true);
create policy "posts_insert" on public.posts for insert with check (
  auth.uid() = creator_id
  and exists (select 1 from profiles pr where pr.id = auth.uid() and pr.account_type = 'creator' and pr.age_verified)
);
create policy "posts_update" on public.posts for update using (auth.uid() = creator_id);
create policy "posts_delete" on public.posts for delete using (auth.uid() = creator_id);

create policy "unlocks_read" on public.post_unlocks for select
  using (auth.uid() = user_id or auth.uid() in (select creator_id from posts where id = post_id));

create policy "likes_read"    on public.likes for select using (true);
create policy "likes_insert"  on public.likes for insert with check (auth.uid() = user_id);
create policy "likes_delete"  on public.likes for delete using (auth.uid() = user_id);
create policy "comments_read"   on public.comments for select using (true);
create policy "comments_insert" on public.comments for insert with check (auth.uid() = user_id);
create policy "comments_delete" on public.comments for delete using (auth.uid() = user_id);

create policy "stories_read" on public.stories for select using (expires_at > now());
create policy "stories_insert" on public.stories for insert with check (
  auth.uid() = creator_id
  and exists (select 1 from profiles pr where pr.id = auth.uid() and pr.account_type = 'creator' and pr.age_verified)
);
create policy "stories_delete" on public.stories for delete using (auth.uid() = creator_id);

create policy "streams_read"   on public.live_streams for select using (true);
create policy "streams_insert" on public.live_streams for insert with check (
  auth.uid() = creator_id
  and exists (select 1 from profiles pr where pr.id = auth.uid() and pr.account_type = 'creator' and pr.age_verified)
);
create policy "streams_update" on public.live_streams for update using (auth.uid() = creator_id);

create policy "conv_read" on public.conversations for select using (auth.uid() in (user_a, user_b));
create policy "msg_read" on public.messages for select using (
  exists (select 1 from conversations c where c.id = conversation_id and auth.uid() in (c.user_a, c.user_b)));
create policy "msg_insert" on public.messages for insert with check (
  auth.uid() = sender_id and
  exists (select 1 from conversations c where c.id = conversation_id and auth.uid() in (c.user_a, c.user_b)));
create policy "msg_mark_read" on public.messages for update
  using (sender_id <> auth.uid() and
    exists (select 1 from conversations c where c.id = conversation_id and auth.uid() in (c.user_a, c.user_b)));

create policy "raffles_read" on public.raffles for select using (true);
create policy "entries_read" on public.raffle_entries for select using (auth.uid() = user_id);

create policy "tx_read" on public.transactions for select using (auth.uid() in (payer_id, payee_id));
create policy "payouts_read" on public.payouts for select using (auth.uid() = creator_id);

create policy "reports_insert" on public.reports for insert with check (auth.uid() = reporter_id);
create policy "reports_read"   on public.reports for select using (auth.uid() = reporter_id);

-- ═══════════════ Table / column privileges (defense in depth beyond RLS) ═══════════════
revoke insert, update, delete, truncate on all tables in schema public from anon;
revoke truncate, trigger, references on all tables in schema public from authenticated;

-- profiles: hide wallet/earnings/age_verified from other users; only safe columns writable.
revoke select, insert, update, delete on public.profiles from anon, authenticated;
grant select (id, username, display_name, bio, avatar_url, account_type, is_verified, sub_price_cents, created_at)
  on public.profiles to anon, authenticated;
grant update (display_name, bio, avatar_url, sub_price_cents) on public.profiles to authenticated;

-- posts: counters and ownership are not client-writable.
revoke insert, update on public.posts from authenticated;
grant insert (creator_id, caption, media_type, media_path, is_paid, price_cents) on public.posts to authenticated;
grant update (caption) on public.posts to authenticated;

-- messages: send body only; recipients may only set read_at.
revoke insert, update on public.messages from authenticated;
grant insert (conversation_id, sender_id, body) on public.messages to authenticated;
grant update (read_at) on public.messages to authenticated;

-- money/entitlement tables are written only by SECURITY DEFINER functions.
revoke insert, update, delete on public.subscriptions, public.post_unlocks, public.raffles,
  public.raffle_entries, public.transactions, public.payouts, public.conversations from authenticated;
