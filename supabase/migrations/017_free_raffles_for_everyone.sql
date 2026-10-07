-- 017: free giveaways are open to every confirmed member (not only people who joined through a campaign link),
-- raffles can run for up to 12 months, and members are told when a new free giveaway goes up.

create or replace function public.claim_free_entry(p_raffle uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_confirmed boolean;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from profiles where id = v_uid and is_banned) then raise exception 'Account suspended'; end if;
  select email_confirmed_at is not null into v_confirmed from auth.users where id = v_uid;
  if not coalesce(v_confirmed, false) then raise exception 'Confirm your email address first — check your inbox'; end if;
  if not exists (select 1 from raffles where id = p_raffle and is_free and closes_at > now() and winner_entry_id is null) then
    raise exception 'This giveaway is closed or not found'; end if;
  -- every confirmed member can enter every free giveaway, one entry each (the unique index also stops two taps at once)
  begin
    insert into raffle_entries(raffle_id, user_id, qty, amount_cents) values (p_raffle, v_uid, 1, 0);
  exception when unique_violation then raise exception 'You are already entered in this giveaway';
  end;
end $$;

create or replace function public.my_free_entry_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_confirmed boolean; v_campaign text;
begin
  if auth.uid() is null then return jsonb_build_object('eligible', false); end if;
  select email_confirmed_at is not null into v_confirmed from auth.users where id = auth.uid();
  select c.name into v_campaign from campaigns c join invite_redemptions ir on ir.code = c.code where ir.user_id = auth.uid() limit 1;
  return jsonb_build_object(
    'eligible', coalesce(v_confirmed, false) and not exists (select 1 from profiles where id = auth.uid() and is_banned),
    'email_confirmed', coalesce(v_confirmed, false), 'campaign', v_campaign,
    'entered', coalesce((select jsonb_agg(raffle_id) from raffle_entries where user_id = auth.uid() and amount_cents = 0), '[]'::jsonb));
end $$;

create or replace function public.admin_create_free_raffle(p_title text, p_prize text, p_hours int) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_seed text; v_id uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_title is null or length(trim(p_title)) < 3 or p_prize is null or length(trim(p_prize)) < 2 then raise exception 'Title and prize are required'; end if;
  if p_hours is null or p_hours < 1 or p_hours > 24*366 then raise exception 'Duration must be between 1 hour and 12 months'; end if;
  v_seed := encode(gen_random_bytes(32), 'hex');
  insert into raffles(host_id, title, prize, entry_price_cents, is_free, seed_hash, closes_at)
    values (null, left(trim(p_title),120), left(trim(p_prize),120), 0, true,
            encode(digest(convert_to(v_seed,'utf8'),'sha256'),'hex'), now() + make_interval(hours => p_hours)) returning id into v_id;
  insert into raffle_secrets(raffle_id, seed) values (v_id, v_seed);
  perform _log('free_raffle_create', null, jsonb_build_object('raffle', v_id, 'title', p_title, 'hours', p_hours));
  -- tell every existing member there is something new to enter
  insert into notifications(user_id, actor_id, type, ref_id, data)
    select id, null, 'new_giveaway', v_id, jsonb_build_object('title', left(trim(p_title),120), 'prize', left(trim(p_prize),120))
    from profiles where not is_banned and id <> auth.uid() limit 5000;
  return v_id;
end $$;

create or replace function public.admin_create_raffle(p_title text, p_prize text, p_price_cents int, p_hours int) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_seed text; v_id uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_title is null or length(trim(p_title)) < 3 or p_prize is null or length(trim(p_prize)) < 2 then raise exception 'Title and prize are required'; end if;
  if p_price_cents is null or p_price_cents < 50 or p_price_cents > 100000 then raise exception 'Entry price must be £0.50–£1000.00'; end if;
  if p_hours is null or p_hours < 1 or p_hours > 24*366 then raise exception 'Duration must be between 1 hour and 12 months'; end if;
  v_seed := encode(gen_random_bytes(32), 'hex');
  insert into raffles(host_id, title, prize, entry_price_cents, seed_hash, closes_at)
    values (null, left(trim(p_title),120), left(trim(p_prize),120), p_price_cents,
            encode(digest(convert_to(v_seed,'utf8'),'sha256'),'hex'), now() + make_interval(hours => p_hours)) returning id into v_id;
  insert into raffle_secrets(raffle_id, seed) values (v_id, v_seed);
  perform _log('raffle_create', null, jsonb_build_object('raffle', v_id, 'title', p_title, 'price_cents', p_price_cents, 'hours', p_hours));
  return v_id;
end $$;
