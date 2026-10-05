-- Live streaming (video is carried by LiveKit; this is access control, payments, chat and moderation).
-- The LiveKit API secret never reaches the browser: the `live-token` edge function mints short-lived tokens only
-- after live_access() confirms the caller may watch/broadcast.

alter table public.live_streams add column if not exists room_name text unique default ('live_' || replace(gen_random_uuid()::text, '-', ''));
alter table public.live_streams add column if not exists last_seen_at timestamptz not null default now();   -- broadcaster heartbeat

create table if not exists public.live_tickets (
  stream_id uuid not null references public.live_streams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount_cents int not null,
  created_at timestamptz not null default now(),
  primary key (stream_id, user_id)
);
create index if not exists live_tickets_user_idx on public.live_tickets (user_id);
alter table public.live_tickets enable row level security;
create policy "live_tickets_read" on public.live_tickets for select using (auth.uid() = user_id);
revoke insert, update, delete on public.live_tickets from anon, authenticated;

create table if not exists public.live_comments (
  id uuid primary key default gen_random_uuid(),
  stream_id uuid not null references public.live_streams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (length(body) between 1 and 300),
  removed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists live_comments_stream_idx on public.live_comments (stream_id, created_at);
alter table public.live_comments enable row level security;

-- Streams are created/ended only through the functions below.
revoke insert, update on public.live_streams from anon, authenticated;

-- ---------- access helper (used by chat policies and the token function) ----------
create or replace function public.live_can_watch(p_stream uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from live_streams s
    where s.id = p_stream
      and (s.creator_id = auth.uid() or s.entry_price_cents = 0
           or exists (select 1 from live_tickets t where t.stream_id = s.id and t.user_id = auth.uid()))
  );
$$;

create policy "live_comments_read" on public.live_comments for select
  using (removed_at is null and public.live_can_watch(stream_id));
create policy "live_comments_insert" on public.live_comments for insert with check (
  auth.uid() = user_id and public.not_banned() and public.live_can_watch(stream_id)
  and exists (select 1 from live_streams s where s.id = stream_id and s.status = 'live'));
revoke update, delete on public.live_comments from anon, authenticated;

create or replace function public.rl_live_comments() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from live_comments where user_id = new.user_id and created_at > now() - interval '10 seconds') >= 8 then
    raise exception 'You are chatting too fast — slow down'; end if;
  return new; end $$;
create trigger rl_live_comments before insert on public.live_comments for each row execute function public.rl_live_comments();

-- ---------- broadcaster ----------
create or replace function public.start_live_stream(p_title text, p_price_cents int default 0) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform _require_adult();
  if not is_verified_creator() then raise exception 'Only verified creators can go live'; end if;
  if p_title is null or length(trim(p_title)) < 1 or length(p_title) > 120 then raise exception 'Give your stream a title (max 120 characters)'; end if;
  if p_price_cents is null or p_price_cents < 0 or p_price_cents > 50000 or (p_price_cents > 0 and p_price_cents < 99) then
    raise exception 'Entry price must be free or between $0.99 and $500.00'; end if;
  update live_streams set status = 'ended', ended_at = now() where creator_id = auth.uid() and status = 'live';
  insert into live_streams(creator_id, title, entry_price_cents, status) values (auth.uid(), trim(p_title), p_price_cents, 'live') returning id into v_id;
  return v_id;
end $$;

create or replace function public.live_heartbeat(p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update live_streams set last_seen_at = now() where id = p_stream and creator_id = auth.uid() and status = 'live';
  if not found then raise exception 'This stream has ended'; end if;
end $$;

create or replace function public.end_live_stream(p_stream uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype;
begin
  update live_streams set status = 'ended', ended_at = now() where id = p_stream and creator_id = auth.uid() and status = 'live' returning * into s;
  if not found then raise exception 'This stream has already ended'; end if;
  return jsonb_build_object('tickets', (select count(*) from live_tickets where stream_id = p_stream),
    'ticket_gross_cents', (select coalesce(sum(amount_cents),0) from live_tickets where stream_id = p_stream),
    'duration_seconds', extract(epoch from (s.ended_at - s.started_at))::int);
end $$;

-- ---------- viewer ----------
create or replace function public.buy_live_ticket(p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype;
begin
  perform _require_adult();
  select * into s from live_streams where id = p_stream and status = 'live';
  if not found then raise exception 'This stream is not live'; end if;
  if s.creator_id = auth.uid() then raise exception 'You cannot buy a ticket to your own stream'; end if;
  if s.entry_price_cents = 0 then raise exception 'This stream is free'; end if;
  if exists (select 1 from live_tickets where stream_id = p_stream and user_id = auth.uid()) then raise exception 'You already have a ticket'; end if;
  perform _settle(s.creator_id, s.entry_price_cents, 'live_entry', p_stream);
  insert into live_tickets(stream_id, user_id, amount_cents) values (p_stream, auth.uid(), s.entry_price_cents);
end $$;

-- Called by the live-token edge function (with the caller's own JWT). Returns what the caller may do in the room.
create or replace function public.live_access(p_stream uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype;
begin
  perform _require_adult();
  select * into s from live_streams where id = p_stream;
  if not found or s.status <> 'live' then raise exception 'This stream is not live'; end if;
  if s.creator_id = auth.uid() then
    return jsonb_build_object('room', s.room_name, 'role', 'broadcaster', 'title', s.title);
  end if;
  if s.last_seen_at < now() - interval '3 minutes' then raise exception 'This stream is not live'; end if;
  if s.entry_price_cents > 0 and not exists (select 1 from live_tickets where stream_id = p_stream and user_id = auth.uid()) then
    raise exception 'Ticket required';
  end if;
  return jsonb_build_object('room', s.room_name, 'role', 'viewer', 'title', s.title);
end $$;

-- ---------- moderation ----------
create or replace function public._target_user(p_type text, p_id uuid) returns uuid language sql stable security definer set search_path = public as $$
  select case p_type
    when 'profile' then p_id
    when 'post'    then (select creator_id from posts where id = p_id)
    when 'comment' then (select user_id from comments where id = p_id)
    when 'message' then (select sender_id from messages where id = p_id)
    when 'stream'  then (select creator_id from live_streams where id = p_id)
  end;
$$;

create or replace function public._remove(p_kind text, p_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_post uuid;
begin
  if p_kind = 'post' then
    update posts set removed_at = now(), removed_reason = left(p_reason,300) where id = p_id and removed_at is null returning creator_id into v_owner;
  elsif p_kind = 'comment' then
    update comments set removed_at = now(), removed_reason = left(p_reason,300) where id = p_id and removed_at is null returning user_id, post_id into v_owner, v_post;
    if found then update posts set comment_count = greatest(comment_count - 1, 0) where id = v_post; end if;
  elsif p_kind = 'message' then
    update messages set removed_at = now() where id = p_id and removed_at is null returning sender_id into v_owner;
  elsif p_kind = 'stream' then
    update live_streams set status = 'ended', ended_at = now() where id = p_id and status = 'live' returning creator_id into v_owner;
  else raise exception 'Unknown content type'; end if;
  if v_owner is null then raise exception 'Content not found or already removed'; end if;
  perform _log('remove_' || p_kind, v_owner, jsonb_build_object('id', p_id, 'reason', p_reason));
  return v_owner;
end $$;

create or replace function public.admin_resolve_report(p_report uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r reports%rowtype; tu uuid;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if p_action not in ('dismiss','remove_content','ban_user','remove_and_ban') then raise exception 'Unknown action'; end if;
  select * into r from reports where id = p_report;
  if not found then raise exception 'Report not found'; end if;
  tu := _target_user(r.target_type, r.target_id);
  if p_action in ('remove_content','remove_and_ban') then
    if r.target_type not in ('post','comment','message','stream') then raise exception 'Nothing to remove for a % report', r.target_type; end if;
    perform _remove(r.target_type, r.target_id, coalesce(p_note, r.reason));
  end if;
  if p_action in ('ban_user','remove_and_ban') then
    if tu is null then raise exception 'Target user no longer exists'; end if;
    perform _ban(tu, true, coalesce(p_note, r.reason));
  end if;
  update reports set status = case when p_action = 'dismiss' then 'dismissed'::report_status else 'actioned'::report_status end,
         resolved_by = auth.uid(), resolved_at = now(), admin_note = left(p_note, 500) where id = p_report;
  perform _log('report:' || p_action, tu, jsonb_build_object('report', p_report, 'type', r.target_type, 'target', r.target_id, 'note', p_note));
end $$;

create or replace function public.admin_list_live()
returns table (id uuid, creator_id uuid, creator_username text, title text, entry_price_cents int, started_at timestamptz, last_seen_at timestamptz, tickets bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  return query select s.id, s.creator_id, p.username, s.title, s.entry_price_cents, s.started_at, s.last_seen_at,
                      (select count(*) from live_tickets t where t.stream_id = s.id)
    from live_streams s join profiles p on p.id = s.creator_id where s.status = 'live' order by s.started_at desc limit 50;
end $$;

create or replace function public.admin_end_live_stream(p_stream uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  perform _remove('stream', p_stream, p_reason);
end $$;

-- ---------- privileges ----------
revoke execute on function public.live_can_watch(uuid), public.start_live_stream(text,int), public.live_heartbeat(uuid),
  public.end_live_stream(uuid), public.buy_live_ticket(uuid), public.live_access(uuid), public.admin_list_live(),
  public.admin_end_live_stream(uuid,text) from public, anon;
grant execute on function public.live_can_watch(uuid), public.start_live_stream(text,int), public.live_heartbeat(uuid),
  public.end_live_stream(uuid), public.buy_live_ticket(uuid), public.live_access(uuid), public.admin_list_live(),
  public.admin_end_live_stream(uuid,text) to authenticated;

alter publication supabase_realtime add table public.live_comments;

-- Trigger functions never need to be callable through the API.
revoke execute on function public.rl_comments(), public.rl_messages(), public.rl_reports(), public.rl_posts(), public.rl_live_comments() from public, anon, authenticated;
