-- 041: a way out when a confirmation email never arrives.
-- * A person stuck on "Check your email" can tap "Still nothing? Ask us to help". That records a request (without revealing whether an address has an account)
--   and tells every admin (in-app notification + push).
-- * Admins see the waiting requests at the top of Admin -> Users and can confirm the address by hand (audit-logged). Also available on any user's page.
-- Manually confirming skips the "click the link" check, so it is admin-only and logged.

create table if not exists public.email_help_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  email text not null,
  username text,
  created_at timestamptz not null default now(),
  handled_at timestamptz,
  handled_by uuid references public.profiles(id) on delete set null);
alter table public.email_help_requests enable row level security;
revoke all on public.email_help_requests from anon, authenticated;

create or replace function public.request_email_help(p_email text) returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_email text := lower(trim(coalesce(p_email, ''))); v_uid uuid; v_name text;
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then return; end if;
  if (select count(*) from email_help_requests where created_at > now() - interval '1 day') >= 200 then return; end if;
  if exists (select 1 from email_help_requests where email = v_email and created_at > now() - interval '30 minutes') then return; end if;
  select id into v_uid from auth.users where lower(email) = v_email and email_confirmed_at is null;
  if v_uid is null then return; end if;                                   -- silent: never reveal whether an address has an account
  select username into v_name from profiles where id = v_uid;
  insert into email_help_requests(user_id, email, username) values (v_uid, v_email, v_name);
  insert into notifications(user_id, actor_id, type, data)
    select p.id, null, 'email_help', jsonb_build_object('email', v_email, 'username', v_name) from profiles p where p.staff_role = 'admin' and not p.is_banned;
end $$;

create or replace function public.admin_email_help_list() returns table (id uuid, user_id uuid, email text, username text, created_at timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select r.id, r.user_id, r.email, r.username, r.created_at from email_help_requests r
   where r.handled_at is null and exists (select 1 from auth.users u where u.id = r.user_id and u.email_confirmed_at is null) order by r.created_at limit 50;
end $$;

create or replace function public.admin_confirm_email(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_email text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()) where id = p_user returning email into v_email;
  if v_email is null then raise exception 'User not found'; end if;
  update email_help_requests set handled_at = now(), handled_by = auth.uid() where user_id = p_user and handled_at is null;
  perform _log('confirm_email', p_user, jsonb_build_object('email', v_email));
end $$;

-- admins get pushed about it like any account notice
create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help') then 'account'
    else null end;
$$;

revoke execute on function public.request_email_help(text), public.admin_email_help_list(), public.admin_confirm_email(uuid) from public;
grant execute on function public.request_email_help(text) to anon, authenticated;
grant execute on function public.admin_email_help_list(), public.admin_confirm_email(uuid) to authenticated;
