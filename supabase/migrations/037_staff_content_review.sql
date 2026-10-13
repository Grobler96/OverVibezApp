-- 037: staff content review.
-- Moderators and admins must be able to see what is actually on the platform, including paid and subscriber-only media, to check it follows the rules.
-- * Every look at protected media is logged: staff open it through admin_open_post_media(), which writes the audit entry AND grants a 10-minute viewing
--   window. Storage only lets staff read paid media while that window is open, so there is no way to view it without leaving a record.
-- * A review queue lists every media post nobody on the team has looked at yet, oldest first, so nothing slips through. "Looks fine" marks it reviewed.
-- Creators are told about this in the Guidelines and Terms.

create table if not exists public.post_reviews (
  post_id uuid primary key references public.posts(id) on delete cascade,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz not null default now());
alter table public.post_reviews enable row level security;
revoke all on public.post_reviews from anon, authenticated;

create table if not exists public.staff_media_access (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now());
create index if not exists staff_media_access_idx on public.staff_media_access (staff_id, post_id, expires_at);
alter table public.staff_media_access enable row level security;
revoke all on public.staff_media_access from anon, authenticated;

create or replace function public.staff_may_view_media(p_post text) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if p_post is null or p_post !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return is_staff() and exists (select 1 from staff_media_access a where a.staff_id = auth.uid() and a.post_id = p_post::uuid and a.expires_at > now());
end $$;
revoke execute on function public.staff_may_view_media(text) from public, anon;
grant execute on function public.staff_may_view_media(text) to authenticated;

create policy paid_media_staff_review on storage.objects for select to authenticated
  using (bucket_id = 'paid-media' and public.staff_may_view_media((storage.foldername(name))[2]));

create or replace function public.admin_open_post_media(p_post uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p posts%rowtype; v_author text;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  select * into p from posts where id = p_post;
  if not found then raise exception 'Post not found'; end if;
  select username into v_author from profiles where id = p.creator_id;
  if p.is_paid or p.subs_only then
    insert into staff_media_access(staff_id, post_id, expires_at) values (auth.uid(), p.id, now() + interval '10 minutes');
    perform _log('view_protected_media', p.creator_id, jsonb_build_object('post', p.id));
  end if;
  return jsonb_build_object('id', p.id, 'author', v_author, 'caption', p.caption, 'media_type', p.media_type::text, 'media_path', p.media_path,
                            'is_paid', p.is_paid, 'subs_only', p.subs_only, 'price_cents', p.price_cents, 'removed', p.removed_at is not null);
end $$;

create or replace function public.admin_review_queue(p_limit int default 20)
returns table (id uuid, author text, caption text, media_type text, is_paid boolean, subs_only boolean, price_cents int, created_at timestamptz, waiting bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  return query
    select p.id, u.username, left(coalesce(p.caption, ''), 200), p.media_type::text, p.is_paid, p.subs_only, p.price_cents, p.created_at, count(*) over ()
      from posts p join profiles u on u.id = p.creator_id
     where p.media_path is not null and p.removed_at is null and p.deleted_at is null
       and not exists (select 1 from post_reviews r where r.post_id = p.id)
     order by p.created_at asc limit least(greatest(coalesce(p_limit, 20), 1), 50);
end $$;

create or replace function public.admin_mark_reviewed(p_post uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  insert into post_reviews(post_id, reviewed_by) values (p_post, auth.uid()) on conflict do nothing;
  perform _log('review_ok', (select creator_id from posts where id = p_post), jsonb_build_object('post', p_post));
end $$;

revoke execute on function public.admin_open_post_media(uuid), public.admin_review_queue(int), public.admin_mark_reviewed(uuid) from public, anon;
grant execute on function public.admin_open_post_media(uuid), public.admin_review_queue(int), public.admin_mark_reviewed(uuid) to authenticated;
