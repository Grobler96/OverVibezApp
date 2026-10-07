-- 018: winner celebrations and announcements.
-- * mark_notification_read(): lets the app dismiss a single notification (the "You won!" pop-up).
-- * the draw now also tells everyone else who entered who won ('raffle_result').

create or replace function public.mark_notification_read(p_id uuid) returns void
language sql security definer set search_path = public as $$
  update notifications set read_at = now() where id = p_id and user_id = auth.uid() and read_at is null;
$$;
revoke execute on function public.mark_notification_read(uuid) from public, anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;

create or replace function public.admin_draw_raffle(p_raffle uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r raffles%rowtype; v_winner uuid; v_user uuid; v_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select * into r from raffles where id = p_raffle for update;
  if not found then raise exception 'Raffle not found'; end if;
  if r.winner_entry_id is not null then raise exception 'Already drawn'; end if;
  if r.closes_at > now() then raise exception 'The raffle has not closed yet'; end if;
  v_winner := _pick_winner(p_raffle, 0);
  if v_winner is null then raise exception 'No entries — nothing to draw'; end if;
  update raffles set winner_entry_id = v_winner, revealed_seed = (select seed from raffle_secrets where raffle_id = p_raffle),
         claim_by = case when is_free then now() + interval '14 days' end where id = p_raffle;
  select e.user_id, p.username into v_user, v_name from raffle_entries e join profiles p on p.id = e.user_id where e.id = v_winner;
  perform _log('raffle_draw', v_user, jsonb_build_object('raffle', p_raffle));
  insert into notifications(user_id, actor_id, type, ref_id, data) values (v_user, null, 'won', p_raffle, jsonb_build_object('title', r.title, 'prize', r.prize, 'free', r.is_free));
  -- everyone else who entered is told who won (the draw can be checked from the Raffles page)
  insert into notifications(user_id, actor_id, type, ref_id, data)
    select u.user_id, null::uuid, 'raffle_result', p_raffle, jsonb_build_object('title', r.title, 'prize', r.prize, 'winner', v_name)
    from (select distinct e.user_id from raffle_entries e where e.raffle_id = p_raffle and e.user_id <> v_user limit 5000) u;
end $$;
