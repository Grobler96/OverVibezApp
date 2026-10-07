-- 023: two-step login (authenticator app) for everyone, enforced for staff.
-- * Anyone can turn on two-step login (Me -> Two-step login). Supabase Auth issues an "aal2" session once the code is entered.
-- * Staff (moderators and admins) who have two-step login on can only use staff powers from an aal2 session, so a stolen
--   password alone is not enough.
-- * Admins can also REQUIRE it for all staff (Admin -> Invites -> Staff two-step): staff without it are locked out of staff powers
--   until they set it up.

insert into public.app_settings(key, value) values ('require_staff_mfa', 'false'::jsonb) on conflict (key) do nothing;

create or replace function public._mfa_ok() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select case
    when exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified')
      then coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
    else not coalesce((select (value #>> '{}')::boolean from public.app_settings where key = 'require_staff_mfa'), false)
  end
$$;

create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and staff_role is not null and not is_banned) and public._mfa_ok();
$$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and staff_role = 'admin' and not is_banned) and public._mfa_ok();
$$;

create or replace function public.admin_set_require_staff_mfa(p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  insert into app_settings(key, value) values ('require_staff_mfa', to_jsonb(p_on)) on conflict (key) do update set value = to_jsonb(p_on);
  perform _log('require_staff_mfa', null, jsonb_build_object('on', p_on));
end $$;

-- What the app needs to know about the caller's own two-step state (so it can nudge staff to set it up).
create or replace function public.my_security() returns jsonb
language sql stable security definer set search_path = public, auth as $$
  select jsonb_build_object(
    'mfa_enabled', exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'),
    'require_staff_mfa', coalesce((select (value #>> '{}')::boolean from public.app_settings where key = 'require_staff_mfa'), false));
$$;

revoke execute on function public._mfa_ok() from public, anon, authenticated;
revoke execute on function public.admin_set_require_staff_mfa(boolean), public.my_security() from public, anon;
grant execute on function public.admin_set_require_staff_mfa(boolean), public.my_security() to authenticated;
