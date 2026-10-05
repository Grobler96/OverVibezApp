-- Admin & moderation layer (approved by the owner).
-- Roles: staff_role = 'moderator' (reports, content, bans) or 'admin' (everything, incl. money and raffles).
-- Staff roles can only be granted by an existing admin (or directly in the Supabase dashboard).
-- Content removal is SOFT (removed_at) so evidence is kept. Every staff action is written to admin_actions.

-- ---------- columns ----------
alter table public.profiles add column if not exists staff_role text check (staff_role in ('moderator','admin'));
alter table public.profiles add column if not exists is_banned boolean not null default false;
alter table public.profiles add column if not exists ban_reason text;
alter table public.profiles add column if not exists banned_at timestamptz;
-- (new profile columns are NOT in the column-level SELECT grant, so other users cannot read them;
--  the owner reads them through get_my_profile())

alter table public.posts    add column if not exists removed_at timestamptz;
alter table public.posts    add column if not exists removed_reason text;
alter table public.comments add column if not exists removed_at timestamptz;
alter table public.comments add column if not exists removed_reason text;
alter table public.messages add column if not exists removed_at timestamptz;
alter table public.reports  add column if not exists resolved_by uuid references public.profiles(id) on delete set null;
alter table public.reports  add column if not exists resolved_at timestamptz;
alter table public.reports  add column if not exists admin_note text;
alter table public.payouts  add column if not exists paid_at timestamptz;

create table if not exists public.admin_actions (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid references public.profiles(id) on delete set null,   -- null = system / provider webhook
  action text not null,
  target_user uuid,
  details jsonb,
  created_at timestamptz not null default now()
);
create index if not exists admin_actions_target_idx on public.admin_actions (target_user, created_at desc);
alter table public.admin_actions enable row level security;          -- no policies: only SECURITY DEFINER code touches it
revoke all on public.admin_actions from anon, authenticated;

create table if not exists public.raffle_secrets (
  raffle_id uuid primary key references public.raffles(id) on delete cascade,
  seed text not null
);
alter table public.raffle_secrets enable row level security;         -- no policies
revoke all on public.raffle_secrets from anon, authenticated;

-- ---------- role helpers ----------
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and staff_role is not null and not is_banned);
$$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and staff_role = 'admin' and not is_banned);
$$;
create or replace function public.not_banned() returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from profiles where id = auth.uid() and is_banned);
$$;

-- ---------- ban enforcement ----------
create or replace function public.is_verified_creator() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and account_type = 'creator' and age_verified and not is_banned);
$$;
create or replace function public._require_adult() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from profiles where id = auth.uid() and is_banned) then raise exception 'Account suspended'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and age_verified) then raise exception 'Age verification required'; end if;
end $$;

alter policy "comments_insert" on public.comments with check (auth.uid() = user_id and public.not_banned());
alter policy "likes_insert"    on public.likes    with check (auth.uid() = user_id and public.not_banned());
alter policy "follows_insert"  on public.follows  with check (auth.uid() = follower_id and public.not_banned());
alter policy "msg_insert"      on public.messages with check (auth.uid() = sender_id and public.not_banned()
  and exists (select 1 from conversations c where c.id = conversation_id and auth.uid() in (c.user_a, c.user_b)));

-- removed content disappears for everyone (staff still see it through the admin functions)
alter policy "posts_read"    on public.posts    using (removed_at is null);
alter policy "comments_read" on public.comments using (removed_at is null);
alter policy "msg_read"      on public.messages using (removed_at is null
  and exists (select 1 from conversations c where c.id = conversation_id and auth.uid() in (c.user_a, c.user_b)));

-- ---------- internal helpers (not callable by clients) ----------
create or replace function public._log(p_action text, p_target uuid, p_details jsonb) returns void
language sql security definer set search_path = public as $$
  insert into admin_actions(admin_id, action, target_user, details) values (auth.uid(), p_action, p_target, p_details);
$$;

create or replace function public._target_user(p_type text, p_id uuid) returns uuid language sql stable security definer set search_path = public as $$
  select case p_type
    when 'profile' then p_id
    when 'post'    then (select creator_id from posts where id = p_id)
    when 'comment' then (select user_id from comments where id = p_id)
    when 'message' then (select sender_id from messages where id = p_id)
  end;
$$;

create or replace function public._ban(p_user uuid, p_banned boolean, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare v_target text;
begin
  if p_user = auth.uid() then raise exception 'You cannot change your own ban status'; end if;
  select staff_role into v_target from profiles where id = p_user;
  if not found then raise exception 'User not found'; end if;
  if v_target = 'admin' then raise exception 'Admins cannot be banned — remove the admin role first'; end if;
  if v_target = 'moderator' and not is_admin() then raise exception 'Only an admin can ban a moderator'; end if;
  if p_banned and (p_reason is null or length(trim(p_reason)) < 3) then raise exception 'A reason is required to ban a user'; end if;
  update profiles set is_banned = p_banned, ban_reason = case when p_banned then left(p_reason, 300) end,
                      banned_at = case when p_banned then now() end where id = p_user;
  perform _log(case when p_banned then 'ban' else 'unban' end, p_user, jsonb_build_object('reason', p_reason));
end $$;

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
  else raise exception 'Unknown content type'; end if;
  if v_owner is null then raise exception 'Content not found or already removed'; end if;
  perform _log('remove_' || p_kind, v_owner, jsonb_build_object('id', p_id, 'reason', p_reason));
  return v_owner;
end $$;

-- ---------- staff functions (moderators + admins) ----------
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
    order by r.created_at limit 100;
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
    if r.target_type not in ('post','comment','message') then raise exception 'Nothing to remove for a % report', r.target_type; end if;
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

create or replace function public.admin_remove_content(p_kind text, p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  perform _remove(p_kind, p_id, p_reason);
end $$;

create or replace function public.admin_restore_content(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_post uuid;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if p_kind = 'post' then
    update posts set removed_at = null, removed_reason = null where id = p_id and removed_at is not null returning creator_id into v_owner;
  elsif p_kind = 'comment' then
    update comments set removed_at = null, removed_reason = null where id = p_id and removed_at is not null returning user_id, post_id into v_owner, v_post;
    if found then update posts set comment_count = comment_count + 1 where id = v_post; end if;
  elsif p_kind = 'message' then
    update messages set removed_at = null where id = p_id and removed_at is not null returning sender_id into v_owner;
  else raise exception 'Unknown content type'; end if;
  if v_owner is null then raise exception 'Content not found or not removed'; end if;
  perform _log('restore_' || p_kind, v_owner, jsonb_build_object('id', p_id));
end $$;

create or replace function public.admin_set_ban(p_user uuid, p_banned boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  perform _ban(p_user, p_banned, p_reason);
end $$;

create or replace function public.admin_search_users(p_q text default '')
returns table (id uuid, username text, account_type text, staff_role text, age_verified boolean, is_verified boolean, is_banned boolean,
               wallet_cents bigint, earnings_cents bigint, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_admin boolean;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  v_admin := is_admin();
  return query select p.id, p.username, p.account_type::text, p.staff_role, p.age_verified, p.is_verified, p.is_banned,
                      case when v_admin then p.wallet_cents end, case when v_admin then p.earnings_cents end, p.created_at
    from profiles p where p.username ilike '%' || replace(replace(coalesce(p_q,''), '%', ''), '_', '\_') || '%'
    order by p.created_at desc limit 25;
end $$;

create or replace function public.admin_user_detail(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'display_name', p.display_name, 'account_type', p.account_type, 'staff_role', p.staff_role,
    'age_verified', p.age_verified, 'is_verified', p.is_verified, 'is_banned', p.is_banned, 'ban_reason', p.ban_reason, 'banned_at', p.banned_at,
    'created_at', p.created_at,
    'posts', (select count(*) from posts where creator_id = p.id),
    'posts_removed', (select count(*) from posts where creator_id = p.id and removed_at is not null),
    'comments', (select count(*) from comments where user_id = p.id),
    'reports_filed', (select count(*) from reports where reporter_id = p.id),
    'reports_against', (select count(*) from reports r where _target_user(r.target_type, r.target_id) = p.id),
    'open_reports_against', (select count(*) from reports r where r.status = 'open' and _target_user(r.target_type, r.target_id) = p.id),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('action', a.action, 'at', a.created_at, 'by', ap.username, 'details', a.details) order by a.created_at desc), '[]'::jsonb)
                from (select * from admin_actions where target_user = p.id order by created_at desc limit 15) a left join profiles ap on ap.id = a.admin_id)
  ) into v from profiles p where p.id = p_user;
  if v is null then raise exception 'User not found'; end if;
  return v;
end $$;

create or replace function public.admin_list_content(p_kind text default 'post', p_limit int default 40)
returns table (id uuid, kind text, author text, preview text, is_paid boolean, price_cents int, created_at timestamptz, removed boolean, removed_reason text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  p_limit := least(greatest(coalesce(p_limit, 40), 1), 100);
  if p_kind = 'comment' then
    return query select c.id, 'comment', u.username, left(c.body, 200), false, null::int, c.created_at, c.removed_at is not null, c.removed_reason
      from comments c join profiles u on u.id = c.user_id order by c.created_at desc limit p_limit;
  else
    return query select po.id, 'post', u.username, left(coalesce(po.caption,'(media post)'), 200), po.is_paid, po.price_cents, po.created_at, po.removed_at is not null, po.removed_reason
      from posts po join profiles u on u.id = po.creator_id order by po.created_at desc limit p_limit;
  end if;
end $$;

-- ---------- admin-only functions ----------
create or replace function public.admin_set_user_flags(p_user uuid, p_age_verified boolean default null, p_verified boolean default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update profiles set age_verified = coalesce(p_age_verified, age_verified), is_verified = coalesce(p_verified, is_verified) where id = p_user;
  if not found then raise exception 'User not found'; end if;
  perform _log('user_flags', p_user, jsonb_build_object('age_verified', p_age_verified, 'verified', p_verified));
end $$;

create or replace function public.admin_set_staff_role(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own role'; end if;
  if p_role is not null and p_role not in ('moderator','admin') then raise exception 'Role must be moderator, admin or empty'; end if;
  update profiles set staff_role = p_role where id = p_user;
  if not found then raise exception 'User not found'; end if;
  perform _log('staff_role', p_user, jsonb_build_object('role', p_role));
end $$;

create or replace function public.admin_credit_wallet(p_user uuid, p_cents int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_cents is null or p_cents < 1 or p_cents > 100000 then raise exception 'Amount must be between $0.01 and $1000.00'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  update profiles set wallet_cents = wallet_cents + p_cents where id = p_user;
  if not found then raise exception 'User not found'; end if;
  insert into transactions(payee_id, type, gross_cents, fee_cents, net_cents) values (p_user, 'wallet_topup', p_cents, 0, p_cents);
  perform _log('credit_wallet', p_user, jsonb_build_object('cents', p_cents, 'reason', p_reason));
end $$;

create or replace function public.admin_list_payouts(p_status text default 'pending')
returns table (id uuid, creator_username text, amount_cents bigint, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select po.id, p.username, po.amount_cents, po.status, po.created_at
    from payouts po join profiles p on p.id = po.creator_id where po.status = p_status order by po.created_at limit 100;
end $$;

create or replace function public.admin_mark_payout_paid(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_creator uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update payouts set status = 'paid', paid_at = now() where id = p_id and status = 'pending' returning creator_id into v_creator;
  if not found then raise exception 'Pending payout not found'; end if;
  perform _log('payout_paid', v_creator, jsonb_build_object('payout', p_id));
end $$;

create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'users', (select count(*) from profiles),
    'creators', (select count(*) from profiles where account_type = 'creator'),
    'followers', (select count(*) from profiles where account_type = 'follower'),
    'age_verified', (select count(*) from profiles where age_verified),
    'banned', (select count(*) from profiles where is_banned),
    'new_users_7d', (select count(*) from profiles where created_at > now() - interval '7 days'),
    'posts', (select count(*) from posts where removed_at is null),
    'posts_removed', (select count(*) from posts where removed_at is not null),
    'comments', (select count(*) from comments where removed_at is null),
    'open_reports', (select count(*) from reports where status = 'open'),
    'gross_cents', (select coalesce(sum(gross_cents),0) from transactions where type in ('post_unlock','subscription','tip')),
    'platform_fees_cents', (select coalesce(sum(fee_cents),0) from transactions where type in ('post_unlock','subscription','tip')),
    'raffle_revenue_cents', (select coalesce(sum(gross_cents),0) from transactions where type = 'raffle_entry'),
    'wallet_liability_cents', (select coalesce(sum(wallet_cents),0) from profiles),
    'creator_earnings_owed_cents', (select coalesce(sum(earnings_cents),0) from profiles),
    'pending_payouts_cents', (select coalesce(sum(amount_cents),0) from payouts where status = 'pending'),
    'pending_payouts', (select count(*) from payouts where status = 'pending'));
end $$;

create or replace function public.admin_list_actions(p_limit int default 50)
returns table (id uuid, action text, admin text, target text, details jsonb, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select a.id, a.action, ap.username, tp.username, a.details, a.created_at
    from admin_actions a left join profiles ap on ap.id = a.admin_id left join profiles tp on tp.id = a.target_user
    order by a.created_at desc limit least(greatest(coalesce(p_limit,50),1),200);
end $$;

-- ---------- raffles: commit-reveal, drawn on the server ----------
create or replace function public.admin_create_raffle(p_title text, p_prize text, p_price_cents int, p_hours int) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_seed text; v_id uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_title is null or length(trim(p_title)) < 3 or p_prize is null or length(trim(p_prize)) < 2 then raise exception 'Title and prize are required'; end if;
  if p_price_cents is null or p_price_cents < 50 or p_price_cents > 100000 then raise exception 'Entry price must be $0.50–$1000.00'; end if;
  if p_hours is null or p_hours < 1 or p_hours > 24*60 then raise exception 'Duration must be 1 hour to 60 days'; end if;
  v_seed := encode(gen_random_bytes(32), 'hex');
  insert into raffles(host_id, title, prize, entry_price_cents, seed_hash, closes_at)
    values (null, left(trim(p_title),120), left(trim(p_prize),120), p_price_cents,
            encode(digest(convert_to(v_seed,'utf8'),'sha256'),'hex'), now() + make_interval(hours => p_hours)) returning id into v_id;
  insert into raffle_secrets(raffle_id, seed) values (v_id, v_seed);
  perform _log('raffle_create', null, jsonb_build_object('raffle', v_id, 'title', p_title, 'price_cents', p_price_cents, 'hours', p_hours));
  return v_id;
end $$;

create or replace function public.admin_draw_raffle(p_raffle uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_seed text; v_total bigint; v_hash text; v_idx bigint; v_acc bigint := 0; v_winner uuid; e record; r raffles%rowtype;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select * into r from raffles where id = p_raffle for update;
  if not found then raise exception 'Raffle not found'; end if;
  if r.winner_entry_id is not null then raise exception 'Already drawn'; end if;
  if r.closes_at > now() then raise exception 'The raffle has not closed yet'; end if;
  select coalesce(sum(qty),0) into v_total from raffle_entries where raffle_id = p_raffle;
  if v_total = 0 then raise exception 'No entries — nothing to draw'; end if;
  select seed into v_seed from raffle_secrets where raffle_id = p_raffle;
  v_hash := encode(digest(convert_to(v_seed || ':' || p_raffle::text || ':' || v_total::text, 'utf8'), 'sha256'), 'hex');
  v_idx := (('x' || substr(v_hash, 1, 15))::bit(60)::bigint) % v_total;      -- 0-based ticket number
  for e in select id, qty from raffle_entries where raffle_id = p_raffle order by created_at, id loop
    v_acc := v_acc + e.qty;
    if v_idx < v_acc then v_winner := e.id; exit; end if;
  end loop;
  update raffles set winner_entry_id = v_winner, revealed_seed = v_seed where id = p_raffle;
  perform _log('raffle_draw', (select user_id from raffle_entries where id = v_winner), jsonb_build_object('raffle', p_raffle, 'tickets', v_total, 'ticket_index', v_idx));
end $$;

-- Anyone can verify a finished draw: hash(revealed_seed) must equal the seed_hash published at creation.
create or replace function public.raffle_result(p_raffle uuid)
returns table (winner_username text, revealed_seed text, seed_hash text, hash_ok boolean, total_tickets bigint)
language sql stable security definer set search_path = public, extensions as $$
  select p.username, r.revealed_seed, r.seed_hash,
         encode(digest(convert_to(r.revealed_seed,'utf8'),'sha256'),'hex') = r.seed_hash,
         (select coalesce(sum(qty),0) from raffle_entries where raffle_id = r.id)
  from raffles r join raffle_entries e on e.id = r.winner_entry_id join profiles p on p.id = e.user_id
  where r.id = p_raffle and r.winner_entry_id is not null;
$$;

-- ---------- privileges ----------
revoke execute on function public._log(text,uuid,jsonb), public._target_user(text,uuid), public._ban(uuid,boolean,text),
  public._remove(text,uuid,text) from public, anon, authenticated;
revoke execute on function public.is_staff(), public.is_admin(), public.not_banned(),
  public.admin_list_reports(text), public.admin_resolve_report(uuid,text,text), public.admin_remove_content(text,uuid,text),
  public.admin_restore_content(text,uuid), public.admin_set_ban(uuid,boolean,text), public.admin_search_users(text),
  public.admin_user_detail(uuid), public.admin_list_content(text,int), public.admin_set_user_flags(uuid,boolean,boolean),
  public.admin_set_staff_role(uuid,text), public.admin_credit_wallet(uuid,int,text), public.admin_list_payouts(text),
  public.admin_mark_payout_paid(uuid), public.admin_stats(), public.admin_list_actions(int),
  public.admin_create_raffle(text,text,int,int), public.admin_draw_raffle(uuid), public.raffle_result(uuid) from public, anon;
-- every admin_* function re-checks is_staff()/is_admin() itself, so being callable is not enough to use them
grant execute on function public.is_staff(), public.is_admin(), public.not_banned(),
  public.admin_list_reports(text), public.admin_resolve_report(uuid,text,text), public.admin_remove_content(text,uuid,text),
  public.admin_restore_content(text,uuid), public.admin_set_ban(uuid,boolean,text), public.admin_search_users(text),
  public.admin_user_detail(uuid), public.admin_list_content(text,int), public.admin_set_user_flags(uuid,boolean,boolean),
  public.admin_set_staff_role(uuid,text), public.admin_credit_wallet(uuid,int,text), public.admin_list_payouts(text),
  public.admin_mark_payout_paid(uuid), public.admin_stats(), public.admin_list_actions(int),
  public.admin_create_raffle(text,text,int,int), public.admin_draw_raffle(uuid), public.raffle_result(uuid) to authenticated;
grant execute on function public.raffle_result(uuid) to anon;
