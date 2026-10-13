-- 044: "Report a problem or idea" from any account. Admins read them in Admin -> Feedback and tell the sender they've been handled.
create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  kind text not null check (kind in ('bug','idea','other')),
  message text not null check (length(message) between 5 and 2000),
  page text, ua text,
  created_at timestamptz not null default now(),
  handled_at timestamptz, handled_by uuid);
create index if not exists feedback_open on public.feedback (created_at desc) where handled_at is null;
alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;

create or replace function public.send_feedback(p_kind text, p_message text, p_page text default null, p_ua text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_msg text := trim(coalesce(p_message, '')); v_name text;
begin
  if v_uid is null then raise exception 'Please log in first'; end if;
  if p_kind not in ('bug','idea','other') then raise exception 'Pick what this is about'; end if;
  if length(v_msg) < 5 then raise exception 'Please tell us a little more'; end if;
  if length(v_msg) > 2000 then raise exception 'That is too long — please keep it under 2000 characters'; end if;
  if (select count(*) from feedback where user_id = v_uid and created_at > now() - interval '1 day') >= 10 then raise exception 'You have sent a lot today — we will get back to you soon'; end if;
  insert into feedback(user_id, kind, message, page, ua) values (v_uid, p_kind, v_msg, left(p_page, 120), left(p_ua, 200));
  select username into v_name from profiles where id = v_uid;
  insert into notifications(user_id, actor_id, type, data)
    select p.id, v_uid, 'feedback', jsonb_build_object('kind', p_kind, 'username', v_name) from profiles p where p.staff_role = 'admin' and not p.is_banned;
end $$;

create or replace function public.admin_list_feedback(p_status text default 'open') returns table (id uuid, username text, kind text, message text, page text, ua text, created_at timestamptz, handled_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select f.id, p.username, f.kind, f.message, f.page, f.ua, f.created_at, f.handled_at from feedback f left join profiles p on p.id = f.user_id
    where (p_status = 'all' or (p_status = 'open' and f.handled_at is null) or (p_status = 'done' and f.handled_at is not null)) order by f.created_at desc limit 100;
end $$;

create or replace function public.admin_handle_feedback(p_id uuid, p_done boolean default true) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update feedback set handled_at = case when p_done then now() end, handled_by = case when p_done then auth.uid() end where id = p_id;
end $$;

revoke execute on function public.send_feedback(text, text, text, text), public.admin_list_feedback(text), public.admin_handle_feedback(uuid, boolean) from public, anon;
grant execute on function public.send_feedback(text, text, text, text), public.admin_list_feedback(text), public.admin_handle_feedback(uuid, boolean) to authenticated;
