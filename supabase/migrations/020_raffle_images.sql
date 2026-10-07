-- 020: prize photos on raffles and giveaways. The image itself lives in the public-media bucket (in the admin's own folder);
-- the raffle only stores its path, and only an admin can set it.
alter table public.raffles add column if not exists image_path text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'raffles_image_path_len') then
    alter table public.raffles add constraint raffles_image_path_len check (image_path is null or length(image_path) <= 200);
  end if;
end $$;

-- Returns the old path so the app can tidy it away.
create or replace function public.admin_set_raffle_image(p_raffle uuid, p_path text) returns text
language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_path is not null and p_path !~ ('^' || auth.uid()::text || '/raffles/[A-Za-z0-9._-]+\.(jpg|jpeg|png|webp)$') then raise exception 'That is not a valid image location'; end if;
  select image_path into v_old from raffles where id = p_raffle for update;
  if not found then raise exception 'Raffle not found'; end if;
  update raffles set image_path = p_path where id = p_raffle;
  perform _log('raffle_image', null, jsonb_build_object('raffle', p_raffle, 'set', p_path is not null));
  return v_old;
end $$;
revoke execute on function public.admin_set_raffle_image(uuid,text) from public, anon;
grant execute on function public.admin_set_raffle_image(uuid,text) to authenticated;
