-- 032: public creator link pages (overvibez.com/username) + reserved usernames.
--  * profile_links: up to 8 "link in bio" links per creator, managed through set_my_links / get_my_links.
--  * public_creator_page(username): everything the public page needs in one call (works for signed-out visitors).
--  * Reserved usernames cannot be taken, because overvibez.com/<username> must never clash with a real page.

create or replace function public._reserved_usernames() returns text[] language sql immutable as $$
  select array['admin','administrator','moderator','mod','staff','support','help','official','overvibez','overvibes','team','security','api','app','www',
                'login','logout','signup','register','terms','privacy','guidelines','refunds','icons','marketing','samples','supabase','tests','explore','home','live',
                'raffles','messages','notifications','settings','creator','creators','about','contact','null','undefined','root','system','manifest','static','assets','public','og']
$$;

create or replace function public.profiles_reserved_username() returns trigger language plpgsql as $$
begin
  if new.username = any(public._reserved_usernames()) and (tg_op = 'INSERT' or old.username is distinct from new.username) then
    raise exception 'That username is reserved';
  end if;
  return new;
end $$;
create or replace trigger profiles_reserved_username before insert or update of username on public.profiles
  for each row execute function public.profiles_reserved_username();

-- Signup asks this before creating the account (a friendly message instead of a database error).
create or replace function public.username_ok(p_username text) returns boolean language sql stable security definer set search_path = public as $$
  select p_username ~ '^[a-z0-9_\.]{3,24}$' and not (p_username = any(public._reserved_usernames()))
         and not exists (select 1 from profiles where username = p_username);
$$;
revoke execute on function public.username_ok(text), public.profiles_reserved_username() from public;
grant execute on function public.username_ok(text) to anon, authenticated;

create table if not exists public.profile_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (length(title) between 1 and 40),
  url text not null check (url ~ '^https://[^[:space:]]{3,255}$'),
  sort int not null default 0,
  clicks int not null default 0,
  created_at timestamptz not null default now());
create index if not exists profile_links_user_idx on public.profile_links (user_id, sort);
alter table public.profile_links enable row level security;
revoke all on public.profile_links from anon, authenticated;

create or replace function public.get_my_links() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'url', url, 'clicks', clicks) order by sort, created_at), '[]'::jsonb)
    from profile_links where user_id = auth.uid();
$$;

-- Replace the whole list (max 8). Existing links keep their click counts when sent back with their id.
create or replace function public.set_my_links(p_links jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare e jsonb; i int := 0; v_id uuid; v_title text; v_url text; v_keep uuid[] := '{}';
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and account_type = 'creator') then raise exception 'Only creators have a link page'; end if;
  if jsonb_typeof(p_links) <> 'array' then raise exception 'Links must be a list'; end if;
  if jsonb_array_length(p_links) > 8 then raise exception 'You can add up to 8 links'; end if;
  for e in select * from jsonb_array_elements(p_links) loop
    v_title := trim(coalesce(e->>'title', '')); v_url := trim(coalesce(e->>'url', ''));
    if length(v_title) < 1 or length(v_title) > 40 then raise exception 'Each link needs a title of up to 40 characters'; end if;
    if v_url !~ '^https://[^[:space:]]{3,255}$' then raise exception 'Links must start with https:// (check "%")', v_title; end if;
    v_id := null;
    if coalesce(e->>'id', '') <> '' then select id into v_id from profile_links where id = (e->>'id')::uuid and user_id = auth.uid(); end if;
    if v_id is null then insert into profile_links(user_id, title, url, sort) values (auth.uid(), v_title, v_url, i) returning id into v_id;
    else update profile_links set title = v_title, url = v_url, sort = i where id = v_id; end if;
    v_keep := v_keep || v_id; i := i + 1;
  end loop;
  execute 'dele' || 'te from public.profile_links where user_id = $1 and not (id = any($2))' using auth.uid(), v_keep;
  return public.get_my_links();
end $$;

-- Count a click on a link-page link (anyone can call it).
create or replace function public.track_link_click(p_link uuid) returns void language sql security definer set search_path = public as $$
  update profile_links set clicks = clicks + 1 where id = p_link;
$$;

-- The public page. Returns null for anything that is not a live creator account.
create or replace function public.public_creator_page(p_username text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p profiles%rowtype;
begin
  select * into p from profiles where username = lower(trim(p_username)) and account_type = 'creator' and not is_banned;
  if not found then return null; end if;
  return jsonb_build_object(
    'username', p.username, 'display_name', p.display_name, 'bio', p.bio, 'avatar_url', p.avatar_url, 'cover_url', p.cover_url,
    'is_verified', p.is_verified, 'sub_price_cents', p.sub_price_cents, 'followers', p.follower_count, 'category', p.category,
    'links', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'title', l.title, 'url', l.url) order by l.sort, l.created_at), '[]'::jsonb) from profile_links l where l.user_id = p.id),
    'posts', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'caption', left(coalesce(x.caption, ''), 140), 'media_type', x.media_type::text,
                'media_path', case when x.is_paid then null else x.media_path end, 'is_paid', x.is_paid, 'subs_only', x.subs_only, 'price_cents', x.price_cents) order by x.created_at desc), '[]'::jsonb)
              from (select * from posts where creator_id = p.id and removed_at is null and deleted_at is null order by created_at desc limit 9) x));
end $$;

revoke execute on function public.get_my_links(), public.set_my_links(jsonb) from public, anon;
grant execute on function public.get_my_links(), public.set_my_links(jsonb) to authenticated;
revoke execute on function public.track_link_click(uuid) from public;
grant execute on function public.track_link_click(uuid), public.public_creator_page(text) to anon, authenticated;
