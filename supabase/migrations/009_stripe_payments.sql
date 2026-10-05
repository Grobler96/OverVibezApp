-- Stripe: wallet top-ups (Checkout) and age verification (Stripe Identity).
-- Money/verification are only ever applied by the stripe-webhook edge function after it has verified Stripe's signature,
-- through functions callable ONLY by the service role (never by browsers).

create table if not exists public.stripe_events (
  id text primary key,                 -- Checkout session id / verification session id: guarantees each payment is applied once
  type text not null,
  user_id uuid,
  amount_cents bigint,
  created_at timestamptz not null default now()
);
alter table public.stripe_events enable row level security;      -- no policies: only service-role code touches it
revoke all on public.stripe_events from anon, authenticated;

-- Browser-callable gate used by the create-topup / create-verification functions (runs with the caller's own login).
create or replace function public.can_topup() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_adult();     -- signed in, not banned, 18+ verified
end $$;

create or replace function public.can_start_verification() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from profiles where id = auth.uid() and is_banned) then raise exception 'Account suspended'; end if;
  if exists (select 1 from profiles where id = auth.uid() and age_verified) then raise exception 'You are already verified'; end if;
end $$;

-- Service-role only: credit a verified, paid Checkout session exactly once.
create or replace function public.credit_wallet_from_stripe(p_user uuid, p_cents bigint, p_event text, p_type text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_new int;
begin
  if p_cents is null or p_cents < 100 or p_cents > 1000000 then raise exception 'Amount out of range'; end if;
  insert into stripe_events(id, type, user_id, amount_cents) values (p_event, p_type, p_user, p_cents) on conflict (id) do nothing;
  get diagnostics v_new = row_count;
  if v_new = 0 then return false; end if;                              -- already applied
  update profiles set wallet_cents = wallet_cents + p_cents where id = p_user;
  if not found then raise exception 'User not found'; end if;          -- rolls back the event row too
  insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents) values (p_user, 'wallet_topup', p_cents, 0, p_cents);
  return true;
end $$;

-- Service-role only: record the outcome of an ID/age check from the provider.
create or replace function public.set_age_verified_from_provider(p_user uuid, p_event text, p_ok boolean, p_note text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_new int;
begin
  insert into stripe_events(id, type, user_id) values (p_event, 'identity', p_user) on conflict (id) do nothing;
  get diagnostics v_new = row_count;
  if v_new = 0 then return false; end if;
  if p_ok then update profiles set age_verified = true where id = p_user; end if;
  insert into admin_actions(admin_id, action, target_user, details)
    values (null, case when p_ok then 'age_verified_by_provider' else 'age_check_failed' end, p_user, jsonb_build_object('session', p_event, 'note', p_note));
  return true;
end $$;

revoke execute on function public.can_topup(), public.can_start_verification() from public, anon;
grant execute on function public.can_topup(), public.can_start_verification() to authenticated;

revoke execute on function public.credit_wallet_from_stripe(uuid,bigint,text,text), public.set_age_verified_from_provider(uuid,text,boolean,text) from public, anon, authenticated;
grant execute on function public.credit_wallet_from_stripe(uuid,bigint,text,text), public.set_age_verified_from_provider(uuid,text,boolean,text) to service_role;
