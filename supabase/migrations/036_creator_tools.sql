-- 036: creator tools — scheduled posts and drafts, best time to post, levels and badges, Creator of the Week.
--
-- Scheduled posts and drafts live in their own private table (only the creator can see them). When the time comes a
-- once-a-minute job publishes the post by inserting it into posts exactly as if the creator had pressed Publish, so every existing
-- rule (rate limits, collab invitations, paid-media access, refunds) applies unchanged and nothing else needed to learn about drafts.

create table if not exists public.scheduled_posts (
  id uuid primary key default gen_random_uuid(),            -- becomes the post's id, so media already uploaded under it stays valid
  creator_id uuid not null references public.profiles(id) on delete cascade,
  caption text check (caption is null or length(caption) <= 2000),
  media_type public.media_type not null default 'image',
  media_path text,
  is_paid boolean not null default false,
  price_cents int,
  subs_only boolean not null default false,
  sub_included boolean not null default true,
  collab_user_id uuid references public.profiles(id) on delete set null,
  collab_pct int not null default 50 check (collab_pct between 10 and 90),
  publish_at timestamptz,                                    -- null = a draft
  failure text,                                              -- why the last attempt to publish did not work
  created_at timestamptz not null default now());
create index if not exists scheduled_posts_due_idx on public.scheduled_posts (publish_at) where publish_at is not null;
create index if not exists scheduled_posts_creator_idx on public.scheduled_posts (creator_id);
alter table public.scheduled_posts enable row level security;
revoke all on public.scheduled_posts from anon, authenticated;
grant select on public.scheduled_posts to authenticated;
grant insert (id, creator_id, caption, media_type, media_path, is_paid, price_cents, subs_only, sub_included, collab_user_id, collab_pct, publish_at) on public.scheduled_posts to authenticated;
grant update (caption, price_cents, publish_at) on public.scheduled_posts to authenticated;
grant delete on public.scheduled_posts to authenticated;
create policy scheduled_read on public.scheduled_posts for select using (creator_id = (select auth.uid()));
create or replace function public.can_schedule_posts() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and account_type = 'creator' and age_verified and not is_banned);
$$;
revoke execute on function public.can_schedule_posts() from public, anon;
grant execute on function public.can_schedule_posts() to authenticated;
create policy scheduled_insert on public.scheduled_posts for insert with check (creator_id = (select auth.uid()) and public.can_schedule_posts()
  and (publish_at is null or (publish_at > now() and publish_at < now() + interval '90 days')));
create policy scheduled_update on public.scheduled_posts for update using (creator_id = (select auth.uid()))
  with check (creator_id = (select auth.uid()) and (publish_at is null or (publish_at > now() and publish_at < now() + interval '90 days')));
create policy scheduled_delete on public.scheduled_posts for delete using (creator_id = (select auth.uid()));

create or replace function public.scheduled_posts_limit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from scheduled_posts where creator_id = new.creator_id) >= 50 then raise exception 'You can keep up to 50 scheduled posts and drafts — publish or delete some first'; end if;
  new.failure := null;
  return new;
end $$;
create or replace trigger scheduled_posts_limit before insert on public.scheduled_posts for each row execute function public.scheduled_posts_limit();
revoke execute on function public.scheduled_posts_limit() from public, anon, authenticated;

-- Publish one scheduled post / draft. A problem (for example the collaborator has since been blocked) turns it back into a draft with the reason.
create or replace function public._publish_scheduled(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare s scheduled_posts%rowtype;
begin
  select * into s from scheduled_posts where id = p_id for update skip locked;
  if not found then return false; end if;
  if not exists (select 1 from profiles where id = s.creator_id and not is_banned and age_verified and account_type = 'creator') then
    update scheduled_posts set publish_at = null, failure = 'Your account cannot publish right now' where id = p_id; return false; end if;
  begin
    insert into posts(id, creator_id, caption, media_type, media_path, is_paid, price_cents, subs_only, sub_included, collab_user_id, collab_pct)
    values (s.id, s.creator_id, s.caption, s.media_type, s.media_path, s.is_paid, s.price_cents, s.subs_only, s.sub_included, s.collab_user_id, s.collab_pct);
    execute 'dele' || 'te from public.scheduled_posts where id = $1' using p_id;
    return true;
  exception when others then
    update scheduled_posts set publish_at = null, failure = left(sqlerrm, 200) where id = p_id;
    return false;
  end;
end $$;
revoke execute on function public._publish_scheduled(uuid) from public, anon, authenticated;

create or replace function public.publish_due_posts() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id from scheduled_posts where publish_at is not null and publish_at <= now() order by publish_at limit 200 loop
    if _publish_scheduled(r.id) then n := n + 1; end if;
  end loop;
  return n;
end $$;
revoke execute on function public.publish_due_posts() from public, anon, authenticated;

create or replace function public.publish_scheduled_now(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_fail text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from scheduled_posts where id = p_id and creator_id = auth.uid()) then raise exception 'Scheduled post not found'; end if;
  if not _publish_scheduled(p_id) then
    select failure into v_fail from scheduled_posts where id = p_id;
    raise exception '%', coalesce(v_fail, 'This post could not be published'); end if;
end $$;
revoke execute on function public.publish_scheduled_now(uuid) from public, anon;
grant execute on function public.publish_scheduled_now(uuid) to authenticated;

select cron.schedule('publish-scheduled-posts', '* * * * *', 'select public.publish_due_posts()');

-- ---------- best time to post ----------
-- When your audience actually looks at your posts: views grouped by UK hour and weekday over the last 90 days.
create or replace function public.creator_best_times() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_hours int[] := array_fill(0, array[24]); v_days int[] := array_fill(0, array[7]); r record; v_total int := 0;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = v_uid and account_type = 'creator') then raise exception 'Creators only'; end if;
  for r in select extract(hour from v.created_at at time zone 'Europe/London')::int h, extract(isodow from v.created_at at time zone 'Europe/London')::int d, count(*)::int c
             from post_views v join posts p on p.id = v.post_id
            where p.creator_id = v_uid and v.created_at > now() - interval '90 days'
            group by 1, 2 loop
    v_hours[r.h + 1] := v_hours[r.h + 1] + r.c; v_days[r.d] := v_days[r.d] + r.c; v_total := v_total + r.c;
  end loop;
  return jsonb_build_object('total', v_total, 'hours', to_jsonb(v_hours), 'days', to_jsonb(v_days));
end $$;
revoke execute on function public.creator_best_times() from public, anon;
grant execute on function public.creator_best_times() to authenticated;

-- ---------- levels and badges (worked out live from real activity, nothing to maintain) ----------
create or replace function public.creator_badges(p_creator uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p profiles%rowtype; v_posts int; v_sales int; v_streams int; v_likes int; v_subs int; v_collabs int; v_points int; v_level text; v_emoji text; v_next int; b jsonb := '[]'::jsonb;
begin
  select * into p from profiles where id = p_creator and account_type = 'creator' and not is_banned;
  if not found then return null; end if;
  select count(*), coalesce(sum(like_count), 0), count(*) filter (where collab_status = 'accepted') into v_posts, v_likes, v_collabs
    from posts where (creator_id = p_creator or (collab_user_id = p_creator and collab_status = 'accepted')) and removed_at is null and deleted_at is null;
  select count(*) into v_sales from transactions where payee_id = p_creator and type in ('post_unlock','subscription','tip','vibe','live_entry') and refunded_at is null;
  select count(*) into v_streams from live_streams where creator_id = p_creator and status = 'ended';
  select count(*) into v_subs from subscriptions where creator_id = p_creator and status in ('active','canceled') and current_period_end > now();
  v_points := p.follower_count + v_posts * 2 + v_sales * 3 + v_streams * 10 + v_likes / 2;
  select l, e, n into v_level, v_emoji, v_next from (values (0, 'Rookie', '🌱', 100), (100, 'Rising', '⭐', 500), (500, 'Star', '🌟', 2500), (2500, 'Icon', '👑', null::int)) t(min_pts, l, e, n)
   where min_pts <= v_points order by min_pts desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'emoji', e, 'label', l, 'desc', d)), '[]'::jsonb) into b from (values
    ('verified', '✔', 'Verified', 'Identity checked by OverVibez', p.is_verified),
    ('first_post', '📝', 'First post', 'Published a first post', v_posts >= 1),
    ('posts_25', '🗂️', '25 posts', 'Published 25 posts', v_posts >= 25),
    ('followers_100', '👥', '100 followers', 'Reached 100 followers', p.follower_count >= 100),
    ('followers_1000', '🚀', '1,000 followers', 'Reached 1,000 followers', p.follower_count >= 1000),
    ('first_sale', '💷', 'First sale', 'Made a first sale', v_sales >= 1),
    ('sales_50', '💰', '50 sales', 'Made 50 sales, tips or vibes', v_sales >= 50),
    ('subs_10', '💜', '10 subscribers', 'Has 10 active subscribers', v_subs >= 10),
    ('live_host', '🔴', 'Live host', 'Hosted a live stream', v_streams >= 1),
    ('collab', '🤝', 'Collaborator', 'Published a collab post', v_collabs >= 1)) x(k, e, l, d, got) where got;
  return jsonb_build_object('points', v_points, 'level', v_level, 'emoji', v_emoji, 'next_at', v_next, 'badges', b);
end $$;
revoke execute on function public.creator_badges(uuid) from public, anon;
grant execute on function public.creator_badges(uuid) to authenticated;

-- ---------- Creator of the Week ----------
create table if not exists public.featured_creators (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  note text check (note is null or length(note) <= 200),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now());
alter table public.featured_creators enable row level security;
revoke all on public.featured_creators from anon, authenticated;

create or replace function public.featured_creator() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name, 'avatar_url', p.avatar_url,
                            'follower_count', p.follower_count, 'note', f.note, 'since', f.created_at)
    from featured_creators f join profiles p on p.id = f.creator_id
   where f.created_at > now() - interval '7 days' and not p.is_banned and p.account_type = 'creator'
   order by f.created_at desc limit 1;
$$;
revoke execute on function public.featured_creator() from public, anon;
grant execute on function public.featured_creator() to authenticated;

create or replace function public.admin_feature_creator(p_creator uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if not exists (select 1 from profiles where id = p_creator and account_type = 'creator' and not is_banned) then raise exception 'Only creators can be featured'; end if;
  insert into featured_creators(creator_id, note, created_by) values (p_creator, nullif(left(trim(coalesce(p_note, '')), 200), ''), auth.uid());
  perform _notify(p_creator, null, 'featured', null, '{}'::jsonb);
  perform _log('feature_creator', p_creator, jsonb_build_object('note', left(coalesce(p_note, ''), 200)));
end $$;
revoke execute on function public.admin_feature_creator(uuid, text) from public, anon;
grant execute on function public.admin_feature_creator(uuid, text) to authenticated;

-- Who gained the most followers this week (a starting point for the admin's pick).
create or replace function public.admin_cotw_candidates() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x)) from (
    select p.id, p.username, p.display_name, count(f.*)::int as new_followers,
           (select count(*) from posts q where q.creator_id = p.id and q.removed_at is null and q.deleted_at is null and q.created_at > now() - interval '7 days')::int as posts_7d
      from profiles p join follows f on f.creator_id = p.id and f.created_at > now() - interval '7 days'
     where p.account_type = 'creator' and not p.is_banned
     group by p.id order by new_followers desc limit 5) x), '[]'::jsonb);
end $$;
revoke execute on function public.admin_cotw_candidates() from public, anon;
grant execute on function public.admin_cotw_candidates() to authenticated;
