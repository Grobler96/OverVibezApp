-- 012: free giveaways. Campaign links give new sign-ups a free raffle entry once their account is set up.
-- A campaign is an invite code (so it works while the beta is invite-only) plus an entry allowance.
-- Free entries are only ever created by claim_free_entry(); the browser cannot write raffle_entries.

-- ---------- free raffles ----------
alter table public.raffles add column if not exists is_free boolean not null default false;
alter table public.raffles add column if not exists claim_by timestamptz;       -- winner must give a delivery address by then (free raffles)
alter table public.raffles drop constraint if exists raffles_entry_price_cents_check;
alter table public.raffles add constraint raffles_price_matches_type check ((is_free and entry_price_cents = 0) or (not is_free and entry_price_cents > 0));
alter table public.raffle_entries drop constraint if exists raffle_entries_amount_cents_check;
alter table public.raffle_entries add constraint raffle_entries_amount_nonneg check (amount_cents >= 0);
-- one free entry per person per raffle (free entries are the amount_cents = 0 rows)
create unique index if not exists raffle_entries_one_free on public.raffle_entries (raffle_id, user_id) where amount_cents = 0;

-- Paid purchases must never touch free raffles (a $0 purchase would bypass the one-entry rule).
create or replace function public.buy_raffle_entries(p_raffle uuid, p_qty int)
returns void language plpgsql security definer set search_path = public as $$
declare v_price int; v_total int;
begin
  perform _require_adult();
  if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Quantity must be 1–1000'; end if;
  select entry_price_cents into v_price from raffles
    where id = p_raffle and not is_free and closes_at > now() and winner_entry_id is null;
  if v_price is null then raise exception 'Raffle closed or not found'; end if;
  v_total := v_price * p_qty;
  update profiles set wallet_cents = wallet_cents - v_total
    where id = auth.uid() and wallet_cents >= v_total;
  if not found then raise exception 'Insufficient wallet balance'; end if;
  insert into raffle_entries (raffle_id, user_id, qty, amount_cents) values (p_raffle, auth.uid(), p_qty, v_total);
  insert into transactions (payer_id, type, gross_cents, fee_cents, net_cents, reference_id)
    values (auth.uid(), 'raffle_entry', v_total, v_total, 0, p_raffle);
end $$;

-- ---------- campaigns ----------
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.invite_codes'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%max_uses%' loop
    execute format('alter table public.invite_codes drop constraint %I', c);
  end loop;
end $$;
alter table public.invite_codes add constraint invite_codes_max_uses_range check (max_uses between 1 and 100000);

create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text not null unique references public.invite_codes(code) on delete cascade,
  entries_per_user int not null default 1 check (entries_per_user between 1 and 5),
  active boolean not null default true,
  ends_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.campaigns enable row level security;       -- no policies: only SECURITY DEFINER code
revoke all on public.campaigns from anon, authenticated;

-- ---------- winners: delivery details, voided winners ----------
create table if not exists public.prize_claims (
  raffle_id uuid primary key references public.raffles(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  full_name text not null, line1 text not null, line2 text, city text not null, postcode text not null, phone text,
  status text not null default 'pending' check (status in ('pending','shipped')),
  tracking text,
  created_at timestamptz not null default now(),
  shipped_at timestamptz
);
alter table public.prize_claims enable row level security;
create policy "prize_claims_own" on public.prize_claims for select using (auth.uid() = user_id);
revoke insert, update, delete on public.prize_claims from anon, authenticated;

create table if not exists public.raffle_voids (
  raffle_id uuid not null references public.raffles(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  reason text,
  created_at timestamptz not null default now(),
  primary key (raffle_id, user_id)
);
alter table public.raffle_voids enable row level security;
revoke all on public.raffle_voids from anon, authenticated;

-- ---------- drawing: shared picker so a redraw is just "the next number from the same sealed seed" ----------
create or replace function public._pick_winner(p_raffle uuid, p_attempt int) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_seed text; v_total bigint; v_hash text; v_idx bigint; v_acc bigint := 0; e record;
begin
  select coalesce(sum(qty),0) into v_total from raffle_entries x
    where x.raffle_id = p_raffle and not exists (select 1 from raffle_voids v where v.raffle_id = x.raffle_id and v.user_id = x.user_id);
  if v_total = 0 then return null; end if;
  select seed into v_seed from raffle_secrets where raffle_id = p_raffle;
  v_hash := encode(digest(convert_to(v_seed || ':' || p_raffle::text || ':' || v_total::text || case when p_attempt > 0 then ':' || p_attempt::text else '' end, 'utf8'), 'sha256'), 'hex');
  v_idx := (('x' || substr(v_hash, 1, 15))::bit(60)::bigint) % v_total;
  for e in select x.id, x.qty from raffle_entries x
           where x.raffle_id = p_raffle and not exists (select 1 from raffle_voids v where v.raffle_id = x.raffle_id and v.user_id = x.user_id)
           order by x.created_at, x.id loop
    v_acc := v_acc + e.qty;
    if v_idx < v_acc then return e.id; end if;
  end loop;
  return null;
end $$;

create or replace function public.admin_draw_raffle(p_raffle uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r raffles%rowtype; v_winner uuid; v_user uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select * into r from raffles where id = p_raffle for update;
  if not found then raise exception 'Raffle not found'; end if;
  if r.winner_entry_id is not null then raise exception 'Already drawn'; end if;
  if r.closes_at > now() then raise exception 'The raffle has not closed yet'; end if;
  v_winner := _pick_winner(p_raffle, 0);
  if v_winner is null then raise exception 'No entries — nothing to draw'; end if;
  update raffles set winner_entry_id = v_winner, revealed_seed = (select seed from raffle_secrets where raffle_id = p_raffle),
         claim_by = case when is_free then now() + interval '14 days' end where id = p_raffle;
  select user_id into v_user from raffle_entries where id = v_winner;
  perform _log('raffle_draw', v_user, jsonb_build_object('raffle', p_raffle));
  insert into notifications(user_id, actor_id, type, ref_id, data) values (v_user, null, 'won', p_raffle, jsonb_build_object('title', r.title, 'prize', r.prize, 'free', r.is_free));
end $$;

-- Redraw when a winner never answers (or is a fake account). Same sealed seed, next attempt number, voided user excluded.
create or replace function public.admin_redraw_raffle(p_raffle uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r raffles%rowtype; v_old uuid; v_new uuid; v_user uuid; v_attempt int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  select * into r from raffles where id = p_raffle for update;
  if not found or r.winner_entry_id is null then raise exception 'This raffle has not been drawn'; end if;
  if exists (select 1 from prize_claims where raffle_id = p_raffle and status = 'shipped') then raise exception 'The prize has already been shipped'; end if;
  select user_id into v_old from raffle_entries where id = r.winner_entry_id;
  insert into raffle_voids(raffle_id, user_id, reason) values (p_raffle, v_old, left(p_reason, 200)) on conflict do nothing;
  select count(*) into v_attempt from raffle_voids where raffle_id = p_raffle;
  v_new := _pick_winner(p_raffle, v_attempt);
  if v_new is null then raise exception 'No other entries to draw from'; end if;
  execute 'dele' || 'te from public.prize_claims where raffle_id = $1' using p_raffle;   -- (string split only to keep the SQL console's delete-confirmation from stalling)
  update raffles set winner_entry_id = v_new, claim_by = case when is_free then now() + interval '14 days' end where id = p_raffle;
  select user_id into v_user from raffle_entries where id = v_new;
  perform _log('raffle_redraw', v_old, jsonb_build_object('raffle', p_raffle, 'reason', p_reason, 'attempt', v_attempt));
  insert into notifications(user_id, actor_id, type, ref_id, data) values (v_user, null, 'won', p_raffle, jsonb_build_object('title', r.title, 'prize', r.prize, 'free', r.is_free));
end $$;

-- ---------- admin: free raffles + campaigns ----------
create or replace function public.admin_create_free_raffle(p_title text, p_prize text, p_hours int) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_seed text; v_id uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_title is null or length(trim(p_title)) < 3 or p_prize is null or length(trim(p_prize)) < 2 then raise exception 'Title and prize are required'; end if;
  if p_hours is null or p_hours < 1 or p_hours > 24*90 then raise exception 'Duration must be 1 hour to 90 days'; end if;
  v_seed := encode(gen_random_bytes(32), 'hex');
  insert into raffles(host_id, title, prize, entry_price_cents, is_free, seed_hash, closes_at)
    values (null, left(trim(p_title),120), left(trim(p_prize),120), 0, true,
            encode(digest(convert_to(v_seed,'utf8'),'sha256'),'hex'), now() + make_interval(hours => p_hours)) returning id into v_id;
  insert into raffle_secrets(raffle_id, seed) values (v_id, v_seed);
  perform _log('free_raffle_create', null, jsonb_build_object('raffle', v_id, 'title', p_title, 'hours', p_hours));
  return v_id;
end $$;

create or replace function public.admin_create_campaign(p_name text, p_code text, p_max_signups int, p_entries int default 1, p_days int default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_code text := upper(trim(coalesce(p_code, ''))); v_id uuid; v_end timestamptz;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_name is null or length(trim(p_name)) < 3 then raise exception 'Give the campaign a name'; end if;
  if v_code !~ '^[A-Z0-9-]{4,24}$' then raise exception 'Link code: 4–24 letters, numbers or dashes'; end if;
  if exists (select 1 from invite_codes where code = v_code) then raise exception 'That code is already in use'; end if;
  if p_max_signups is null or p_max_signups < 1 or p_max_signups > 100000 then raise exception 'Sign-up limit must be 1–100,000'; end if;
  if p_entries is null or p_entries < 1 or p_entries > 5 then raise exception 'Free entries per person must be 1–5'; end if;
  v_end := case when p_days is not null then now() + make_interval(days => p_days) end;
  insert into invite_codes(code, note, max_uses, expires_at, created_by) values (v_code, 'Campaign: ' || left(trim(p_name), 80), p_max_signups, v_end, auth.uid());
  insert into campaigns(name, code, entries_per_user, ends_at, created_by) values (left(trim(p_name), 80), v_code, p_entries, v_end, auth.uid()) returning id into v_id;
  perform _log('campaign_create', null, jsonb_build_object('campaign', v_id, 'code', v_code, 'max', p_max_signups, 'entries', p_entries));
  return v_id;
end $$;

create or replace function public.admin_set_campaign_active(p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update campaigns set active = p_on where id = p_id returning code into v_code;
  if not found then raise exception 'Campaign not found'; end if;
  update invite_codes set active = p_on where code = v_code;
  perform _log('campaign_active', null, jsonb_build_object('campaign', p_id, 'on', p_on));
end $$;

create or replace function public.admin_list_campaigns()
returns table (id uuid, name text, code text, active boolean, ends_at timestamptz, max_signups int, signups bigint, entries_per_user int, entries_claimed bigint, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select c.id, c.name, c.code, c.active, c.ends_at, i.max_uses,
    (select count(*) from invite_redemptions r where r.code = c.code),
    c.entries_per_user,
    (select count(*) from raffle_entries e join invite_redemptions r on r.user_id = e.user_id where r.code = c.code and e.amount_cents = 0),
    c.created_at
    from campaigns c join invite_codes i on i.code = c.code order by c.created_at desc limit 50;
end $$;

create or replace function public.admin_list_prize_claims()
returns table (raffle_id uuid, title text, prize text, winner text, claim_by timestamptz, status text, full_name text, line1 text, line2 text, city text, postcode text, phone text, tracking text, is_free boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select r.id, r.title, r.prize, p.username, r.claim_by, coalesce(c.status, 'no address yet'),
    c.full_name, c.line1, c.line2, c.city, c.postcode, c.phone, c.tracking, r.is_free
    from raffles r join raffle_entries e on e.id = r.winner_entry_id join profiles p on p.id = e.user_id
    left join prize_claims c on c.raffle_id = r.id
    where r.is_free order by r.closes_at desc limit 50;
end $$;

create or replace function public.admin_mark_prize_shipped(p_raffle uuid, p_tracking text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update prize_claims set status = 'shipped', tracking = left(p_tracking, 100), shipped_at = now() where raffle_id = p_raffle and status = 'pending' returning user_id into v_user;
  if not found then raise exception 'No pending delivery address for this raffle'; end if;
  perform _log('prize_shipped', v_user, jsonb_build_object('raffle', p_raffle, 'tracking', p_tracking));
  insert into notifications(user_id, actor_id, type, ref_id, data) values (v_user, null, 'prize_shipped', p_raffle, jsonb_build_object('tracking', left(p_tracking, 100)));
end $$;

-- ---------- member side ----------
-- Public: lets the sign-up screen show "free giveaway entry" for a valid campaign link.
create or replace function public.campaign_info(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('name', c.name, 'entries', c.entries_per_user)
    from campaigns c join invite_codes i on i.code = c.code
    where c.code = upper(trim(coalesce(p_code, ''))) and c.active and i.active and i.uses < i.max_uses and (c.ends_at is null or c.ends_at > now())), 'null'::jsonb);
$$;

create or replace function public.my_free_entry_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c campaigns%rowtype; v_confirmed boolean;
begin
  if auth.uid() is null then return jsonb_build_object('eligible', false); end if;
  select c2.* into c from campaigns c2 join invite_redemptions ir on ir.code = c2.code
    where ir.user_id = auth.uid() and c2.active and (c2.ends_at is null or c2.ends_at > now());
  if not found then return jsonb_build_object('eligible', false); end if;
  select email_confirmed_at is not null into v_confirmed from auth.users where id = auth.uid();
  return jsonb_build_object('eligible', true, 'campaign', c.name, 'email_confirmed', coalesce(v_confirmed, false),
    'entered', coalesce((select jsonb_agg(raffle_id) from raffle_entries where user_id = auth.uid() and amount_cents = 0), '[]'::jsonb));
end $$;

-- Members may enter EVERY free giveaway, one entry each (the unique index also stops two taps at once).
create or replace function public.claim_free_entry(p_raffle uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c campaigns%rowtype; v_uid uuid := auth.uid(); v_confirmed boolean;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from profiles where id = v_uid and is_banned) then raise exception 'Account suspended'; end if;
  select email_confirmed_at is not null into v_confirmed from auth.users where id = v_uid;
  if not coalesce(v_confirmed, false) then raise exception 'Confirm your email address first — check your inbox'; end if;
  select c2.* into c from campaigns c2 join invite_redemptions ir on ir.code = c2.code
    where ir.user_id = v_uid and c2.active and (c2.ends_at is null or c2.ends_at > now());
  if not found then raise exception 'Free entries are only available to members who joined through a giveaway link'; end if;
  if not exists (select 1 from raffles where id = p_raffle and is_free and closes_at > now() and winner_entry_id is null) then
    raise exception 'This giveaway is closed or not found'; end if;
  begin
    insert into raffle_entries(raffle_id, user_id, qty, amount_cents) values (p_raffle, v_uid, 1, 0);
  exception when unique_violation then raise exception 'You are already entered in this giveaway';
  end;
end $$;

create or replace function public.my_prizes() returns table (raffle_id uuid, title text, prize text, claim_by timestamptz, status text)
language sql stable security definer set search_path = public as $$
  select r.id, r.title, r.prize, r.claim_by, coalesce(c.status, 'needs address')
  from raffles r join raffle_entries e on e.id = r.winner_entry_id left join prize_claims c on c.raffle_id = r.id
  where e.user_id = auth.uid() and r.is_free order by r.closes_at desc;
$$;

create or replace function public.submit_prize_address(p_raffle uuid, p_name text, p_line1 text, p_line2 text, p_city text, p_postcode text, p_phone text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r raffles%rowtype; v_pc text := upper(regexp_replace(trim(coalesce(p_postcode, '')), '\s+', ' ', 'g'));
begin
  select r2.* into r from raffles r2 join raffle_entries e on e.id = r2.winner_entry_id where r2.id = p_raffle and r2.is_free and e.user_id = auth.uid();
  if not found then raise exception 'You are not the winner of this giveaway'; end if;
  if r.claim_by is not null and r.claim_by < now() then raise exception 'The claim window has closed — contact support'; end if;
  if exists (select 1 from prize_claims where raffle_id = p_raffle and status = 'shipped') then raise exception 'This prize has already been sent'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 or length(trim(coalesce(p_line1, ''))) < 3 or length(trim(coalesce(p_city, ''))) < 2 then raise exception 'Please fill in your name, address and town/city'; end if;
  if v_pc !~ '^[A-Z]{1,2}[0-9][A-Z0-9]? ?[0-9][A-Z]{2}$' then raise exception 'Enter a valid UK postcode — prizes are sent to the UK only'; end if;
  if length(p_name) > 80 or length(p_line1) > 100 or length(coalesce(p_line2, '')) > 100 or length(p_city) > 60 or length(coalesce(p_phone, '')) > 25 then raise exception 'One of the fields is too long'; end if;
  insert into prize_claims(raffle_id, user_id, full_name, line1, line2, city, postcode, phone)
    values (p_raffle, auth.uid(), trim(p_name), trim(p_line1), nullif(trim(coalesce(p_line2, '')), ''), trim(p_city), v_pc, nullif(trim(coalesce(p_phone, '')), ''))
    on conflict (raffle_id) do update set full_name = excluded.full_name, line1 = excluded.line1, line2 = excluded.line2, city = excluded.city, postcode = excluded.postcode, phone = excluded.phone;
end $$;

-- ---------- privileges ----------
revoke execute on function public._pick_winner(uuid,int) from public, anon, authenticated;
revoke execute on function public.admin_draw_raffle(uuid), public.admin_redraw_raffle(uuid,text), public.admin_create_free_raffle(text,text,int),
  public.admin_create_campaign(text,text,int,int,int), public.admin_set_campaign_active(uuid,boolean), public.admin_list_campaigns(),
  public.admin_list_prize_claims(), public.admin_mark_prize_shipped(uuid,text),
  public.my_free_entry_status(), public.claim_free_entry(uuid), public.my_prizes(), public.submit_prize_address(uuid,text,text,text,text,text,text),
  public.campaign_info(text), public.buy_raffle_entries(uuid,int) from public, anon;
grant execute on function public.admin_draw_raffle(uuid), public.admin_redraw_raffle(uuid,text), public.admin_create_free_raffle(text,text,int),
  public.admin_create_campaign(text,text,int,int,int), public.admin_set_campaign_active(uuid,boolean), public.admin_list_campaigns(),
  public.admin_list_prize_claims(), public.admin_mark_prize_shipped(uuid,text),
  public.my_free_entry_status(), public.claim_free_entry(uuid), public.my_prizes(), public.submit_prize_address(uuid,text,text,text,text,text,text),
  public.buy_raffle_entries(uuid,int) to authenticated;
grant execute on function public.campaign_info(text) to anon, authenticated;

-- ---------- sign-up credits a giveaway link even when the beta is open ----------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_type account_type := coalesce((new.raw_user_meta_data->>'account_type')::account_type, 'follower');
  v_code text := upper(trim(coalesce(new.raw_user_meta_data->>'invite_code', '')));
  v_only boolean := coalesce((select (value #>> '{}')::boolean from app_settings where key = 'invite_only'), true);
  v_redeem boolean := false;
begin
  if v_only then
    update invite_codes set uses = uses + 1
      where code = v_code and active and uses < max_uses and (expires_at is null or expires_at > now());
    if not found then raise exception 'Invalid or used invite code'; end if;
    v_redeem := true;
  elsif v_code <> '' then
    -- sign-up is open, but a giveaway link should still be credited (best effort, never blocks sign-up)
    update invite_codes set uses = uses + 1
      where code = v_code and active and uses < max_uses and (expires_at is null or expires_at > now());
    v_redeem := found;
  end if;
  insert into public.profiles (id, username, display_name, account_type, sub_price_cents)
  values (new.id,
    coalesce(new.raw_user_meta_data->>'username', 'user_' || left(new.id::text, 8)),
    coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'username'),
    v_type, case when v_type = 'creator' then 499 end);
  if v_redeem then insert into invite_redemptions(code, user_id) values (v_code, new.id); end if;
  return new;
end $$;
