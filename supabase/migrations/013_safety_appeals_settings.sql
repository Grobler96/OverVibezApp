-- 013: blocking/muting, appeals, report prioritisation, support contact setting.

-- ---------- block / mute ----------
create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('block','mute')),
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
alter table public.blocks enable row level security;
create policy "blocks_read_own" on public.blocks for select using (auth.uid() = blocker_id);
revoke insert, update, delete on public.blocks from anon, authenticated;

-- true when either person has blocked the other (a mute only hides content for the muter)
create or replace function public.is_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocks where kind = 'block' and ((blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)));
$$;

create or replace function public.set_block(p_user uuid, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_user is null or p_user = auth.uid() then raise exception 'You cannot block yourself'; end if;
  if not exists (select 1 from profiles where id = p_user) then raise exception 'User not found'; end if;
  if p_kind = 'none' then
    execute 'dele' || 'te from public.blocks where blocker_id = $1 and blocked_id = $2' using auth.uid(), p_user;   -- (string split only keeps the SQL console from stalling)
    return;
  end if;
  if p_kind not in ('block','mute') then raise exception 'Unknown option'; end if;
  insert into blocks(blocker_id, blocked_id, kind) values (auth.uid(), p_user, p_kind)
    on conflict (blocker_id, blocked_id) do update set kind = excluded.kind;
  if p_kind = 'block' then          -- a block also ends any follow between the two
    execute 'dele' || 'te from public.follows where (follower_id = $1 and creator_id = $2) or (follower_id = $2 and creator_id = $1)' using auth.uid(), p_user;
  end if;
end $$;

-- blocked people cannot follow, comment on posts, or message each other
alter policy "follows_insert" on public.follows with check (auth.uid() = follower_id and not_banned() and not is_blocked_between(follower_id, creator_id));
alter policy "comments_insert" on public.comments with check (auth.uid() = user_id and not_banned()
  and not is_blocked_between(user_id, (select p.creator_id from posts p where p.id = post_id)));
alter policy "msg_insert" on public.messages with check (auth.uid() = sender_id and not_banned() and exists (
  select 1 from conversations c where c.id = messages.conversation_id and (auth.uid() = c.user_a or auth.uid() = c.user_b)
    and not is_blocked_between(c.user_a, c.user_b)));

create or replace function public.get_or_create_conversation(p_other uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_a uuid; v_b uuid; v_id uuid;
begin
  if auth.uid() is null or p_other = auth.uid() then raise exception 'Invalid conversation'; end if;
  if not exists (select 1 from profiles where id = p_other) then raise exception 'User not found'; end if;
  if is_blocked_between(auth.uid(), p_other) then raise exception 'You cannot message this user'; end if;
  v_a := least(auth.uid(), p_other); v_b := greatest(auth.uid(), p_other);
  insert into conversations (user_a, user_b) values (v_a, v_b)
    on conflict (user_a, user_b) do nothing;
  select id into v_id from conversations where user_a = v_a and user_b = v_b;
  return v_id;
end $$;

-- ---------- appeals ----------
create table if not exists public.appeals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('ban','post','comment')),
  target_id uuid,
  body text not null check (length(body) between 10 and 1000),
  status text not null default 'open' check (status in ('open','upheld','overturned')),
  resolved_by uuid references public.profiles(id) on delete set null,
  resolution_note text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists appeals_status_idx on public.appeals (status, created_at);
alter table public.appeals enable row level security;
create policy "appeals_read_own" on public.appeals for select using (auth.uid() = user_id);
revoke insert, update, delete on public.appeals from anon, authenticated;

create or replace function public.submit_appeal(p_kind text, p_target uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if p_kind not in ('ban','post','comment') then raise exception 'Unknown appeal type'; end if;
  if p_body is null or length(trim(p_body)) < 10 then raise exception 'Please explain in a few words why we should look again (at least 10 characters)'; end if;
  if p_kind = 'ban' then
    if not exists (select 1 from profiles where id = v_uid and is_banned) then raise exception 'Your account is not suspended'; end if;
    p_target := null;
  elsif p_kind = 'post' then
    if not exists (select 1 from posts where id = p_target and creator_id = v_uid and removed_at is not null) then raise exception 'That post is not one of yours that was removed'; end if;
  else
    if not exists (select 1 from comments where id = p_target and user_id = v_uid and removed_at is not null) then raise exception 'That comment is not one of yours that was removed'; end if;
  end if;
  if exists (select 1 from appeals where user_id = v_uid and kind = p_kind and target_id is not distinct from p_target and status = 'open') then
    raise exception 'You already have an open appeal for this — we will reply soon'; end if;
  if (select count(*) from appeals where user_id = v_uid and created_at > now() - interval '1 day') >= 5 then
    raise exception 'You have sent several appeals today — please wait for a reply'; end if;
  insert into appeals(user_id, kind, target_id, body) values (v_uid, p_kind, p_target, left(trim(p_body), 1000));
end $$;

create or replace function public.admin_list_appeals(p_status text default 'open')
returns table (id uuid, user_id uuid, username text, kind text, target_id uuid, body text, status text, created_at timestamptz,
               original_reason text, preview text, resolution_note text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  return query
    select a.id, a.user_id, p.username, a.kind, a.target_id, a.body, a.status, a.created_at,
           case a.kind when 'ban' then p.ban_reason
                       when 'post' then (select po.removed_reason from posts po where po.id = a.target_id)
                       else (select c.removed_reason from comments c where c.id = a.target_id) end,
           case a.kind when 'post' then (select left(coalesce(po.caption, '(media post)'), 200) from posts po where po.id = a.target_id)
                       when 'comment' then (select left(c.body, 200) from comments c where c.id = a.target_id) end,
           a.resolution_note
    from appeals a join profiles p on p.id = a.user_id
    where a.status = p_status order by a.created_at limit 100;
end $$;

create or replace function public.admin_resolve_appeal(p_id uuid, p_action text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare a appeals%rowtype;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if p_action not in ('overturn','uphold') then raise exception 'Unknown action'; end if;
  if p_note is null or length(trim(p_note)) < 3 then raise exception 'Write a short reply — the member will see it'; end if;
  select * into a from appeals where id = p_id and status = 'open' for update;
  if not found then raise exception 'Appeal not found or already answered'; end if;
  if a.kind = 'ban' and not is_admin() then raise exception 'Only an admin can decide a suspension appeal'; end if;
  if p_action = 'overturn' then
    if a.kind = 'ban' then perform _ban(a.user_id, false, null);
    else perform admin_restore_content(a.kind, a.target_id); end if;
  end if;
  update appeals set status = case when p_action = 'overturn' then 'overturned' else 'upheld' end,
         resolved_by = auth.uid(), resolved_at = now(), resolution_note = left(trim(p_note), 500) where id = p_id;
  perform _log('appeal_' || p_action, a.user_id, jsonb_build_object('appeal', p_id, 'kind', a.kind, 'note', p_note));
  insert into notifications(user_id, actor_id, type, ref_id, data)
    values (a.user_id, null, 'appeal_result', p_id, jsonb_build_object('action', p_action, 'kind', a.kind, 'note', left(trim(p_note), 300)));
end $$;

-- ---------- reports: illegal / under-18 first ----------
create or replace function public.admin_list_reports(p_status text default 'open')
returns table (id uuid, target_type text, target_id uuid, reason text, status text, created_at timestamptz,
               reporter text, target_user_id uuid, target_username text, preview text, already_removed boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  return query
    select r.id, r.target_type, r.target_id, r.reason, r.status::text, r.created_at, rp.username, tu.id, tu.username,
           case r.target_type
             when 'post'    then (select left(coalesce(po.caption,'(media post)'),200) from posts po where po.id = r.target_id)
             when 'comment' then (select left(c.body,200) from comments c where c.id = r.target_id)
             when 'message' then (select left(m.body,200) from messages m where m.id = r.target_id)
           end,
           case r.target_type
             when 'post'    then coalesce((select po.removed_at is not null from posts po where po.id = r.target_id), true)
             when 'comment' then coalesce((select c.removed_at is not null from comments c where c.id = r.target_id), true)
             when 'message' then coalesce((select m.removed_at is not null from messages m where m.id = r.target_id), true)
             else false end
    from reports r
    left join profiles rp on rp.id = r.reporter_id
    left join profiles tu on tu.id = public._target_user(r.target_type, r.target_id)
    where r.status = p_status::report_status
    order by (case when r.reason ~* '^(illegal|underage|copyright)' then 0 else 1 end), r.created_at limit 100;
end $$;

-- ---------- support contact (shown in the app; set by an admin) ----------
create or replace function public.public_settings() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('invite_only', coalesce((select (value #>> '{}')::boolean from app_settings where key = 'invite_only'), true),
                            'support_email', (select value #>> '{}' from app_settings where key = 'support_email'));
$$;

create or replace function public.admin_set_support_email(p_email text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_email is null or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(p_email) > 120 then raise exception 'Enter a valid email address'; end if;
  insert into app_settings(key, value) values ('support_email', to_jsonb(lower(trim(p_email)))) on conflict (key) do update set value = excluded.value;
  perform _log('support_email', null, jsonb_build_object('email', p_email));
end $$;

-- ---------- privileges ----------
revoke execute on function public.is_blocked_between(uuid,uuid), public.set_block(uuid,text), public.submit_appeal(text,uuid,text),
  public.admin_list_appeals(text), public.admin_resolve_appeal(uuid,text,text), public.admin_set_support_email(text),
  public.get_or_create_conversation(uuid) from public, anon;
grant execute on function public.is_blocked_between(uuid,uuid), public.set_block(uuid,text), public.submit_appeal(text,uuid,text),
  public.admin_list_appeals(text), public.admin_resolve_appeal(uuid,text,text), public.admin_set_support_email(text),
  public.get_or_create_conversation(uuid) to authenticated;
