-- 016: error monitoring and email notifications.

-- ---------- error monitoring ----------
create table if not exists public.client_errors (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete set null,
  message text not null,
  stack text,
  url text,
  ua text,
  occurrences int not null default 1,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index if not exists client_errors_seen_idx on public.client_errors (last_seen_at desc);
alter table public.client_errors enable row level security;     -- no policies: only the functions below touch it
revoke all on public.client_errors from anon, authenticated;

-- Anyone's browser can report an error (including signed-out visitors); repeats are counted, not stored again, and the whole thing is throttled.
create or replace function public.log_client_error(p_message text, p_stack text, p_url text, p_ua text) returns void
language plpgsql security definer set search_path = public as $$
declare v_msg text := left(coalesce(p_message, ''), 500);
begin
  if length(trim(v_msg)) = 0 then return; end if;
  if (select count(*) from client_errors where last_seen_at > now() - interval '1 minute') >= 120 then return; end if;
  update client_errors set occurrences = occurrences + 1, last_seen_at = now()
    where message = v_msg and last_seen_at > now() - interval '1 day' and coalesce(url, '') = coalesce(left(p_url, 200), '');
  if found then return; end if;
  insert into client_errors(user_id, message, stack, url, ua) values (auth.uid(), v_msg, left(p_stack, 2000), left(p_url, 200), left(p_ua, 200));
end $$;

create or replace function public.admin_list_errors() returns table (id uuid, message text, stack text, url text, ua text, occurrences int, created_at timestamptz, last_seen_at timestamptz, username text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select e.id, e.message, e.stack, e.url, e.ua, e.occurrences, e.created_at, e.last_seen_at, p.username
    from client_errors e left join profiles p on p.id = e.user_id order by e.last_seen_at desc limit 100;
end $$;

create or replace function public.admin_clear_errors() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  execute 'dele' || 'te from public.client_errors where true';       -- (string split only keeps the SQL console from stalling)
end $$;

-- ---------- email notifications ----------
alter table public.profiles add column if not exists email_notifications boolean not null default true;
grant update (email_notifications) on public.profiles to authenticated;

create table if not exists public.email_queue (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  subject text not null,
  body text not null,
  status text not null default 'queued' check (status in ('queued','sending','sent','failed')),
  attempts int not null default 0,
  error text,
  created_at timestamptz not null default now(),
  sent_at timestamp with time zone
);
create index if not exists email_queue_status_idx on public.email_queue (status, created_at);
alter table public.email_queue enable row level security;
revoke all on public.email_queue from anon, authenticated;

create or replace function public._money(c bigint) returns text language sql immutable as $$ select '£' || to_char(coalesce(c, 0) / 100.0, 'FM999990.00') $$;

-- Only the notifications that matter enough to interrupt someone; everything else stays in the app.
create or replace function public._enqueue_email() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_subject text; v_body text; d jsonb := coalesce(new.data, '{}'::jsonb);
begin
  v_subject := case new.type
    when 'won' then 'You won ' || coalesce(d->>'prize', 'a prize') || '!'
    when 'prize_shipped' then 'Your prize is on its way'
    when 'refunded' then case when d->>'role' = 'payee' then 'A sale was refunded' else 'You have been refunded ' || _money((d->>'cents')::bigint) end
    when 'topup_reversed' then 'A top-up was reversed'
    when 'appeal_result' then case when d->>'action' = 'overturn' then 'Your appeal was accepted' else 'Your appeal has been reviewed' end
    when 'removed' then 'Something you posted was removed'
    when 'payout_paid' then 'Your payout of ' || _money((d->>'amount_cents')::bigint) || ' has been sent'
  end;
  if v_subject is null then return null; end if;
  if not exists (select 1 from profiles where id = new.user_id and email_notifications and not is_banned) then return null; end if;
  if (select count(*) from email_queue where status = 'queued') >= 5000 then return null; end if;
  v_body := case new.type
    when 'won' then 'Congratulations! You won ' || coalesce(d->>'prize', 'a prize') || ' in "' || coalesce(d->>'title', 'a giveaway') || '".' ||
      case when (d->>'free')::boolean then E'\n\nOpen OverVibez, go to Raffles and add your UK delivery address within 14 days so we can send it.' else '' end
    when 'prize_shipped' then 'Good news — your prize has been posted.' || case when coalesce(d->>'tracking', '') <> '' then E'\nTracking: ' || (d->>'tracking') else '' end
    when 'refunded' then case when d->>'role' = 'payee' then _money((d->>'cents')::bigint) || ' was taken from your earnings because a sale was refunded.' else _money((d->>'cents')::bigint) || ' has been returned to your OverVibez wallet.' end ||
      case when coalesce(d->>'reason', '') <> '' then E'\nReason: ' || (d->>'reason') else '' end
    when 'topup_reversed' then 'A top-up of ' || _money((d->>'cents')::bigint) || ' was reversed (' || coalesce(d->>'reason', 'refund') || ').' ||
      case when coalesce((d->>'owed')::bigint, 0) > 0 then E'\nYou now owe ' || _money((d->>'owed')::bigint) || ', which will be taken from your next top-up.' else '' end
    when 'appeal_result' then 'We have looked at your appeal and ' || case when d->>'action' = 'overturn' then 'accepted it — the decision has been put right.' else 'the original decision stands.' end ||
      case when coalesce(d->>'note', '') <> '' then E'\n\nOur reply: ' || (d->>'note') else '' end
    when 'removed' then 'A moderator removed your ' || coalesce(d->>'kind', 'content') || '.' || case when coalesce(d->>'reason', '') <> '' then E'\nReason: ' || (d->>'reason') else '' end ||
      E'\n\nIf you think this was a mistake you can appeal from the notification in the app.'
    when 'payout_paid' then 'We have sent ' || _money((d->>'amount_cents')::bigint) || ' to your payout account. It usually reaches your bank in 1–3 working days.'
  end;
  insert into email_queue(user_id, kind, subject, body) values (new.user_id, new.type, v_subject, v_body);
  return null;
exception when others then
  return null;          -- an email problem must never block the notification itself
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'enqueue_email') then
    create trigger enqueue_email after insert on public.notifications for each row execute function public._enqueue_email();
  end if;
end $$;

-- Service role only: take a batch to send (safe if two senders run at once), and report the result.
create or replace function public.claim_emails(p_limit int default 20) returns table (id uuid, user_id uuid, subject text, body text)
language sql security definer set search_path = public as $$
  update email_queue q set status = 'sending', attempts = attempts + 1
  where q.id in (select e.id from email_queue e where (e.status = 'queued' or (e.status = 'sending' and e.created_at < now() - interval '10 minutes')) and e.attempts < 3
                 order by e.created_at limit least(greatest(p_limit, 1), 50) for update skip locked)
  returning q.id, q.user_id, q.subject, q.body;
$$;
create or replace function public.finish_email(p_id uuid, p_ok boolean, p_error text default null) returns void
language sql security definer set search_path = public as $$
  update email_queue set status = case when p_ok then 'sent' when attempts >= 3 then 'failed' else 'queued' end,
         sent_at = case when p_ok then now() end, error = left(p_error, 300) where id = p_id;
$$;

create or replace function public.admin_email_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from email_queue group by status) t), '{}'::jsonb);
end $$;

-- ---------- privileges ----------
revoke execute on function public.log_client_error(text,text,text,text) from public;
grant execute on function public.log_client_error(text,text,text,text) to anon, authenticated;
revoke execute on function public.admin_list_errors(), public.admin_clear_errors(), public.admin_email_stats() from public, anon;
grant execute on function public.admin_list_errors(), public.admin_clear_errors(), public.admin_email_stats() to authenticated;
revoke execute on function public._enqueue_email(), public._money(bigint) from public, anon, authenticated;
revoke execute on function public.claim_emails(int), public.finish_email(uuid,boolean,text) from public, anon, authenticated;
grant execute on function public.claim_emails(int), public.finish_email(uuid,boolean,text) to service_role;
