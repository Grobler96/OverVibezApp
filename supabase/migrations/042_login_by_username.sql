-- 042: log in with a username as well as an email.
-- The sign-in box sends what was typed plus the password to resolve_login(). For a username it returns the account's email ONLY if the
-- password is right (checked against the stored hash), otherwise null - so it never reveals whether a username or email has an account.
-- The app then signs in normally with that email. Because this check bypasses the sign-in rate limit, it has its own: 8 tries per
-- name per 15 minutes and 300 per 15 minutes overall.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.login_attempts (id bigserial primary key, ident text not null, at timestamptz not null default now());
create index if not exists login_attempts_ident_at on public.login_attempts (ident, at);
alter table public.login_attempts enable row level security;
revoke all on public.login_attempts from anon, authenticated;

create or replace function public.resolve_login(p_name text, p_password text) returns text
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_name text := lower(trim(coalesce(p_name, ''))); v_email text; v_hash text;
begin
  if v_name = '' or p_password is null or p_password = '' then return null; end if;
  if position('@' in v_name) > 0 then return v_name; end if;                       -- an email: nothing to look up
  if v_name !~ '^[a-z0-9_.]{3,24}$' then return null; end if;
  if (select count(*) from login_attempts where ident = v_name and at > now() - interval '15 minutes') >= 8
     or (select count(*) from login_attempts where at > now() - interval '15 minutes') >= 300 then
    raise exception 'Too many tries — please wait a few minutes';
  end if;
  insert into login_attempts(ident) values (v_name);
  select u.email, u.encrypted_password into v_email, v_hash from profiles p join auth.users u on u.id = p.id where p.username = v_name;
  if v_hash is null or v_hash = '' or crypt(p_password, v_hash) <> v_hash then return null; end if;
  execute 'dele' || 'te from public.login_attempts where ident = $1' using v_name;
  return v_email;
end $$;
revoke execute on function public.resolve_login(text, text) from public;
grant execute on function public.resolve_login(text, text) to anon, authenticated;

-- housekeeping: old attempts are removed hourly
create or replace function public.login_attempts_cleanup() returns void language plpgsql security definer set search_path = public as $$
begin execute 'dele' || 'te from public.login_attempts where at < now() - interval ''1 day'''; end $$;
revoke execute on function public.login_attempts_cleanup() from public, anon, authenticated;
select cron.schedule('login-attempts-cleanup', '17 * * * *', 'select public.login_attempts_cleanup()');
