-- 048: safety checks on uploads.
--  * Every new photo or video post gets a row in media_scans. A background job (the scan-media edge function, every 30 seconds)
--    checks photos with an automatic image moderation service. If something looks wrong the post is HELD (hidden from everyone but
--    staff and its creator) and staff are told. Staff then keep it or remove it (removal can be appealed like any other).
--  * Videos cannot be scanned automatically, so they are marked 'review' and wait in the existing staff review queue.
--  * Reports of "illegal content" or "under 18" alert every staff member straight away.
-- Nothing is scanned until the OPENAI_API_KEY secret is added to the scan-media function; until then rows simply wait as 'pending'.

create table if not exists public.media_scans (
  post_id uuid primary key references public.posts(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'clean', 'flagged', 'review', 'error', 'cleared', 'removed')),
  severity text check (severity in ('normal', 'urgent')),
  categories text[] not null default '{}',
  scores jsonb,
  attempts int not null default 0,
  locked_until timestamptz,
  error text,
  created_at timestamptz not null default now(),
  scanned_at timestamptz,
  decided_by uuid,
  decided_at timestamptz);
create index if not exists media_scans_todo on public.media_scans (created_at) where status in ('pending', 'error');
create index if not exists media_scans_flagged on public.media_scans (created_at) where status = 'flagged';
alter table public.media_scans enable row level security;
revoke all on public.media_scans from anon, authenticated;

-- queue every new post that has a photo or video
create or replace function public.scan_queue_post() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.media_path is not null then
    insert into media_scans(post_id, status) values (new.id, case when new.media_type::text = 'video' then 'review' else 'pending' end) on conflict do nothing;
  end if;
  return null;
exception when others then return null;     -- a scanning problem must never stop a post being created
end $$;
create or replace trigger posts_scan_queue after insert on public.posts for each row execute function public.scan_queue_post();

-- the edge function takes a batch to work on (service role only)
create or replace function public.claim_media_scans(p_limit int default 10) returns table (post_id uuid)
language sql security definer set search_path = public as $$
  with c as (select s.post_id from media_scans s
              where s.status in ('pending', 'error') and s.attempts < 3 and (s.locked_until is null or s.locked_until < now())
              order by s.created_at limit least(greatest(coalesce(p_limit, 10), 1), 25) for update skip locked)
  update media_scans m set attempts = m.attempts + 1, locked_until = now() + interval '2 minutes' from c where m.post_id = c.post_id returning m.post_id;
$$;

-- the edge function reports what it found (service role only). 'flagged' holds the post and tells staff and the creator.
create or replace function public.finish_media_scan(p_post uuid, p_status text, p_severity text, p_cats text[], p_scores jsonb, p_error text) returns void
language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_row media_scans%rowtype;
begin
  if p_status not in ('clean', 'flagged', 'review', 'error') then raise exception 'bad status'; end if;
  select * into v_row from media_scans where post_id = p_post for update;
  if not found or v_row.status in ('cleared', 'removed') then return; end if;
  if p_status = 'error' and v_row.attempts >= 3 then p_status := 'review'; end if;      -- the machine could not read it: a person looks instead
  update media_scans set status = p_status, severity = case when p_status = 'flagged' then coalesce(p_severity, 'normal') end, categories = coalesce(p_cats, '{}'),
         scores = p_scores, error = left(p_error, 300), scanned_at = now(), locked_until = null where post_id = p_post;
  if p_status = 'flagged' then
    update posts set removed_at = now(), removed_reason = 'Held for a safety check' where id = p_post and removed_at is null returning creator_id into v_owner;
    if v_owner is not null then
      insert into notifications(user_id, actor_id, type, ref_id, data) values (v_owner, null, 'held', p_post, '{}'::jsonb);
      insert into notifications(user_id, actor_id, type, ref_id, data)
        select p.id, null, 'scan_held', p_post, jsonb_build_object('severity', coalesce(p_severity, 'normal'), 'categories', coalesce(p_cats, '{}'))
          from profiles p where p.staff_role is not null and not p.is_banned;
    end if;
  end if;
end $$;

-- staff: posts held by the scanner, newest first
create or replace function public.admin_list_held(p_limit int default 30)
returns table (id uuid, author text, caption text, media_type text, is_paid boolean, subs_only boolean, severity text, categories text[], created_at timestamptz, held_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  return query
    select p.id, u.username, left(coalesce(p.caption, ''), 200), p.media_type::text, p.is_paid, p.subs_only, s.severity, s.categories, p.created_at, p.removed_at
      from media_scans s join posts p on p.id = s.post_id join profiles u on u.id = p.creator_id
     where s.status = 'flagged' and p.removed_at is not null and p.deleted_at is null
     order by (s.severity = 'urgent') desc, p.removed_at asc limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

-- staff decide: keep (put it back) or remove (with a reason, appealable)
create or replace function public.admin_decide_held(p_post uuid, p_keep boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if not exists (select 1 from media_scans where post_id = p_post and status = 'flagged') then raise exception 'This post is not waiting for a decision'; end if;
  select creator_id into v_owner from posts where id = p_post;
  if p_keep then
    update posts set removed_at = null, removed_reason = null where id = p_post;
    update media_scans set status = 'cleared', decided_by = auth.uid(), decided_at = now() where post_id = p_post;
    insert into post_reviews(post_id, reviewed_by) values (p_post, auth.uid()) on conflict do nothing;
    insert into notifications(user_id, actor_id, type, ref_id, data) values (v_owner, null, 'held_ok', p_post, '{}'::jsonb);
    perform _log('held_cleared', v_owner, jsonb_build_object('post', p_post));
  else
    if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
    update posts set removed_reason = left(trim(p_reason), 300) where id = p_post;
    update media_scans set status = 'removed', decided_by = auth.uid(), decided_at = now() where post_id = p_post;
    insert into notifications(user_id, actor_id, type, ref_id, data) values (v_owner, null, 'removed', p_post, jsonb_build_object('kind', 'post', 'reason', left(trim(p_reason), 200)));
    perform _log('held_removed', v_owner, jsonb_build_object('post', p_post, 'reason', left(trim(p_reason), 300)));
  end if;
end $$;

-- urgent reports ("illegal content" or "under 18") alert all staff at once
create or replace function public.report_urgent_alert() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.reason ~* '^(illegal|underage)' then
    insert into notifications(user_id, actor_id, type, ref_id, data)
      select p.id, null, 'urgent_report', new.id, jsonb_build_object('target_type', new.target_type, 'reason', left(new.reason, 80))
        from profiles p where p.staff_role is not null and not p.is_banned;
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger reports_urgent_alert after insert on public.reports for each row execute function public.report_urgent_alert();

-- push wording groups: staff alerts and the creator's "being checked" notices are account notices (always sent)
create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured','weekly_summary') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help','age_nudge','held','held_ok','scan_held','urgent_report') then 'account'
    else null end;
$$;

-- the admin overview gains the safety numbers
create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'users', (select count(*) from profiles),
    'new_24h', (select count(*) from profiles where created_at > now() - interval '1 day'),
    'new_7d', (select count(*) from profiles where created_at > now() - interval '7 days'),
    'new_30d', (select count(*) from profiles where created_at > now() - interval '30 days'),
    'creators', (select count(*) from profiles where account_type = 'creator'),
    'creators_unverified', (select count(*) from profiles where account_type = 'creator' and not age_verified and not is_banned),
    'creators_posting_7d', (select count(distinct creator_id) from posts where created_at > now() - interval '7 days' and deleted_at is null and removed_at is null),
    'open_reports', (select count(*) from reports where status::text = 'open'),
    'urgent_reports', (select count(*) from reports where status::text = 'open' and reason ~* '^(illegal|underage)'),
    'held_posts', (select count(*) from media_scans s join posts p on p.id = s.post_id where s.status = 'flagged' and p.removed_at is not null),
    'scan_pending', (select count(*) from media_scans where status in ('pending', 'error')),
    'open_appeals', (select count(*) from appeals where status = 'open'),
    'overdue_appeals', (select count(*) from appeals where status = 'open' and created_at < now() - interval '48 hours'),
    'age_pending', (select count(*) from age_requests where status = 'pending'),
    'age_overdue', (select count(*) from age_requests where status = 'pending' and created_at < now() - interval '24 hours'),
    'feedback_open', (select count(*) from feedback where handled_at is null),
    'email_help_open', (select count(*) from email_help_requests r where r.handled_at is null and exists (select 1 from auth.users u where u.id = r.user_id and u.email_confirmed_at is null)),
    'payouts_pending', (select count(*) from payouts where status = 'pending'),
    'errors_24h', (select count(*) from client_errors where last_seen_at > now() - interval '1 day'),
    'live_now', (select count(*) from live_streams where status::text = 'live'),
    'sales_7d_cents', (select coalesce(sum(gross_cents), 0) from transactions where refunded_at is null and created_at > now() - interval '7 days' and type in ('subscription', 'post_unlock', 'tip', 'live_entry', 'vibe')),
    'fees_7d_cents', (select coalesce(sum(fee_cents), 0) from transactions where refunded_at is null and created_at > now() - interval '7 days' and type in ('subscription', 'post_unlock', 'tip', 'live_entry', 'vibe')),
    'topups_7d_cents', (select coalesce(sum(gross_cents), 0) from transactions where created_at > now() - interval '7 days' and type = 'wallet_topup'),
    'signups', (select coalesce(jsonb_agg(c order by d), '[]'::jsonb) from (
        select g::date d, (select count(*) from profiles where (created_at at time zone 'Europe/London')::date = g::date) c
          from generate_series((now() at time zone 'Europe/London')::date - 13, (now() at time zone 'Europe/London')::date, interval '1 day') g) x));
end $$;

revoke execute on function public.scan_queue_post(), public.report_urgent_alert(), public.claim_media_scans(int), public.finish_media_scan(uuid, text, text, text[], jsonb, text) from public, anon, authenticated;
grant execute on function public.claim_media_scans(int), public.finish_media_scan(uuid, text, text, text[], jsonb, text) to service_role;
revoke execute on function public.admin_list_held(int), public.admin_decide_held(uuid, boolean, text) from public, anon;
grant execute on function public.admin_list_held(int), public.admin_decide_held(uuid, boolean, text) to authenticated;

select cron.schedule('scan-media', '30 seconds', $c$
  select net.http_post(url := 'https://ectwnzhuebgnvejdpgdk.supabase.co/functions/v1/scan-media',
    headers := jsonb_build_object('x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')))
$c$);
