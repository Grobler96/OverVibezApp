-- 025: manual 18+ checks.
-- Stripe Identity charges per check, so by default the ID check is done by hand: a member asks for a check, an admin looks at
-- their ID OUTSIDE the app (a photo of the member holding their ID, emailed to support and deleted straight after), then approves or rejects
-- here. The app stores only the result and a short note — never an image of the ID. An admin can switch back to Stripe
-- Identity later with admin_set_id_check_mode('stripe').

insert into public.app_settings(key, value) values ('id_check', to_jsonb('manual'::text)) on conflict (key) do nothing;

create or replace function public._id_check_mode() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select value #>> '{}' from app_settings where key = 'id_check'), 'manual')
$$;

create table if not exists public.age_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  note text,                                   -- what the member wrote (e.g. best time to reply)
  review_note text,                            -- what the admin recorded (e.g. "photo holding passport checked, over 18")
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists age_requests_one_pending on public.age_requests (user_id) where status = 'pending';
create index if not exists age_requests_status_idx on public.age_requests (status, created_at);
create index if not exists age_requests_reviewed_by_fk on public.age_requests (reviewed_by);
alter table public.age_requests enable row level security;        -- no policies: only the functions below touch it
revoke all on public.age_requests from anon, authenticated;

-- Stripe's paid ID check can only be started while the setting says "stripe".
create or replace function public.can_start_verification() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from profiles where id = auth.uid() and is_banned) then raise exception 'Account suspended'; end if;
  if exists (select 1 from profiles where id = auth.uid() and age_verified) then raise exception 'You are already verified'; end if;
  if _id_check_mode() <> 'stripe' then raise exception 'Automatic ID checks are switched off — please request a manual check'; end if;
end $$;

create or replace function public.public_settings() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('invite_only', coalesce((select (value #>> '{}')::boolean from app_settings where key = 'invite_only'), true),
                            'support_email', (select value #>> '{}' from app_settings where key = 'support_email'),
                            'paid_raffles', public._paid_raffles_on(),
                            'id_check', public._id_check_mode());
$$;

-- ---------- member side ----------
create or replace function public.request_age_check(p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from profiles where id = auth.uid() and is_banned) then raise exception 'Account suspended'; end if;
  if exists (select 1 from profiles where id = auth.uid() and age_verified) then raise exception 'You are already verified'; end if;
  if exists (select 1 from age_requests where user_id = auth.uid() and status = 'pending') then raise exception 'You already have a request waiting — we will be in touch'; end if;
  if (select count(*) from age_requests where user_id = auth.uid() and created_at > now() - interval '1 day') >= 3 then raise exception 'Too many requests today — please try again tomorrow'; end if;
  insert into age_requests(user_id, note) values (auth.uid(), nullif(left(trim(coalesce(p_note, '')), 300), '')) returning id into v_id;
  return v_id;
end $$;

create or replace function public.my_age_request() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('status', status, 'note', review_note, 'created_at', created_at)
                   from age_requests where user_id = auth.uid() order by created_at desc limit 1), '{}'::jsonb)
$$;

-- ---------- admin side ----------
create or replace function public.admin_list_age_requests(p_status text default 'pending')
returns table (id uuid, user_id uuid, username text, display_name text, email text, account_type text, note text, status text, review_note text, created_at timestamptz, reviewed_at timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query
    select r.id, r.user_id, p.username, p.display_name, u.email::text, p.account_type::text, r.note, r.status, r.review_note, r.created_at, r.reviewed_at
    from age_requests r join profiles p on p.id = r.user_id left join auth.users u on u.id = r.user_id
    where r.status = coalesce(p_status, 'pending') order by r.created_at desc limit 100;
end $$;

-- Approve or reject. The note is required: write what you checked (e.g. "photo holding passport checked, over 18"). No ID copies are kept here.
create or replace function public.admin_review_age_request(p_id uuid, p_approve boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare r age_requests%rowtype;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_note is null or length(trim(p_note)) < 3 then raise exception 'Write a short note of what you checked'; end if;
  select * into r from age_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if r.status <> 'pending' then raise exception 'This request was already reviewed'; end if;
  update age_requests set status = case when p_approve then 'approved' else 'rejected' end, review_note = left(trim(p_note), 300),
         reviewed_by = auth.uid(), reviewed_at = now() where id = p_id;
  if p_approve then update profiles set age_verified = true where id = r.user_id; end if;
  insert into notifications(user_id, actor_id, type, ref_id, data)
    values (r.user_id, null, case when p_approve then 'age_approved' else 'age_rejected' end, null,
            jsonb_build_object('note', case when p_approve then null else left(trim(p_note), 200) end));
  perform _log('age_manual', r.user_id, jsonb_build_object('approved', p_approve, 'note', left(trim(p_note), 300), 'request', p_id));
end $$;

create or replace function public.admin_set_id_check_mode(p_mode text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_mode not in ('manual','stripe') then raise exception 'Mode must be manual or stripe'; end if;
  insert into app_settings(key, value) values ('id_check', to_jsonb(p_mode)) on conflict (key) do update set value = to_jsonb(p_mode);
  perform _log('id_check_mode', null, jsonb_build_object('mode', p_mode));
end $$;

-- ---------- privileges ----------
revoke execute on function public._id_check_mode() from public, anon, authenticated;
revoke execute on function public.request_age_check(text), public.my_age_request(), public.admin_list_age_requests(text),
  public.admin_review_age_request(uuid,boolean,text), public.admin_set_id_check_mode(text) from public, anon;
grant execute on function public.request_age_check(text), public.my_age_request(), public.admin_list_age_requests(text),
  public.admin_review_age_request(uuid,boolean,text), public.admin_set_id_check_mode(text) to authenticated;
