-- 027: one-time welcome animation for new creators.
-- `intro_seen` remembers (per account, on every device) whether the creator has already been shown it.
-- Everyone who already has an account is marked as having seen it, so only brand-new accounts get the welcome.

alter table public.profiles add column if not exists intro_seen boolean not null default false;
update public.profiles set intro_seen = true where not intro_seen;

create or replace function public.mark_intro_seen() returns void
language sql security definer set search_path = public as $$
  update profiles set intro_seen = true where id = auth.uid();
$$;

-- The app already reads this after login, so the flag rides along with it.
create or replace function public.my_security() returns jsonb
language sql stable security definer set search_path = public, auth as $$
  select jsonb_build_object(
    'mfa_enabled', exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'),
    'require_staff_mfa', coalesce((select (value #>> '{}')::boolean from public.app_settings where key = 'require_staff_mfa'), false),
    'intro_seen', coalesce((select intro_seen from public.profiles where id = auth.uid()), true));
$$;

revoke execute on function public.mark_intro_seen() from public, anon;
grant execute on function public.mark_intro_seen() to authenticated;
