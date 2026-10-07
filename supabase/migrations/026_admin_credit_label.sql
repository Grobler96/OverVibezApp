-- 026: admin wallet credits get their own label and the right currency in the error message.
-- A credit is free money added by an admin (no payment behind it), so it must not look like a paid top-up in history.
-- NOTE: the enum value must be added on its own, before anything uses it (apply this first statement separately).

alter type public.tx_type add value if not exists 'admin_credit';

create or replace function public.admin_credit_wallet(p_user uuid, p_cents int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_cents is null or p_cents < 1 or p_cents > 100000 then raise exception 'Amount must be between £0.01 and £1,000.00'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  update profiles set wallet_cents = wallet_cents + p_cents where id = p_user;
  if not found then raise exception 'User not found'; end if;
  insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents) values (p_user, 'admin_credit', p_cents, 0, p_cents);
  perform _log('credit_wallet', p_user, jsonb_build_object('cents', p_cents, 'reason', p_reason));
end $$;
