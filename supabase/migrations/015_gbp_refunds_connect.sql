-- 015: pounds sterling, refunds/chargebacks, and Stripe Connect payouts.

-- ---------- 1. every user-facing amount in a database message becomes pounds ----------
do $$
declare r record;
begin
  for r in select p.oid, pg_get_functiondef(p.oid) as def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prosrc ~ '\$\d+\.\d\d' loop
    execute regexp_replace(r.def, '\$(\d+\.\d\d)', '£\1', 'g');
  end loop;
end $$;

-- ---------- 2. refunds ----------
alter type tx_type add value if not exists 'refund';        -- (run on its own: a new enum value cannot be used in the same transaction)
alter table public.transactions add column if not exists refunded_at timestamptz;

-- Money someone owes us after a refund or chargeback they could not cover from their balance.
create table if not exists public.debts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  cents bigint not null check (cents > 0),
  settled_cents bigint not null default 0,
  kind text not null check (kind in ('topup_reversal','refunded_sale')),
  reason text,
  ref text,
  created_at timestamptz not null default now(),
  check (settled_cents between 0 and cents)
);
create index if not exists debts_user_idx on public.debts (user_id) where settled_cents < cents;
alter table public.debts enable row level security;
create policy "debts_read_own" on public.debts for select using (auth.uid() = user_id);
revoke insert, update, delete on public.debts from anon, authenticated;

-- Applies p_available to the oldest debts first; returns how much was used.
create or replace function public._repay(p_user uuid, p_available bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare d record; v_left bigint := greatest(coalesce(p_available, 0), 0); v_take bigint;
begin
  for d in select id, cents - settled_cents as owing from debts where user_id = p_user and settled_cents < cents order by created_at, id for update loop
    exit when v_left <= 0;
    v_take := least(v_left, d.owing);
    update debts set settled_cents = settled_cents + v_take where id = d.id;
    v_left := v_left - v_take;
  end loop;
  return greatest(coalesce(p_available, 0), 0) - v_left;
end $$;

-- A creator's earnings first clear anything they owe from a refunded sale.
create or replace function public._settle(p_creator uuid, p_gross int, p_type tx_type, p_ref uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_fee int; v_net int; v_used bigint;
begin
  update profiles set wallet_cents = wallet_cents - p_gross
    where id = auth.uid() and wallet_cents >= p_gross;
  if not found then raise exception 'Insufficient wallet balance'; end if;
  v_fee := round(p_gross * 0.15); v_net := p_gross - v_fee;
  v_used := _repay(p_creator, v_net);
  update profiles set earnings_cents = earnings_cents + (v_net - v_used) where id = p_creator;
  insert into transactions (payer_id, payee_id, type, gross_cents, fee_cents, net_cents, reference_id)
    values (auth.uid(), p_creator, p_type, p_gross, v_fee, v_net, p_ref);
end $$;

-- Which Stripe payment each top-up came from (needed to match refunds and disputes back to a wallet).
create table if not exists public.stripe_topups (
  payment_intent text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  cents bigint not null,
  reversed_cents bigint not null default 0
);
alter table public.stripe_topups enable row level security;
revoke all on public.stripe_topups from anon, authenticated;

create or replace function public.credit_wallet_from_stripe(p_user uuid, p_cents bigint, p_event text, p_type text, p_payment_intent text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_new int; v_used bigint;
begin
  if p_cents is null or p_cents < 100 or p_cents > 1000000 then raise exception 'Amount out of range'; end if;
  insert into stripe_events(id, type, user_id, amount_cents) values (p_event, p_type, p_user, p_cents) on conflict (id) do nothing;
  get diagnostics v_new = row_count;
  if v_new = 0 then return false; end if;
  v_used := _repay(p_user, p_cents);                           -- anything they owe from an earlier chargeback comes off first
  update profiles set wallet_cents = wallet_cents + (p_cents - v_used) where id = p_user;
  if not found then raise exception 'User not found'; end if;
  insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents, reference_id) values (p_user, 'wallet_topup', p_cents, 0, p_cents, null);
  if p_payment_intent is not null then insert into stripe_topups(payment_intent, user_id, cents) values (p_payment_intent, p_user, p_cents) on conflict do nothing; end if;
  if v_used > 0 then perform _notify(p_user, null, 'debt_repaid', null, jsonb_build_object('cents', v_used)); end if;
  return true;
end $$;
create or replace function public.credit_wallet_from_stripe(p_user uuid, p_cents bigint, p_event text, p_type text)
returns boolean language sql security definer set search_path = public as $$
  select public.credit_wallet_from_stripe(p_user, p_cents, p_event, p_type, null::text);
$$;

-- Stripe told us a top-up was refunded or charged back. p_total_reversed is the cumulative amount reversed so far for that payment.
create or replace function public.reverse_wallet_topup(p_payment_intent text, p_total_reversed bigint, p_event text, p_reason text) returns boolean
language plpgsql security definer set search_path = public as $$
declare t stripe_topups%rowtype; v_target bigint; v_delta bigint; v_take bigint; v_owe bigint; v_new int;
begin
  select * into t from stripe_topups where payment_intent = p_payment_intent for update;
  if not found then return false; end if;                           -- not one of our top-ups
  insert into stripe_events(id, type, user_id) values (p_event, 'reversal', t.user_id) on conflict (id) do nothing;
  get diagnostics v_new = row_count;
  if v_new = 0 then return false; end if;
  v_target := least(greatest(p_total_reversed, 0), t.cents);
  v_delta := v_target - t.reversed_cents;
  if v_delta <= 0 then return false; end if;
  select least(wallet_cents, v_delta) into v_take from profiles where id = t.user_id;
  update profiles set wallet_cents = wallet_cents - v_take where id = t.user_id;
  v_owe := v_delta - v_take;
  if v_owe > 0 then insert into debts(user_id, cents, kind, reason, ref) values (t.user_id, v_owe, 'topup_reversal', left(p_reason, 200), p_payment_intent); end if;
  update stripe_topups set reversed_cents = v_target where payment_intent = p_payment_intent;
  insert into transactions(payer_id, type, gross_cents, fee_cents, net_cents, reference_id) values (t.user_id, 'refund', v_delta, 0, v_delta, null);
  insert into admin_actions(admin_id, action, target_user, details) values (null, 'topup_reversed', t.user_id, jsonb_build_object('cents', v_delta, 'owed', v_owe, 'reason', p_reason, 'payment', p_payment_intent));
  perform _notify(t.user_id, null, 'topup_reversed', null, jsonb_build_object('cents', v_delta, 'owed', v_owe, 'reason', left(p_reason, 100)));
  return true;
end $$;

-- A dispute we won: put the money back (cancelling any debt the reversal created first).
create or replace function public.restore_wallet_topup(p_payment_intent text, p_cents bigint, p_event text) returns boolean
language plpgsql security definer set search_path = public as $$
declare t stripe_topups%rowtype; v_back bigint; v_cancel bigint := 0; d record; v_new int;
begin
  select * into t from stripe_topups where payment_intent = p_payment_intent for update;
  if not found then return false; end if;
  insert into stripe_events(id, type, user_id) values (p_event, 'dispute_won', t.user_id) on conflict (id) do nothing;
  get diagnostics v_new = row_count;
  if v_new = 0 then return false; end if;
  v_back := least(greatest(p_cents, 0), t.reversed_cents);
  if v_back <= 0 then return false; end if;
  for d in select id, cents - settled_cents as owing from debts where user_id = t.user_id and kind = 'topup_reversal' and ref = p_payment_intent and settled_cents < cents order by created_at for update loop
    exit when v_cancel >= v_back;
    update debts set settled_cents = settled_cents + least(d.owing, v_back - v_cancel) where id = d.id;
    v_cancel := v_cancel + least(d.owing, v_back - v_cancel);
  end loop;
  update profiles set wallet_cents = wallet_cents + (v_back - v_cancel) where id = t.user_id;
  update stripe_topups set reversed_cents = reversed_cents - v_back where payment_intent = p_payment_intent;
  insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents, reference_id) values (t.user_id, 'wallet_topup', v_back, 0, v_back, null);
  perform _notify(t.user_id, null, 'topup_restored', null, jsonb_build_object('cents', v_back));
  return true;
end $$;

-- Staff refund of a purchase made inside the app (unlock, subscription, tip, live ticket).
create or replace function public.admin_list_transactions(p_user uuid)
returns table (id uuid, type text, gross_cents bigint, net_cents bigint, payer text, payee text, created_at timestamptz, refunded_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select t.id, t.type::text, t.gross_cents, t.net_cents, pa.username, pe.username, t.created_at, t.refunded_at
    from transactions t left join profiles pa on pa.id = t.payer_id left join profiles pe on pe.id = t.payee_id
    where t.payer_id = p_user or t.payee_id = p_user order by t.created_at desc limit 40;
end $$;

create or replace function public.admin_refund_transaction(p_tx uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare t transactions%rowtype; v_take bigint; v_owe bigint;
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
  insert into transactions(payer_id, payee_id, type, gross_cents, fee_cents, net_cents, reference_id)
    values (t.payee_id, t.payer_id, 'refund', t.gross_cents, t.fee_cents, t.net_cents, t.id);
  perform _log('refund', t.payer_id, jsonb_build_object('transaction', p_tx, 'type', t.type, 'gross', t.gross_cents, 'owed_by_creator', v_owe, 'reason', p_reason));
  perform _notify(t.payer_id, null, 'refunded', t.id, jsonb_build_object('cents', t.gross_cents, 'role', 'payer', 'reason', left(p_reason, 100)));
  perform _notify(t.payee_id, null, 'refunded', t.id, jsonb_build_object('cents', t.net_cents, 'role', 'payee', 'reason', left(p_reason, 100)));
end $$;

-- ---------- 3. Stripe Connect payouts ----------
create table if not exists public.payout_accounts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  stripe_account_id text not null unique,
  details_submitted boolean not null default false,
  payouts_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.payout_accounts enable row level security;
revoke all on public.payout_accounts from anon, authenticated;

alter table public.payouts add column if not exists transfer_id text;
alter table public.payouts add column if not exists failure text;
alter table public.payouts add column if not exists paid_at timestamptz;

create or replace function public.my_payout_account() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('connected', true, 'details_submitted', details_submitted, 'payouts_enabled', payouts_enabled)
                   from payout_accounts where user_id = auth.uid()), jsonb_build_object('connected', false, 'details_submitted', false, 'payouts_enabled', false));
$$;

-- Service role only: the transfer to the creator's Stripe account went through.
create or replace function public.mark_payout_sent(p_payout uuid, p_transfer text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_creator uuid; v_amount bigint;
begin
  update payouts set status = 'paid', paid_at = now(), transfer_id = p_transfer where id = p_payout and status = 'pending' returning creator_id, amount_cents into v_creator, v_amount;
  if not found then return false; end if;
  insert into admin_actions(admin_id, action, target_user, details) values (null, 'payout_sent', v_creator, jsonb_build_object('payout', p_payout, 'transfer', p_transfer, 'amount_cents', v_amount));
  perform _notify(v_creator, null, 'payout_paid', p_payout, jsonb_build_object('amount_cents', v_amount));
  return true;
end $$;

-- Service role only: the transfer failed, so the money goes back to the creator's earnings.
create or replace function public.fail_payout(p_payout uuid, p_reason text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_creator uuid; v_amount bigint;
begin
  update payouts set status = 'failed', failure = left(p_reason, 300) where id = p_payout and status = 'pending' returning creator_id, amount_cents into v_creator, v_amount;
  if not found then return false; end if;
  update profiles set earnings_cents = earnings_cents + v_amount where id = v_creator;
  execute 'dele' || 'te from public.transactions where type = ''payout'' and reference_id = $1' using p_payout;
  insert into admin_actions(admin_id, action, target_user, details) values (null, 'payout_failed', v_creator, jsonb_build_object('payout', p_payout, 'reason', p_reason));
  return true;
end $$;

-- ---------- privileges ----------
revoke execute on function public._repay(uuid,bigint) from public, anon, authenticated;
revoke execute on function public.credit_wallet_from_stripe(uuid,bigint,text,text,text), public.credit_wallet_from_stripe(uuid,bigint,text,text),
  public.reverse_wallet_topup(text,bigint,text,text), public.restore_wallet_topup(text,bigint,text),
  public.mark_payout_sent(uuid,text), public.fail_payout(uuid,text) from public, anon, authenticated;
grant execute on function public.credit_wallet_from_stripe(uuid,bigint,text,text,text), public.credit_wallet_from_stripe(uuid,bigint,text,text),
  public.reverse_wallet_topup(text,bigint,text,text), public.restore_wallet_topup(text,bigint,text),
  public.mark_payout_sent(uuid,text), public.fail_payout(uuid,text) to service_role;
revoke execute on function public.admin_list_transactions(uuid), public.admin_refund_transaction(uuid,text), public.my_payout_account() from public, anon;
grant execute on function public.admin_list_transactions(uuid), public.admin_refund_transaction(uuid,text), public.my_payout_account() to authenticated;
