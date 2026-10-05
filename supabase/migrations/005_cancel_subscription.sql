-- Cancelling keeps access until the paid period ends.
create or replace function public.can_view_post(p_post_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from posts p
    where p.id = p_post_id
      and (
        p.is_paid = false
        or p.creator_id = auth.uid()
        or exists (select 1 from post_unlocks u where u.post_id = p.id and u.user_id = auth.uid())
        or exists (select 1 from subscriptions s where s.creator_id = p.creator_id
                     and s.subscriber_id = auth.uid() and s.status in ('active','canceled')
                     and s.current_period_end > now())
      )
  );
$$;

create or replace function public.cancel_subscription(p_creator uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update subscriptions set status = 'canceled'
    where subscriber_id = auth.uid() and creator_id = p_creator and status = 'active' and current_period_end > now();
  if not found then raise exception 'No active subscription to cancel'; end if;
end $$;
revoke execute on function public.cancel_subscription(uuid) from public, anon;
grant execute on function public.cancel_subscription(uuid) to authenticated;
