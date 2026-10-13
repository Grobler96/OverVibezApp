-- 040: followers / following lists, with privacy that is actually enforced.
-- * Tapping Followers or Following on a profile shows the accounts involved.
-- * On an 18+ platform, who follows which creator is sensitive, so: a creator always sees ALL their own followers; everyone else sees only the followers who are
--   creators or fans who chose to appear (Me -> "Show me in followers lists", off by default). A creator's Following list is public (those are creators).
--   A fan's own lists are visible only to that fan.
-- * Until now any signed-in member could read the whole follows table directly (policy "using (true)"). That is closed: members can only read follows that
--   involve themselves, so the lists can only be read through list_people(), which applies the rules above.

alter table public.profiles add column if not exists show_in_lists boolean not null default false;

alter policy follows_read on public.follows using (follower_id = (select auth.uid()) or creator_id = (select auth.uid()));

create or replace function public.set_list_visibility(p_show boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update profiles set show_in_lists = coalesce(p_show, false) where id = auth.uid();
end $$;

create or replace function public.list_people(p_user uuid, p_kind text, p_limit int default 50, p_offset int default 0)
returns table (id uuid, username text, display_name text, avatar_url text, account_type text, is_verified boolean, follower_count int)
language plpgsql stable security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_type text; v_lim int := least(greatest(coalesce(p_limit, 50), 1), 100); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  if v_me is null then raise exception 'Not signed in'; end if;
  select p.account_type::text into v_type from profiles p where p.id = p_user and not p.is_banned;
  if v_type is null then return; end if;
  if v_me <> p_user and v_type <> 'creator' then return; end if;            -- a fan's lists are private to that fan
  if p_kind = 'followers' then
    return query
      select p.id, p.username, p.display_name, p.avatar_url, p.account_type::text, p.is_verified, p.follower_count
        from follows f join profiles p on p.id = f.follower_id
       where f.creator_id = p_user and not p.is_banned and not is_blocked_between(v_me, p.id)
         and (v_me = p_user or p.account_type = 'creator' or p.show_in_lists or p.id = v_me)
       order by f.created_at desc limit v_lim offset v_off;
  elsif p_kind = 'following' then
    return query
      select p.id, p.username, p.display_name, p.avatar_url, p.account_type::text, p.is_verified, p.follower_count
        from follows f join profiles p on p.id = f.creator_id
       where f.follower_id = p_user and not p.is_banned and not is_blocked_between(v_me, p.id)
       order by f.created_at desc limit v_lim offset v_off;
  end if;
end $$;

-- how many accounts someone follows (shown only where the list itself may be seen)
create or replace function public.following_count(p_user uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare v_type text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select account_type::text into v_type from profiles where id = p_user and not is_banned;
  if v_type is null or (auth.uid() <> p_user and v_type <> 'creator') then return null; end if;
  return (select count(*) from follows f join profiles p on p.id = f.creator_id where f.follower_id = p_user and not p.is_banned)::int;
end $$;

revoke execute on function public.set_list_visibility(boolean), public.list_people(uuid, text, int, int), public.following_count(uuid) from public, anon;
grant execute on function public.set_list_visibility(boolean), public.list_people(uuid, text, int, int), public.following_count(uuid) to authenticated;
