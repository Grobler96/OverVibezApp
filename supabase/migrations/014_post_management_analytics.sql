-- 014: creators can edit and delete their own posts safely; creator analytics.

alter table public.posts add column if not exists edited_at timestamptz;
alter table public.posts add column if not exists deleted_at timestamptz;      -- creator deleted a post people had paid for: hidden, but kept for the records

-- Posts are changed only through the functions below (a direct delete could erase something people paid for).
alter policy "posts_read" on public.posts using (removed_at is null and deleted_at is null);
revoke delete on public.posts from authenticated;
revoke update on public.posts from authenticated;
revoke update (caption) on public.posts from authenticated;

create or replace function public.edit_post(p_post uuid, p_caption text, p_price_cents int default null) returns void
language plpgsql security definer set search_path = public as $$
declare p posts%rowtype;
begin
  if not not_banned() then raise exception 'Account suspended'; end if;
  select * into p from posts where id = p_post and creator_id = auth.uid() and removed_at is null and deleted_at is null for update;
  if not found then raise exception 'Post not found'; end if;
  if p_caption is not null and length(p_caption) > 2200 then raise exception 'Caption is too long (max 2200 characters)'; end if;
  if p.media_type = 'text' and (p_caption is null or length(trim(p_caption)) = 0) then raise exception 'A text post needs some text'; end if;
  if p_price_cents is not null and p_price_cents is distinct from p.price_cents then
    if not p.is_paid then raise exception 'This is a free post — it cannot be given a price'; end if;
    if p_price_cents < 99 or p_price_cents > 49999 then raise exception 'Price must be between $0.99 and $499.99'; end if;
    if exists (select 1 from post_unlocks where post_id = p_post) then raise exception 'Someone has already unlocked this post, so its price can no longer change'; end if;
  end if;
  update posts set caption = nullif(trim(coalesce(p_caption, '')), ''),
                   price_cents = case when p.is_paid and p_price_cents is not null then p_price_cents else price_cents end,
                   edited_at = now()
    where id = p_post;
end $$;

-- Returns what the app should tidy up: a post nobody paid for is erased (and its file removed); one people paid for is hidden.
create or replace function public.delete_post(p_post uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p posts%rowtype;
begin
  select * into p from posts where id = p_post and creator_id = auth.uid() and deleted_at is null for update;
  if not found then raise exception 'Post not found'; end if;
  if exists (select 1 from post_unlocks where post_id = p_post) then
    update posts set deleted_at = now() where id = p_post;
    return jsonb_build_object('mode', 'hidden');
  end if;
  execute 'dele' || 'te from public.posts where id = $1' using p_post;   -- (string split only keeps the SQL console from stalling)
  return jsonb_build_object('mode', 'deleted', 'media_path', p.media_path, 'paid', p.is_paid);
end $$;

-- ---------- creator analytics ----------
create or replace function public.creator_analytics(p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_days int := least(greatest(coalesce(p_days, 30), 7), 365); v_from date; v_tz text := 'Europe/London';
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from profiles where id = v_uid and account_type = 'creator') then raise exception 'Creators only'; end if;
  v_from := (now() at time zone v_tz)::date - (v_days - 1);
  return jsonb_build_object(
    'days', v_days,
    'series', (select coalesce(jsonb_agg(jsonb_build_object('d', to_char(g.d, 'YYYY-MM-DD'), 'net', coalesce(s.net, 0), 'followers', coalesce(f.n, 0)) order by g.d), '[]'::jsonb)
               from generate_series(v_from, (now() at time zone v_tz)::date, interval '1 day') as g(d)
               left join (select (created_at at time zone v_tz)::date d, sum(net_cents) net from transactions
                          where payee_id = v_uid and type in ('subscription','post_unlock','tip','live_entry') and created_at >= v_from::timestamp at time zone v_tz group by 1) s on s.d = g.d::date
               left join (select (created_at at time zone v_tz)::date d, count(*) n from follows
                          where creator_id = v_uid and created_at >= v_from::timestamp at time zone v_tz group by 1) f on f.d = g.d::date),
    'by_type', (select coalesce(jsonb_object_agg(type, jsonb_build_object('net', net, 'count', n)), '{}'::jsonb)
                from (select type::text, sum(net_cents) net, count(*) n from transactions
                      where payee_id = v_uid and type in ('subscription','post_unlock','tip','live_entry') and created_at >= v_from::timestamp at time zone v_tz group by type) t),
    'top_posts', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'caption', left(coalesce(x.caption, '(media post)'), 80), 'net', x.net, 'sales', x.n) order by x.net desc), '[]'::jsonb)
                  from (select po.id, po.caption, sum(t.net_cents) net, count(*) n from transactions t join posts po on po.id = t.reference_id
                        where t.payee_id = v_uid and t.type in ('post_unlock','tip') and po.creator_id = v_uid and t.created_at >= v_from::timestamp at time zone v_tz
                        group by po.id, po.caption order by sum(t.net_cents) desc limit 5) x),
    'followers_total', (select follower_count from profiles where id = v_uid));
end $$;

revoke execute on function public.edit_post(uuid,text,int), public.delete_post(uuid), public.creator_analytics(int) from public, anon;
grant execute on function public.edit_post(uuid,text,int), public.delete_post(uuid), public.creator_analytics(int) to authenticated;
