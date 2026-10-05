-- Abuse brakes: per-user rate limits on comments, messages, reports and posts.
-- Trigger functions only; no privilege changes.
create or replace function public.rl_comments() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from comments where user_id = new.user_id and created_at > now() - interval '1 minute') >= 15 then
    raise exception 'You are commenting too fast — slow down'; end if;
  return new; end $$;

create or replace function public.rl_messages() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from messages where sender_id = new.sender_id and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'You are sending messages too fast — slow down'; end if;
  return new; end $$;

create or replace function public.rl_reports() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from reports where reporter_id = new.reporter_id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Too many reports submitted — try again later'; end if;
  return new; end $$;

create or replace function public.rl_posts() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from posts where creator_id = new.creator_id and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Posting limit reached — try again later'; end if;
  return new; end $$;

create trigger rl_comments before insert on public.comments for each row execute function public.rl_comments();
create trigger rl_messages before insert on public.messages for each row execute function public.rl_messages();
create trigger rl_reports  before insert on public.reports  for each row execute function public.rl_reports();
create trigger rl_posts    before insert on public.posts    for each row execute function public.rl_posts();
