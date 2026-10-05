-- Fix: "permission denied for table profiles" when publishing.
-- The insert policies on posts/stories/live_streams read profiles.age_verified directly, but signed-in users
-- have no SELECT grant on that column. Use a SECURITY DEFINER helper instead.
create or replace function public.is_verified_creator()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and account_type = 'creator' and age_verified);
$$;
revoke execute on function public.is_verified_creator() from public, anon;
grant execute on function public.is_verified_creator() to authenticated;

alter policy "posts_insert"   on public.posts        with check (auth.uid() = creator_id and public.is_verified_creator());
alter policy "stories_insert" on public.stories      with check (auth.uid() = creator_id and public.is_verified_creator());
alter policy "streams_insert" on public.live_streams with check (auth.uid() = creator_id and public.is_verified_creator());
