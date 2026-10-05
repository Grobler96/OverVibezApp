-- Clients choose the post id so media can be uploaded to {creator_id}/{post_id}/... before/after the insert.
grant insert (id) on public.posts to authenticated;

-- New creators start with a default subscription price ($4.99) so they are subscribable immediately.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_type account_type := coalesce((new.raw_user_meta_data->>'account_type')::account_type, 'follower');
begin
  insert into public.profiles (id, username, display_name, account_type, sub_price_cents)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', 'user_' || left(new.id::text, 8)),
    coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'username'),
    v_type,
    case when v_type = 'creator' then 499 end
  );
  return new;
end $$;
