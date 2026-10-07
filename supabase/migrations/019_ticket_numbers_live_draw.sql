-- 019: ticket numbers and the live draw.
-- * Every entry is given its own ticket number(s), in the order people enter: the first ticket is #1.
-- * An admin can run the draw live on camera: the draw happens first, the result is only announced (notifications, seed reveal,
--   public winners list) when the admin finishes the on-screen reveal, so nobody is spoiled.
-- * Anyone can check an announced draw (raffle_proof).

alter table public.raffle_entries add column if not exists ticket_start int;
alter table public.raffles add column if not exists winning_ticket int;
alter table public.raffles add column if not exists announced_at timestamptz;

-- Hands out ticket numbers one entry at a time per raffle, so two people entering together can never share a number.
create or replace function public._assign_tickets() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform 1 from raffles where id = new.raffle_id for update;
  new.ticket_start := coalesce((select max(ticket_start + qty - 1) from raffle_entries where raffle_id = new.raffle_id), 0) + 1;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'assign_tickets') then
    create trigger assign_tickets before insert on public.raffle_entries for each row execute function public._assign_tickets();
  end if;
end $$;
update public.raffle_entries e set ticket_start = x.s
  from (select id, 1 + coalesce(sum(qty) over (partition by raffle_id order by created_at, id rows between unbounded preceding and 1 preceding), 0) as s from public.raffle_entries) x
  where x.id = e.id and e.ticket_start is null;
alter table public.raffle_entries alter column ticket_start set not null;
create unique index if not exists raffle_entries_ticket_idx on public.raffle_entries (raffle_id, ticket_start);

-- ---------- the draw ----------
create or replace function public._pick_ticket(p_raffle uuid, p_attempt int) returns table (entry_id uuid, ticket int, total bigint)
language plpgsql security definer set search_path = public, extensions as $$
declare v_seed text; v_total bigint; v_hash text; v_idx bigint; v_acc bigint := 0; e record;
begin
  select coalesce(sum(qty),0) into v_total from raffle_entries x
    where x.raffle_id = p_raffle and not exists (select 1 from raffle_voids v where v.raffle_id = x.raffle_id and v.user_id = x.user_id);
  if v_total = 0 then return; end if;
  select seed into v_seed from raffle_secrets where raffle_id = p_raffle;
  v_hash := encode(digest(convert_to(v_seed || ':' || p_raffle::text || ':' || v_total::text || case when p_attempt > 0 then ':' || p_attempt::text else '' end, 'utf8'), 'sha256'), 'hex');
  v_idx := (('x' || substr(v_hash, 1, 15))::bit(60)::bigint) % v_total;
  for e in select x.id, x.qty, x.ticket_start from raffle_entries x
           where x.raffle_id = p_raffle and not exists (select 1 from raffle_voids v where v.raffle_id = x.raffle_id and v.user_id = x.user_id)
           order by x.ticket_start loop
    if v_idx < v_acc + e.qty then
      return query select e.id, (e.ticket_start + (v_idx - v_acc))::int, v_total; return;
    end if;
    v_acc := v_acc + e.qty;
  end loop;
end $$;

create or replace function public._pick_winner(p_raffle uuid, p_attempt int) returns uuid
language sql security definer set search_path = public, extensions as $$
  select t.entry_id from public._pick_ticket(p_raffle, p_attempt) t;
$$;

-- Step 1: choose the winner. Nothing is announced yet and the seed stays secret.
create or replace function public._do_draw(p_raffle uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r raffles%rowtype; t record; v_user uuid; v_name text;
begin
  select * into r from raffles where id = p_raffle for update;
  if not found then raise exception 'Raffle not found'; end if;
  if r.winner_entry_id is not null then raise exception 'Already drawn'; end if;
  if r.closes_at > now() then raise exception 'The raffle has not closed yet'; end if;
  select * into t from _pick_ticket(p_raffle, 0);
  if t.entry_id is null then raise exception 'No entries — nothing to draw'; end if;
  update raffles set winner_entry_id = t.entry_id, winning_ticket = t.ticket where id = p_raffle;
  select e.user_id, p.username into v_user, v_name from raffle_entries e join profiles p on p.id = e.user_id where e.id = t.entry_id;
  perform _log('raffle_draw', v_user, jsonb_build_object('raffle', p_raffle, 'ticket', t.ticket));
  return jsonb_build_object('raffle', p_raffle, 'title', r.title, 'prize', r.prize, 'is_free', r.is_free, 'seed_hash', r.seed_hash,
    'winning_ticket', t.ticket, 'total_tickets', t.total, 'entrants', (select count(distinct user_id) from raffle_entries where raffle_id = p_raffle), 'winner_username', v_name);
end $$;

create or replace function public.admin_draw_raffle_live(p_raffle uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return _do_draw(p_raffle);
end $$;

-- Step 2: announce it — reveal the seed, tell the winner and everyone else who entered, start the claim window.
create or replace function public.admin_announce_raffle(p_raffle uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r raffles%rowtype; v_user uuid; v_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select * into r from raffles where id = p_raffle for update;
  if not found or r.winner_entry_id is null then raise exception 'This raffle has not been drawn yet'; end if;
  if r.announced_at is not null then raise exception 'Already announced'; end if;
  update raffles set announced_at = now(), revealed_seed = (select seed from raffle_secrets where raffle_id = p_raffle),
         claim_by = case when is_free then now() + interval '14 days' end where id = p_raffle;
  select e.user_id, p.username into v_user, v_name from raffle_entries e join profiles p on p.id = e.user_id where e.id = r.winner_entry_id;
  insert into notifications(user_id, actor_id, type, ref_id, data) values (v_user, null, 'won', p_raffle,
    jsonb_build_object('title', r.title, 'prize', r.prize, 'free', r.is_free, 'ticket', r.winning_ticket));
  insert into notifications(user_id, actor_id, type, ref_id, data)
    select u.user_id, null::uuid, 'raffle_result', p_raffle, jsonb_build_object('title', r.title, 'prize', r.prize, 'winner', v_name, 'ticket', r.winning_ticket)
    from (select distinct e.user_id from raffle_entries e where e.raffle_id = p_raffle and e.user_id <> v_user limit 5000) u;
  perform _log('raffle_announce', v_user, jsonb_build_object('raffle', p_raffle));
end $$;

-- The quick way (no on-screen show): draw and announce in one go.
create or replace function public.admin_draw_raffle(p_raffle uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  perform _do_draw(p_raffle);
  perform admin_announce_raffle(p_raffle);
end $$;

create or replace function public.admin_redraw_raffle(p_raffle uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r raffles%rowtype; v_old uuid; t record; v_user uuid; v_attempt int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  select * into r from raffles where id = p_raffle for update;
  if not found or r.winner_entry_id is null then raise exception 'This raffle has not been drawn'; end if;
  if r.announced_at is null then raise exception 'Announce the current winner first'; end if;
  if exists (select 1 from prize_claims where raffle_id = p_raffle and status = 'shipped') then raise exception 'The prize has already been shipped'; end if;
  select user_id into v_old from raffle_entries where id = r.winner_entry_id;
  insert into raffle_voids(raffle_id, user_id, reason) values (p_raffle, v_old, left(p_reason, 200)) on conflict do nothing;
  select count(*) into v_attempt from raffle_voids where raffle_id = p_raffle;
  select * into t from _pick_ticket(p_raffle, v_attempt);
  if t.entry_id is null then raise exception 'No other entries to draw from'; end if;
  execute 'dele' || 'te from public.prize_claims where raffle_id = $1' using p_raffle;
  update raffles set winner_entry_id = t.entry_id, winning_ticket = t.ticket, claim_by = case when is_free then now() + interval '14 days' end where id = p_raffle;
  select user_id into v_user from raffle_entries where id = t.entry_id;
  perform _log('raffle_redraw', v_old, jsonb_build_object('raffle', p_raffle, 'reason', p_reason, 'attempt', v_attempt, 'ticket', t.ticket));
  insert into notifications(user_id, actor_id, type, ref_id, data) values (v_user, null, 'won', p_raffle, jsonb_build_object('title', r.title, 'prize', r.prize, 'free', r.is_free, 'ticket', t.ticket));
end $$;

-- ---------- public results (only once announced) ----------
create or replace function public.raffle_result(p_raffle uuid)
returns table (winner_username text, revealed_seed text, seed_hash text, hash_ok boolean, total_tickets bigint)
language sql stable security definer set search_path = public, extensions as $$
  select p.username, r.revealed_seed, r.seed_hash,
         encode(digest(convert_to(r.revealed_seed,'utf8'),'sha256'),'hex') = r.seed_hash,
         (select coalesce(sum(qty),0) from raffle_entries where raffle_id = r.id)
  from raffles r join raffle_entries e on e.id = r.winner_entry_id join profiles p on p.id = e.user_id
  where r.id = p_raffle and r.winner_entry_id is not null and r.announced_at is not null;
$$;

-- Everything someone needs to check a draw for themselves.
create or replace function public.raffle_proof(p_raffle uuid)
returns table (title text, prize text, winner_username text, winning_ticket int, total_tickets bigint, revealed_seed text, seed_hash text, hash_ok boolean, redraws int)
language sql stable security definer set search_path = public, extensions as $$
  select r.title, r.prize, p.username, r.winning_ticket, (select coalesce(sum(qty),0) from raffle_entries where raffle_id = r.id),
         r.revealed_seed, r.seed_hash, encode(digest(convert_to(r.revealed_seed,'utf8'),'sha256'),'hex') = r.seed_hash,
         (select count(*)::int from raffle_voids where raffle_id = r.id)
  from raffles r join raffle_entries e on e.id = r.winner_entry_id join profiles p on p.id = e.user_id
  where r.id = p_raffle and r.announced_at is not null;
$$;

-- ---------- privileges ----------
revoke execute on function public._assign_tickets(), public._pick_ticket(uuid,int), public._pick_winner(uuid,int), public._do_draw(uuid) from public, anon, authenticated;
revoke execute on function public.admin_draw_raffle_live(uuid), public.admin_announce_raffle(uuid), public.admin_draw_raffle(uuid), public.admin_redraw_raffle(uuid,text) from public, anon;
grant execute on function public.admin_draw_raffle_live(uuid), public.admin_announce_raffle(uuid), public.admin_draw_raffle(uuid), public.admin_redraw_raffle(uuid,text) to authenticated;
revoke execute on function public.raffle_proof(uuid) from public;
grant execute on function public.raffle_proof(uuid) to anon, authenticated;
