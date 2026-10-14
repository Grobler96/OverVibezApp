-- 055: a banned account disappears for everyone else.
-- Before this, a ban only blocked what the person could DO (post, comment, spend). Their profile, posts, comments and
-- lives stayed visible to everyone. Now the database hides them: nobody else can read a banned person's profile,
-- posts, comments or lives, so they vanish from feeds, stories, Explore, search, followers lists and chats at once.
-- The banned person still sees their own account (and the suspension notice). Unbanning brings everything back.
-- Staff tools are unaffected: they read through the admin functions, not these tables.

create or replace function public._is_banned(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_banned from profiles where id = p_id), false)
$$;
grant execute on function public._is_banned(uuid) to anon, authenticated;

alter policy profiles_read on public.profiles
  using (not is_banned or id = (select auth.uid()));

alter policy posts_read on public.posts
  using (removed_at is null and deleted_at is null
         and (collab_status is null or collab_status = 'accepted' or creator_id = (select auth.uid()) or collab_user_id = (select auth.uid()))
         and (not public._is_banned(creator_id) or creator_id = (select auth.uid())));

alter policy comments_read on public.comments
  using (removed_at is null and (not public._is_banned(user_id) or user_id = (select auth.uid())));

alter policy streams_read on public.live_streams
  using (not public._is_banned(creator_id) or creator_id = (select auth.uid()));

alter policy live_comments_read on public.live_comments
  using (removed_at is null and public.live_can_watch(stream_id) and (not public._is_banned(user_id) or user_id = (select auth.uid())));

-- Banning someone also ends any live they are in the middle of.
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
  if p_banned then update live_streams set status = 'ended', ended_at = now() where creator_id = p_user and status = 'live'; end if;
  perform _log(case when p_banned then 'ban' else 'unban' end, p_user, jsonb_build_object('reason', p_reason));
end $$;
