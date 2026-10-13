-- 043: a follower can convert their account to a creator account (one way; staff can change it back).
-- Sets exactly what a creator sign-up sets (account_type, default subscription price) and clears intro_seen so the welcome tour plays
-- on their next load. Everything else on the account (followers, subscriptions, wallet, history) is kept. Posting still needs the 18+ check.
create or replace function public.become_creator() returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); p profiles%rowtype;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  select * into p from profiles where id = v_uid for update;
  if not found then raise exception 'No profile'; end if;
  if p.is_banned then raise exception 'This account cannot be changed'; end if;
  if p.account_type = 'creator' then return; end if;
  update profiles set account_type = 'creator', sub_price_cents = coalesce(sub_price_cents, 499), intro_seen = false where id = v_uid;
  perform _log('become_creator', v_uid, '{}'::jsonb);
end $$;
revoke execute on function public.become_creator() from public, anon;
grant execute on function public.become_creator() to authenticated;
