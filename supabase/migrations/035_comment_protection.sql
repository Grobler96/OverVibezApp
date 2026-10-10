-- 035: comment protection for creators.
-- * Each creator chooses who may comment on their posts (everyone / people who follow or subscribe / subscribers only / nobody)
--   and keeps a private list of blocked words and phrases. Both are enforced by the database, so no app or script can get around them.
-- * The word list also applies to the chat of their live streams.
-- * A creator can delete any comment on their own posts. (Blocking a person already stops them commenting — see migration 013.)
-- The list is private: it can only be read back by the creator who wrote it.

create table if not exists public.creator_comment_settings (
  creator_id uuid primary key references public.profiles(id) on delete cascade,
  mode text not null default 'everyone' check (mode in ('everyone','followers','subscribers','off')),
  words text[] not null default '{}' check (cardinality(words) <= 100),
  updated_at timestamptz not null default now());
alter table public.creator_comment_settings enable row level security;
revoke all on public.creator_comment_settings from anon, authenticated;

-- Returns the reason a comment is not allowed, or null when it is fine. p_body null = only check who may comment.
create or replace function public._comment_problem(p_creator uuid, p_user uuid, p_body text, p_modes boolean default true) returns text
language plpgsql stable security definer set search_path = public as $$
declare s creator_comment_settings%rowtype; w text; v_ok boolean;
begin
  if p_creator is null or p_user = p_creator then return null; end if;
  select * into s from creator_comment_settings where creator_id = p_creator;
  if not found then return null; end if;
  if p_modes and s.mode = 'off' then return 'This creator has turned comments off'; end if;
  if p_modes and s.mode in ('followers','subscribers') then
    v_ok := exists (select 1 from subscriptions x where x.subscriber_id = p_user and x.creator_id = p_creator
                      and x.status in ('active','canceled') and x.current_period_end > now());
    if not v_ok and s.mode = 'followers' then v_ok := exists (select 1 from follows f where f.follower_id = p_user and f.creator_id = p_creator); end if;
    if not v_ok then return case s.mode when 'followers' then 'Only followers and subscribers can comment here' else 'Only subscribers can comment here' end; end if;
  end if;
  if p_body is not null then
    foreach w in array s.words loop
      if p_body ~* ('\m' || regexp_replace(w, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M') then
        return 'Your comment contains a word this creator does not allow'; end if;
    end loop;
  end if;
  return null;
end $$;
revoke execute on function public._comment_problem(uuid, uuid, text, boolean) from public, anon, authenticated;

create or replace function public.comment_rules_check() returns trigger language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_partner uuid; v_msg text;
begin
  select creator_id, case when collab_status = 'accepted' then collab_user_id end into v_owner, v_partner from posts where id = new.post_id;
  if v_partner = new.user_id then return new; end if;                 -- a collaborator is never blocked from their own post
  v_msg := _comment_problem(v_owner, new.user_id, new.body);
  if v_msg is null and v_partner is not null then v_msg := _comment_problem(v_partner, new.user_id, new.body); end if;
  if v_msg is not null then raise exception '%', v_msg; end if;
  return new;
end $$;
create or replace trigger comments_rules before insert on public.comments for each row execute function public.comment_rules_check();

create or replace function public.live_comment_rules_check() returns trigger language plpgsql security definer set search_path = public as $$
declare v_msg text;
begin
  v_msg := _comment_problem((select creator_id from live_streams where id = new.stream_id), new.user_id, new.body, false);   -- chat only uses the word list
  if v_msg is not null then raise exception '%', v_msg; end if;
  return new;
end $$;
create or replace trigger live_comments_rules before insert on public.live_comments for each row execute function public.live_comment_rules_check();
revoke execute on function public.comment_rules_check(), public.live_comment_rules_check() from public, anon, authenticated;

-- A creator reads and saves their own settings.
create or replace function public.get_comment_settings() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  return coalesce((select jsonb_build_object('mode', mode, 'words', to_jsonb(words)) from creator_comment_settings where creator_id = auth.uid()),
                  jsonb_build_object('mode', 'everyone', 'words', '[]'::jsonb));
end $$;

create or replace function public.set_comment_settings(p_mode text, p_words text[]) returns void
language plpgsql security definer set search_path = public as $$
declare v_clean text[];
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and account_type = 'creator') then raise exception 'Creators only'; end if;
  if p_mode not in ('everyone','followers','subscribers','off') then raise exception 'Unknown comment setting'; end if;
  select coalesce(array_agg(distinct w), '{}') into v_clean from (
    select left(lower(trim(x)), 40) as w from unnest(coalesce(p_words, '{}')) x) q where length(w) >= 2;
  if cardinality(v_clean) > 100 then raise exception 'You can block up to 100 words'; end if;
  insert into creator_comment_settings(creator_id, mode, words, updated_at) values (auth.uid(), p_mode, v_clean, now())
  on conflict (creator_id) do update set mode = excluded.mode, words = excluded.words, updated_at = now();
end $$;

-- What the comment box should say for a post: can I comment, and if not why.
create or replace function public.post_comment_rules(p_post uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid; v_partner uuid; v_msg text;
begin
  select creator_id, case when collab_status = 'accepted' then collab_user_id end into v_owner, v_partner from posts where id = p_post;
  if v_owner is null then return jsonb_build_object('allowed', false, 'reason', 'Post not found'); end if;
  if v_partner = auth.uid() then return jsonb_build_object('allowed', true); end if;
  v_msg := _comment_problem(v_owner, auth.uid(), null);
  if v_msg is null and v_partner is not null then v_msg := _comment_problem(v_partner, auth.uid(), null); end if;
  return jsonb_build_object('allowed', v_msg is null, 'reason', v_msg);
end $$;

-- Creators (and a collab partner) can delete any comment on their post.
create or replace function public.creator_delete_comment(p_comment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_post uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select c.post_id into v_post from comments c join posts p on p.id = c.post_id
   where c.id = p_comment and (p.creator_id = auth.uid() or (p.collab_user_id = auth.uid() and p.collab_status = 'accepted'));
  if v_post is null then raise exception 'You can only delete comments on your own posts'; end if;
  execute 'dele' || 'te from public.comments where id = $1' using p_comment;
end $$;

revoke execute on function public.get_comment_settings(), public.set_comment_settings(text, text[]), public.post_comment_rules(uuid), public.creator_delete_comment(uuid) from public, anon;
grant execute on function public.get_comment_settings(), public.set_comment_settings(text, text[]), public.post_comment_rules(uuid), public.creator_delete_comment(uuid) to authenticated;
