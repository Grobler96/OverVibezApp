-- 049: creator growth tools.
--  * Offers: a creator makes a link that gives new subscribers either a FREE TRIAL (1 to 30 days, then the normal price renews from their
--    wallet unless they cancel) or a DISCOUNT on the first 30 days. Only people who have never subscribed to that creator can use one,
--    each person once, and the creator can set a limit on uses and an expiry date and switch an offer off at any time.
--  * Pinned posts: a creator can pin up to 3 of their posts to the top of their page.
-- Everything is enforced here in the database; the app only asks.

-- ---------- pinned posts ----------
alter table public.posts add column if not exists pinned_at timestamptz;
create or replace function public.pin_post(p_post uuid, p_pin boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from posts where id = p_post and creator_id = v_uid and removed_at is null and deleted_at is null) then raise exception 'You can only pin your own posts'; end if;
  if p_pin then
    if (select count(*) from posts where creator_id = v_uid and pinned_at is not null and removed_at is null and deleted_at is null and id <> p_post) >= 3 then
      raise exception 'You can pin up to 3 posts. Unpin one first.';
    end if;
    update posts set pinned_at = coalesce(pinned_at, now()) where id = p_post;
  else
    update posts set pinned_at = null where id = p_post;
  end if;
end $$;

-- ---------- offers ----------
alter table public.subscriptions add column if not exists trial_ends_at timestamptz, add column if not exists offer_id uuid;

create table if not exists public.creator_offers (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  code text not null unique,
  kind text not null check (kind in ('trial', 'discount')),
  trial_days int check (trial_days between 1 and 30),
  percent_off int check (percent_off between 10 and 90),
  max_uses int check (max_uses between 1 and 10000),
  uses int not null default 0,
  expires_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check ((kind = 'trial' and trial_days is not null and percent_off is null) or (kind = 'discount' and percent_off is not null and trial_days is null)));
create index if not exists creator_offers_creator on public.creator_offers (creator_id, created_at desc);
alter table public.creator_offers enable row level security;
revoke all on public.creator_offers from anon, authenticated;

create table if not exists public.offer_redemptions (
  offer_id uuid not null references public.creator_offers(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (offer_id, user_id));
alter table public.offer_redemptions enable row level security;
revoke all on public.offer_redemptions from anon, authenticated;

create or replace function public.create_offer(p_kind text, p_days int default null, p_percent int default null, p_max_uses int default null, p_expires_days int default null) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_code text; v_try int := 0;
begin
  perform _require_adult();
  if not exists (select 1 from profiles where id = v_uid and account_type = 'creator' and not is_banned) then raise exception 'Only creators can make offers'; end if;
  if p_kind not in ('trial', 'discount') then raise exception 'Choose a free trial or a discount'; end if;
  if p_kind = 'trial' and (p_days is null or p_days < 1 or p_days > 30) then raise exception 'A free trial can be 1 to 30 days'; end if;
  if p_kind = 'discount' and (p_percent is null or p_percent < 10 or p_percent > 90) then raise exception 'A discount can be 10%% to 90%%'; end if;
  if p_max_uses is not null and (p_max_uses < 1 or p_max_uses > 10000) then raise exception 'Limit must be between 1 and 10,000 uses'; end if;
  if p_expires_days is not null and (p_expires_days < 1 or p_expires_days > 365) then raise exception 'Expiry must be between 1 and 365 days'; end if;
  if p_kind = 'discount' and (select round(sub_price_cents * (100 - p_percent) / 100.0) from profiles where id = v_uid) < 100 then raise exception 'That discount would take your first month below £1.00'; end if;
  if (select count(*) from creator_offers where creator_id = v_uid and active) >= 10 then raise exception 'You can have up to 10 active offers. Turn one off first.'; end if;
  loop
    v_code := substr(upper(md5(random()::text || clock_timestamp()::text || v_uid::text)), 1, 8);
    begin
      insert into creator_offers(creator_id, code, kind, trial_days, percent_off, max_uses, expires_at)
      values (v_uid, v_code, p_kind, case when p_kind = 'trial' then p_days end, case when p_kind = 'discount' then p_percent end, p_max_uses,
              case when p_expires_days is not null then now() + make_interval(days => p_expires_days) end);
      exit;
    exception when unique_violation then v_try := v_try + 1; if v_try > 4 then raise; end if;
    end;
  end loop;
  return v_code;
end $$;

create or replace function public.my_offers()
returns table (id uuid, code text, kind text, trial_days int, percent_off int, max_uses int, uses int, expires_at timestamptz, active boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  return query select o.id, o.code, o.kind, o.trial_days, o.percent_off, o.max_uses, o.uses, o.expires_at, o.active, o.created_at
                 from creator_offers o where o.creator_id = auth.uid() order by o.created_at desc limit 50;
end $$;

create or replace function public.set_offer_active(p_offer uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_active and (select count(*) from creator_offers where creator_id = auth.uid() and active and id <> p_offer) >= 10 then raise exception 'You can have up to 10 active offers. Turn one off first.'; end if;
  update creator_offers set active = coalesce(p_active, false) where id = p_offer and creator_id = auth.uid();
  if not found then raise exception 'Offer not found'; end if;
end $$;

-- what a link offers the person opening it (also says why it cannot be used)
create or replace function public.offer_info(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); o creator_offers%rowtype; c profiles%rowtype; v_reason text; v_first int;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  select * into o from creator_offers where code = upper(trim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('valid', false, 'reason', 'This offer link is not valid'); end if;
  select * into c from profiles where id = o.creator_id;
  v_first := case when o.kind = 'discount' then round(c.sub_price_cents * (100 - o.percent_off) / 100.0)::int else 0 end;
  v_reason := case
    when not o.active then 'This offer has been switched off'
    when o.expires_at is not null and o.expires_at < now() then 'This offer has expired'
    when o.max_uses is not null and o.uses >= o.max_uses then 'This offer has been fully used'
    when o.creator_id = v_uid then 'This is your own offer'
    when exists (select 1 from subscriptions where subscriber_id = v_uid and creator_id = o.creator_id) then 'This offer is for new subscribers only'
    when c.is_banned or c.account_type <> 'creator' then 'This offer is not available' end;
  return jsonb_build_object('valid', v_reason is null, 'reason', v_reason, 'code', o.code, 'creator_id', o.creator_id, 'username', c.username,
    'kind', o.kind, 'trial_days', o.trial_days, 'percent_off', o.percent_off, 'price_cents', c.sub_price_cents, 'first_price_cents', v_first);
end $$;

-- subscribing WITH an offer is its own function; the normal subscribe_to_creator(p_creator) is untouched.
create or replace function public.subscribe_with_offer(p_creator uuid, p_offer text) returns void
language plpgsql security definer set search_path = public as $$
declare v_price int; v_off creator_offers%rowtype; v_first int;
begin
  perform _require_adult();
  select sub_price_cents into v_price from profiles where id = p_creator and account_type = 'creator';
  if v_price is null then raise exception 'Creator has no subscription price set'; end if;
  if p_creator = auth.uid() then raise exception 'Cannot subscribe to yourself'; end if;
  if p_offer is null or length(trim(p_offer)) = 0 then raise exception 'This offer is no longer available'; end if;
  select * into v_off from creator_offers where code = upper(trim(p_offer)) and creator_id = p_creator for update;
  if not found or not v_off.active or (v_off.expires_at is not null and v_off.expires_at < now()) or (v_off.max_uses is not null and v_off.uses >= v_off.max_uses) then
    raise exception 'This offer is no longer available';
  end if;
  if exists (select 1 from subscriptions where subscriber_id = auth.uid() and creator_id = p_creator) then raise exception 'This offer is for new subscribers only'; end if;
  insert into offer_redemptions(offer_id, user_id) values (v_off.id, auth.uid());
  update creator_offers set uses = uses + 1 where id = v_off.id;
  if v_off.kind = 'trial' then
    insert into subscriptions (subscriber_id, creator_id, price_cents, current_period_end, auto_renew, trial_ends_at, offer_id)
      values (auth.uid(), p_creator, v_price, now() + make_interval(days => v_off.trial_days), true, now() + make_interval(days => v_off.trial_days), v_off.id);
  else
    v_first := round(v_price * (100 - v_off.percent_off) / 100.0)::int;
    if v_first < 100 then raise exception 'That discount takes the price too low'; end if;
    perform _settle(p_creator, v_first, 'subscription', p_creator);
    insert into subscriptions (subscriber_id, creator_id, price_cents, current_period_end, auto_renew, offer_id)
      values (auth.uid(), p_creator, v_price, now() + interval '30 days', true, v_off.id);
  end if;
end $$;

revoke execute on function public.pin_post(uuid, boolean), public.create_offer(text, int, int, int, int), public.my_offers(), public.set_offer_active(uuid, boolean),
  public.offer_info(text), public.subscribe_with_offer(uuid, text) from public, anon;
grant execute on function public.pin_post(uuid, boolean), public.create_offer(text, int, int, int, int), public.my_offers(), public.set_offer_active(uuid, boolean),
  public.offer_info(text), public.subscribe_with_offer(uuid, text) to authenticated;
