-- 052: admin panel v2. Live queue counts for the menu and a proper people directory.

-- How much is waiting in each queue. Moderators see their three, admins see everything.
create or replace function public.admin_nav_counts() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare v jsonb;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  v := jsonb_build_object(
    'reports', (select count(*) from reports where status::text = 'open'),
    'appeals', (select count(*) from appeals where status = 'open'),
    'live', (select count(*) from live_streams where status::text = 'live'));
  if is_admin() then
    v := v || jsonb_build_object(
      'age', (select count(*) from age_requests where status = 'pending'),
      'feedback', (select count(*) from feedback where handled_at is null),
      'payouts', (select count(*) from payouts where status = 'pending'),
      'errors', (select count(*) from client_errors where last_seen_at > now() - interval '1 day'),
      'referrals', (select count(*) from referral_rewards where status = 'pending'),
      'users', (select count(*) from email_help_requests r where r.handled_at is null and exists (select 1 from auth.users u where u.id = r.user_id and u.email_confirmed_at is null)));
  end if;
  return v;
end $$;

-- People directory: search, filter, sort and page. Email, wallet and earnings are admin only.
create or replace function public.admin_find_users(p_q text default '', p_filter text default 'all', p_sort text default 'newest',
                                                   p_limit int default 25, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare v_admin boolean; v_q text; v_total bigint; v_rows jsonb; v_id uuid;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  v_admin := is_admin();
  v_q := trim(coalesce(p_q, ''));
  begin v_id := v_q::uuid; exception when others then v_id := null; end;
  v_q := replace(replace(v_q, '%', ''), '_', '\_');
  p_limit := least(greatest(coalesce(p_limit, 25), 1), 100);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  if p_filter not in ('all','creators','followers','staff','banned','unverified','flagged','new7') then p_filter := 'all'; end if;
  if p_sort not in ('newest','oldest','followers','earnings','wallet') then p_sort := 'newest'; end if;
  if p_sort in ('earnings','wallet') and not v_admin then p_sort := 'newest'; end if;

  with f as (
    select p.* from profiles p
     where (v_q = '' or p.username ilike '%' || v_q || '%' or p.display_name ilike '%' || v_q || '%' or p.id = v_id
            or (v_admin and exists (select 1 from auth.users u where u.id = p.id and u.email ilike '%' || v_q || '%')))
       and case p_filter
             when 'creators' then p.account_type::text = 'creator'
             when 'followers' then p.account_type::text <> 'creator'
             when 'staff' then p.staff_role is not null
             when 'banned' then p.is_banned
             when 'unverified' then not p.age_verified
             when 'new7' then p.created_at > now() - interval '7 days'
             when 'flagged' then exists (select 1 from reports r where r.status::text = 'open' and _target_user(r.target_type, r.target_id) = p.id)
             else true end),
  pg as (
    select row_number() over (order by
             case when p_sort = 'oldest' then f.created_at end asc,
             case when p_sort = 'followers' then f.follower_count end desc,
             case when p_sort = 'earnings' then f.earnings_cents end desc,
             case when p_sort = 'wallet' then f.wallet_cents end desc,
             f.created_at desc) as ord, f.*
      from f order by 1 limit p_limit offset p_offset)
  select (select count(*) from f),
         coalesce((select jsonb_agg(jsonb_build_object('id', pg.id, 'username', pg.username, 'display_name', pg.display_name,
             'account_type', pg.account_type, 'staff_role', pg.staff_role, 'age_verified', pg.age_verified, 'is_verified', pg.is_verified,
             'is_banned', pg.is_banned, 'created_at', pg.created_at, 'followers', pg.follower_count,
             'email', case when v_admin then (select u.email from auth.users u where u.id = pg.id) end,
             'wallet_cents', case when v_admin then pg.wallet_cents end,
             'earnings_cents', case when v_admin then pg.earnings_cents end) order by pg.ord) from pg), '[]'::jsonb)
    into v_total, v_rows;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $$;

revoke execute on function public.admin_nav_counts(), public.admin_find_users(text, text, text, int, int) from public, anon;
grant execute on function public.admin_nav_counts(), public.admin_find_users(text, text, text, int, int) to authenticated;
