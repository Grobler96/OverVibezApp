-- 033: reach and the moderation promise.
--  * following_posts(): every post from creators you follow (and your own), newest first, so the Following feed never misses a post
--    even when the app's general "recent posts" list is full of other people's.
--  * creator_post_stats() now also says how many of the creator's FOLLOWERS saw each post ("seen by X of Y followers").
--  * admin_appeal_counts(): open and overdue (waiting over 48 hours) appeals, so the 48-hour promise can be kept.

create or replace function public.following_posts(p_limit int default 150) returns setof public.posts
language sql stable security invoker set search_path = public as $$
  select p.* from posts p
   where p.creator_id = auth.uid() or exists (select 1 from follows f where f.follower_id = auth.uid() and f.creator_id = p.creator_id)
   order by p.created_at desc limit least(greatest(coalesce(p_limit, 150), 1), 300);
$$;
revoke execute on function public.following_posts(int) from public, anon;
grant execute on function public.following_posts(int) to authenticated;

create or replace function public.admin_appeal_counts() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  return jsonb_build_object('open', (select count(*) from appeals where status = 'open'),
    'overdue', (select count(*) from appeals where status = 'open' and created_at < now() - interval '48 hours'));
end $$;
revoke execute on function public.admin_appeal_counts() from public, anon;
grant execute on function public.admin_appeal_counts() to authenticated;

create or replace function public.creator_post_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = v_uid and account_type = 'creator') then raise exception 'Creators only'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select p.id, left(coalesce(p.caption, ''), 120) as caption, p.created_at, p.is_paid, p.price_cents, p.subs_only, p.sub_included, p.media_type::text as media_type,
           p.like_count as likes, p.comment_count as comments,
           coalesce(m.views, 0) as views, coalesce(m.shares, 0) as shares,
           (select count(*) from post_views v join follows fo on fo.follower_id = v.viewer_id and fo.creator_id = p.creator_id where v.post_id = p.id) as follower_views,
           (select count(*) from transactions t where t.reference_id = p.id and t.type = 'post_unlock' and t.refunded_at is null) as unlocks,
           (select count(*) from transactions t where t.reference_id = p.id and t.type = 'tip' and t.refunded_at is null) as tips,
           coalesce((select sum(t.net_cents) from transactions t where t.reference_id = p.id and t.type in ('post_unlock','tip') and t.refunded_at is null), 0) as earned_cents
      from posts p left join post_metrics m on m.post_id = p.id
     where p.creator_id = v_uid and p.removed_at is null and p.deleted_at is null) x), '[]'::jsonb);
end $$;
