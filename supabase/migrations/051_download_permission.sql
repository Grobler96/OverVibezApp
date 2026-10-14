-- 051: nobody can save a photo or video unless the creator allows it.
-- A creator either switches on "followers can download" or approves requests one by one.
-- Every saved copy is watermarked in the app with the person's username, and every save is logged.

create table if not exists public.download_settings (
  creator_id uuid primary key references public.profiles(id) on delete cascade,
  followers_can_download boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.download_settings enable row level security;

create table if not exists public.download_requests (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  creator_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','declined')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  unique (post_id, requester_id)
);
create index if not exists download_requests_creator_idx on public.download_requests (creator_id, status, created_at desc);
alter table public.download_requests enable row level security;

create table if not exists public.download_log (
  id bigint generated always as identity primary key,
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists download_log_post_idx on public.download_log (post_id, created_at desc);
alter table public.download_log enable row level security;

-- Can this person see the post's media at all? (free posts yes, paid ones only if unlocked or subscribed)
create or replace function public._can_see_media(p_post uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from posts p where p.id = p_post and (
      not p.is_paid
      or p.creator_id = p_user or p.collab_user_id = p_user
      or exists (select 1 from post_unlocks u where u.post_id = p.id and u.user_id = p_user)
      or ((p.subs_only or p.sub_included) and exists (select 1 from subscriptions s
            where s.subscriber_id = p_user and s.creator_id = p.creator_id and s.current_period_end > now()))
    ));
$$;

-- Where does this person stand on downloading this post?
-- own | allowed | pending | declined | none (can ask) | need_follow | no
create or replace function public._download_state(p_post uuid, p_user uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare p record; v_req text;
begin
  select creator_id, collab_user_id, collab_status, is_paid, subs_only, media_path into p from posts where id = p_post;
  if not found or p.media_path is null then return 'no'; end if;
  if p_user = p.creator_id or (p_user = p.collab_user_id and p.collab_status = 'accepted') then return 'own'; end if;
  if is_blocked_between(p_user, p.creator_id) then return 'no'; end if;
  if not exists (select 1 from follows where follower_id = p_user and creator_id = p.creator_id) then return 'need_follow'; end if;
  if not _can_see_media(p_post, p_user) then return 'no'; end if;
  select status into v_req from download_requests where post_id = p_post and requester_id = p_user;
  if v_req = 'approved' then return 'allowed'; end if;
  -- the creator's blanket switch covers free and subscriber posts; pay-per-view always needs a yes per post
  if (not p.is_paid or p.subs_only)
     and coalesce((select followers_can_download from download_settings where creator_id = p.creator_id), false) then return 'allowed'; end if;
  if v_req = 'pending' then return 'pending'; end if;
  if v_req = 'declined' then return 'declined'; end if;
  return 'none';
end $$;

create or replace function public.download_state(p_post uuid) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  return _download_state(p_post, auth.uid());
end $$;

create or replace function public.get_download_settings() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  return jsonb_build_object('followers_can_download',
    coalesce((select followers_can_download from download_settings where creator_id = auth.uid()), false));
end $$;

create or replace function public.set_download_settings(p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and account_type = 'creator') then raise exception 'Creators only'; end if;
  insert into download_settings(creator_id, followers_can_download, updated_at) values (auth.uid(), coalesce(p_on, false), now())
  on conflict (creator_id) do update set followers_can_download = excluded.followers_can_download, updated_at = now();
end $$;

-- A follower asks the creator for permission to save one post.
create or replace function public.request_download(p_post uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_state text; v_owner uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not not_banned() then raise exception 'Your account is restricted'; end if;
  v_state := _download_state(p_post, auth.uid());
  if v_state = 'need_follow' then raise exception 'Follow this creator first, then you can ask'; end if;
  if v_state in ('own','allowed') then return v_state; end if;
  if v_state = 'pending' then return 'pending'; end if;
  if v_state = 'declined' then raise exception 'The creator said no to this one'; end if;
  if v_state <> 'none' then raise exception 'You cannot download this'; end if;
  if (select count(*) from download_requests where requester_id = auth.uid() and created_at > now() - interval '1 day') >= 20 then
    raise exception 'That is plenty of requests for today, try again tomorrow';
  end if;
  select creator_id into v_owner from posts where id = p_post;
  insert into download_requests(post_id, requester_id, creator_id) values (p_post, auth.uid(), v_owner)
  on conflict (post_id, requester_id) do nothing;
  perform _notify(v_owner, auth.uid(), 'download_request', p_post, '{}'::jsonb);
  return 'pending';
end $$;

-- Creator inbox.
create or replace function public.list_download_requests() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'post_id', r.post_id, 'username', pr.username,
            'caption', left(coalesce(p.caption, ''), 80), 'media_type', p.media_type, 'at', r.created_at) order by r.created_at desc)
          from download_requests r join profiles pr on pr.id = r.requester_id join posts p on p.id = r.post_id
         where r.creator_id = auth.uid() and r.status = 'pending'), '[]'::jsonb);
end $$;

create or replace function public.decide_download_request(p_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into r from download_requests where id = p_id and creator_id = auth.uid() and status = 'pending';
  if not found then raise exception 'That request is not waiting any more'; end if;
  update download_requests set status = case when p_approve then 'approved' else 'declined' end, decided_at = now() where id = p_id;
  perform _notify(r.requester_id, auth.uid(), case when p_approve then 'download_ok' else 'download_no' end, r.post_id, '{}'::jsonb);
end $$;

-- The app calls this just before it saves a file. It is the gate and the record.
create or replace function public.log_download(p_post uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_state text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  v_state := _download_state(p_post, auth.uid());
  if v_state not in ('own','allowed') then return false; end if;
  insert into download_log(post_id, user_id) values (p_post, auth.uid());
  return true;
end $$;

-- push wording group: the three new notice types are about people
create or replace function public._push_category(p_type text) returns text language sql immutable as $$
  select case
    when p_type in ('tip','unlock','ticket','payout_paid','refunded','topup_restored','debt_repaid','sub_renew_soon','sub_renewed','sub_renew_failed','sub_ended','bonus','new_subscriber','subscription_renewed') then 'money'
    when p_type in ('new_follower','comment','collab_invite','collab_response','featured','weekly_summary','download_request','download_ok','download_no') then 'people'
    when p_type = 'like' then 'likes'
    when p_type in ('live','new_giveaway','raffle_result') then 'live'
    when p_type in ('removed','age_approved','age_rejected','appeal_result','won','prize_shipped','topup_reversed','email_help','age_nudge','held','held_ok','scan_held','urgent_report','referral_reward') then 'account'
    else null end;
$$;

revoke execute on function public._can_see_media(uuid, uuid), public._download_state(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.download_state(uuid), public.get_download_settings(), public.set_download_settings(boolean), public.request_download(uuid),
  public.list_download_requests(), public.decide_download_request(uuid, boolean), public.log_download(uuid) from public, anon;
grant execute on function public.download_state(uuid), public.get_download_settings(), public.set_download_settings(boolean), public.request_download(uuid),
  public.list_download_requests(), public.decide_download_request(uuid, boolean), public.log_download(uuid) to authenticated;
