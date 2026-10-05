-- 010: invite-only beta, profile pictures, data export and account deletion checks.

-- ---------- profile pictures ----------
-- avatar_url / cover_url store a PATH in the public-media bucket and may only point into the user's own folder
-- (so a profile can never be made to load an external tracking URL).
alter table public.profiles add column if not exists cover_url text;
alter table public.profiles add constraint profiles_avatar_own_path check (avatar_url is null or (length(avatar_url) <= 200 and avatar_url like id::text || '/%'));
alter table public.profiles add constraint profiles_cover_own_path  check (cover_url  is null or (length(cover_url)  <= 200 and cover_url  like id::text || '/%'));
grant select (cover_url) on public.profiles to anon, authenticated;
grant update (cover_url) on public.profiles to authenticated;

-- ---------- invite-only beta ----------
create table if not exists public.app_settings (key text primary key, value jsonb not null);
alter table public.app_settings enable row level security;          -- no policies: only SECURITY DEFINER code
revoke all on public.app_settings from anon, authenticated;
insert into public.app_settings(key, value) values ('invite_only', 'true'::jsonb) on conflict (key) do nothing;

create table if not exists public.invite_codes (
  code text primary key,
  note text,
  max_uses int not null default 1 check (max_uses between 1 and 1000),
  uses int not null default 0,
  active boolean not null default true,
  expires_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.invite_redemptions (
  code text not null references public.invite_codes(code) on delete cascade,
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.invite_codes enable row level security;
alter table public.invite_redemptions enable row level security;
revoke all on public.invite_codes, public.invite_redemptions from anon, authenticated;

-- Sign-up is enforced HERE (server side): without a valid code nobody can create an account, whatever the browser does.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_type account_type := coalesce((new.raw_user_meta_data->>'account_type')::account_type, 'follower');
  v_code text := upper(trim(coalesce(new.raw_user_meta_data->>'invite_code', '')));
  v_only boolean := coalesce((select (value #>> '{}')::boolean from app_settings where key = 'invite_only'), true);
begin
  if v_only then
    update invite_codes set uses = uses + 1
      where code = v_code and active and uses < max_uses and (expires_at is null or expires_at > now());
    if not found then raise exception 'Invalid or used invite code'; end if;
  end if;
  insert into public.profiles (id, username, display_name, account_type, sub_price_cents)
  values (new.id,
    coalesce(new.raw_user_meta_data->>'username', 'user_' || left(new.id::text, 8)),
    coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'username'),
    v_type, case when v_type = 'creator' then 499 end);
  if v_only then insert into invite_redemptions(code, user_id) values (v_code, new.id); end if;
  return new;
end $$;

create or replace function public.public_settings() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('invite_only', coalesce((select (value #>> '{}')::boolean from app_settings where key = 'invite_only'), true));
$$;
create or replace function public.check_invite(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from invite_codes where code = upper(trim(coalesce(p_code, ''))) and active and uses < max_uses and (expires_at is null or expires_at > now()));
$$;

create or replace function public.admin_set_invite_only(p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  insert into app_settings(key, value) values ('invite_only', to_jsonb(p_on)) on conflict (key) do update set value = to_jsonb(p_on);
  perform _log('invite_only', null, jsonb_build_object('on', p_on));
end $$;

create or replace function public.admin_create_invite(p_note text, p_max_uses int default 1, p_days int default null) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_code text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_max_uses is null or p_max_uses < 1 or p_max_uses > 1000 then raise exception 'Uses must be 1–1000'; end if;
  v_code := upper(encode(gen_random_bytes(8), 'hex'));
  v_code := 'VIBE-' || substr(v_code,1,4) || '-' || substr(v_code,5,4) || '-' || substr(v_code,9,4) || '-' || substr(v_code,13,4);
  insert into invite_codes(code, note, max_uses, expires_at, created_by)
    values (v_code, left(p_note, 100), p_max_uses, case when p_days is not null then now() + make_interval(days => p_days) end, auth.uid());
  perform _log('invite_create', null, jsonb_build_object('code', v_code, 'note', p_note, 'max_uses', p_max_uses));
  return v_code;
end $$;

create or replace function public.admin_list_invites()
returns table (code text, note text, uses int, max_uses int, active boolean, expires_at timestamptz, created_at timestamptz, redeemed_by text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select c.code, c.note, c.uses, c.max_uses, c.active, c.expires_at, c.created_at,
    (select string_agg(p.username, ', ') from invite_redemptions r join profiles p on p.id = r.user_id where r.code = c.code)
    from invite_codes c order by c.created_at desc limit 100;
end $$;

create or replace function public.admin_revoke_invite(p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update invite_codes set active = false where code = upper(trim(p_code));
  if not found then raise exception 'Code not found'; end if;
  perform _log('invite_revoke', null, jsonb_build_object('code', p_code));
end $$;

-- ---------- account: export + deletion checks ----------
create or replace function public.export_my_data() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not signed in'; end if;
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) - 'staff_role' from profiles p where p.id = me),
    'posts', coalesce((select jsonb_agg(to_jsonb(x)) from posts x where x.creator_id = me), '[]'),
    'comments', coalesce((select jsonb_agg(to_jsonb(x)) from comments x where x.user_id = me), '[]'),
    'messages', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from messages m join conversations c on c.id = m.conversation_id
                          where me in (c.user_a, c.user_b) and m.removed_at is null), '[]'),
    'likes', coalesce((select jsonb_agg(to_jsonb(x)) from likes x where x.user_id = me), '[]'),
    'follows', coalesce((select jsonb_agg(to_jsonb(x)) from follows x where me in (x.follower_id, x.creator_id)), '[]'),
    'subscriptions', coalesce((select jsonb_agg(to_jsonb(x)) from subscriptions x where me in (x.subscriber_id, x.creator_id)), '[]'),
    'unlocks', coalesce((select jsonb_agg(to_jsonb(x)) from post_unlocks x where x.user_id = me), '[]'),
    'transactions', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from transactions x where me in (x.payer_id, x.payee_id)), '[]'),
    'payouts', coalesce((select jsonb_agg(to_jsonb(x)) from payouts x where x.creator_id = me), '[]'),
    'reports_filed', coalesce((select jsonb_agg(to_jsonb(x)) from reports x where x.reporter_id = me), '[]'),
    'live_tickets', coalesce((select jsonb_agg(to_jsonb(x)) from live_tickets x where x.user_id = me), '[]'),
    'live_comments', coalesce((select jsonb_agg(to_jsonb(x)) from live_comments x where x.user_id = me), '[]'));
end $$;

create or replace function public.can_delete_account() returns void
language plpgsql security definer set search_path = public as $$
declare p profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into p from profiles where id = auth.uid();
  if not found then raise exception 'Account not found'; end if;
  if p.wallet_cents > 0 then raise exception 'Your wallet still holds % — spend it or contact support for a refund before deleting your account', '$' || to_char(p.wallet_cents / 100.0, 'FM999990.00'); end if;
  if p.earnings_cents > 0 or exists (select 1 from payouts where creator_id = p.id and status = 'pending') then
    raise exception 'You still have creator earnings or a pending payout — request a payout and wait for it to be paid first'; end if;
  if p.staff_role = 'admin' and (select count(*) from profiles where staff_role = 'admin' and not is_banned) <= 1 then
    raise exception 'You are the only admin — make someone else an admin first'; end if;
  update live_streams set status = 'ended', ended_at = now() where creator_id = p.id and status = 'live';
end $$;

-- ---------- privileges ----------
revoke execute on function public.public_settings(), public.check_invite(text) from public;
grant execute on function public.public_settings(), public.check_invite(text) to anon, authenticated;
revoke execute on function public.admin_set_invite_only(boolean), public.admin_create_invite(text,int,int), public.admin_list_invites(),
  public.admin_revoke_invite(text), public.export_my_data(), public.can_delete_account() from public, anon;
grant execute on function public.admin_set_invite_only(boolean), public.admin_create_invite(text,int,int), public.admin_list_invites(),
  public.admin_revoke_invite(text), public.export_my_data(), public.can_delete_account() to authenticated;

-- Users can list/remove their own files in the public bucket (needed to tidy replaced avatars). Public URLs are unaffected.
create policy "public_media_read_own_folder" on storage.objects for select to authenticated
  using (bucket_id = 'public-media' and (storage.foldername(name))[1] = auth.uid()::text);
