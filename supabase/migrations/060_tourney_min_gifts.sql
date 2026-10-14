-- 060: a tournament only pays its champion bonus Vibez if the battles raised at least £100 in gifts in total
-- (it was £10). Setting: tourney_min_cents (10000 = £100).
insert into public.app_settings(key, value) values ('tourney_min_cents', to_jsonb(10000)) on conflict (key) do update set value = excluded.value;

create or replace function public._tourney_award(p_id uuid, p_champ uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t live_tournaments%rowtype; v_amt bigint; v_note text; v_cents bigint; v_min int := _ref_int('tourney_min_cents', 10000);
begin
  select * into t from live_tournaments where id = p_id;
  v_amt := _ref_int('tourney_bonus_' || t.size, case t.size when 8 then 20000 else 10000 end);
  select coalesce(sum(coalesce(score_a, 0) + coalesce(score_b, 0)), 0) into v_cents from live_battles where tournament_id = p_id and status = 'ended';
  if exists (select 1 from profiles where id = p_champ and is_banned) then v_amt := 0; v_note := 'Account restricted';
  elsif v_cents < v_min then v_amt := 0; v_note := 'The battles needed to raise at least £' || (v_min / 100) || ' in gifts for a bonus';
  elsif (select count(*) from lb_ledger where creator_id = p_champ and kind = 'tournament_bonus' and created_at > now() - interval '7 days') >= _ref_int('tourney_weekly_max', 2) then
    v_amt := 0; v_note := 'Weekly tournament bonus limit reached';
  end if;
  if v_amt > 0 then
    insert into lb_ledger(creator_id, kind, vibez, month_key, week_start, note) values (p_champ, 'tournament_bonus', v_amt, _lb_month(now()), _lb_week_start(now()), 'Tournament winner (' || t.size || ' creators)');
    perform _log('tournament_bonus', p_champ, jsonb_build_object('tournament', p_id, 'vibez', v_amt, 'gifts_cents', v_cents));
  end if;
  update live_tournaments set bonus_vibez = v_amt, bonus_note = v_note where id = p_id;
  perform _notify(p_champ, null, 'tournament_won', p_id, jsonb_build_object('vibez', v_amt, 'size', t.size));
end $$;
revoke execute on function public._tourney_award(uuid, uuid) from public, anon, authenticated;
