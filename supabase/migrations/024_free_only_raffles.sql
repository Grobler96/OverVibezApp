-- 024: raffles are free-entry only (paid entries are switched off).
-- Paid raffle entries are treated as gambling by card processors and need a licence, so the platform runs free giveaways only.
-- The paid code path stays in the database but cannot be used unless an admin deliberately flips this setting, which is
-- not exposed in the app.

insert into public.app_settings(key, value) values ('paid_raffles', 'false'::jsonb) on conflict (key) do nothing;

create or replace function public._paid_raffles_on() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::boolean from app_settings where key = 'paid_raffles'), false)
$$;

create or replace function public.admin_create_raffle(p_title text, p_prize text, p_price_cents int, p_hours int) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_seed text; v_id uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if not _paid_raffles_on() then raise exception 'Paid raffles are switched off — all raffles are free to enter'; end if;
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

create or replace function public.buy_raffle_entries(p_raffle uuid, p_qty int)
returns void language plpgsql security definer set search_path = public as $$
declare v_price int; v_total int;
begin
  perform _require_adult();
  if not _paid_raffles_on() then raise exception 'Paid raffles are switched off — free giveaways only'; end if;
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

create or replace function public.public_settings() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('invite_only', coalesce((select (value #>> '{}')::boolean from app_settings where key = 'invite_only'), true),
                            'support_email', (select value #>> '{}' from app_settings where key = 'support_email'),
                            'paid_raffles', public._paid_raffles_on());
$$;

revoke execute on function public._paid_raffles_on() from public, anon, authenticated;
