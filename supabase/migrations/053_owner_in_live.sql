-- 053: owners can drop into any live, announce themselves, go on camera alongside the creator,
-- and gift a bonus that everyone in the live sees. Admins only (two-step login required, same as all admin tools).

-- Things that happen in a live that everyone in the room should see.
create table if not exists public.live_events (
  id uuid primary key default gen_random_uuid(),
  stream_id uuid not null references public.live_streams(id) on delete cascade,
  kind text not null check (kind in ('owner_joined','owner_left','bonus')),
  actor_id uuid references public.profiles(id) on delete set null,
  cents int,
  cohost boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists live_events_stream_idx on public.live_events (stream_id, created_at desc);
alter table public.live_events enable row level security;

-- Staff can watch any live without a ticket (admins can also be on camera, see live_access).
create or replace function public.live_can_watch(p_stream uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from live_streams s
    where s.id = p_stream
      and (s.creator_id = auth.uid() or s.entry_price_cents = 0 or public.is_admin()
           or exists (select 1 from live_tickets t where t.stream_id = s.id and t.user_id = auth.uid()))
  );
$$;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'live_events' and policyname = 'live_events_read') then
    create policy live_events_read on public.live_events for select using (public.live_can_watch(stream_id));
  end if;
end $$;
revoke all on public.live_events from anon, authenticated;
grant select on public.live_events to authenticated;
alter publication supabase_realtime add table public.live_events;

-- Admins get the 'owner' role: no ticket needed, and the token lets them publish camera and microphone
-- (they only do so when they press the button). Everyone else is unchanged.
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
  if is_admin() then
    return jsonb_build_object('room', s.room_name, 'role', 'owner', 'title', s.title);
  end if;
  if s.entry_price_cents > 0 and not exists (select 1 from live_tickets where stream_id = p_stream and user_id = auth.uid()) then
    raise exception 'Ticket required';
  end if;
  return jsonb_build_object('room', s.room_name, 'role', 'viewer', 'title', s.title);
end $$;

-- Tell the room an owner has arrived (optionally on camera). Repeats within a minute are ignored.
create or replace function public.live_owner_join(p_stream uuid, p_cohost boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if not exists (select 1 from live_streams where id = p_stream and status = 'live') then raise exception 'This stream is not live'; end if;
  if exists (select 1 from (select kind, cohost, created_at from live_events where stream_id = p_stream and actor_id = auth.uid()
                             and kind in ('owner_joined','owner_left') order by created_at desc limit 1) l
              where l.kind = 'owner_joined' and l.cohost = coalesce(p_cohost, false) and l.created_at > now() - interval '1 minute') then return; end if;
  insert into live_events(stream_id, kind, actor_id, cohost) values (p_stream, 'owner_joined', auth.uid(), coalesce(p_cohost, false));
  perform _log('live_owner_join', (select creator_id from live_streams where id = p_stream), jsonb_build_object('stream', p_stream, 'cohost', coalesce(p_cohost, false)));
end $$;

create or replace function public.live_owner_leave(p_stream uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if exists (select 1 from live_streams where id = p_stream) then
    insert into live_events(stream_id, kind, actor_id) values (p_stream, 'owner_left', auth.uid());
  end if;
end $$;

-- Is an owner in this live right now? (for people who join after the announcement)
create or replace function public.live_owner_present(p_stream uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not live_can_watch(p_stream) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', j.actor_id, 'cohost', j.cohost))
    from live_events j
   where j.stream_id = p_stream and j.kind = 'owner_joined' and j.created_at > now() - interval '6 hours'
     and j.created_at = (select max(x.created_at) from live_events x where x.stream_id = p_stream and x.actor_id = j.actor_id and x.kind in ('owner_joined','owner_left'))), '[]'::jsonb);
end $$;

-- The gift. Pays the live's creator a bonus (bonus balance, no fee, withdrawable like any bonus) and tells the whole room.
-- Same rules as any bonus (admins only, max £100 each) plus a daily limit per admin so a slip or a stolen session cannot do much harm.
create or replace function public.admin_live_bonus(p_stream uuid, p_cents int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s live_streams%rowtype; v_cap int; v_today bigint; v_id uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_cents is null or p_cents < 100 or p_cents > 10000 then raise exception 'A live gift must be between £1.00 and £100.00'; end if;
  select * into s from live_streams where id = p_stream and status = 'live';
  if not found then raise exception 'This stream is not live'; end if;
  v_cap := _ref_int('live_bonus_daily_cap_cents', 100000);
  select coalesce(sum(cents), 0) into v_today from live_events where actor_id = auth.uid() and kind = 'bonus' and created_at > now() - interval '24 hours';
  if v_today + p_cents > v_cap then raise exception 'That is over your daily live gift limit (£%)', (v_cap / 100); end if;
  perform admin_pay_bonus(s.creator_id, p_cents, 'Live gift during "' || left(s.title, 60) || '"');
  insert into live_events(stream_id, kind, actor_id, cents) values (p_stream, 'bonus', auth.uid(), p_cents) returning id into v_id;
  return jsonb_build_object('id', v_id, 'cents', p_cents);
end $$;

revoke execute on function public.live_owner_join(uuid, boolean), public.live_owner_leave(uuid), public.live_owner_present(uuid), public.admin_live_bonus(uuid, int) from public, anon;
grant execute on function public.live_owner_join(uuid, boolean), public.live_owner_leave(uuid), public.live_owner_present(uuid), public.admin_live_bonus(uuid, int) to authenticated;
