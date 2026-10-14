-- 061: the reason a tournament champion did not get bonus Vibez (for example "the battles needed to raise at least £100 in gifts")
-- is only for the champion. Followers and the other creators only see who won and, if it was paid, the bonus.
-- The note is no longer in the tournament state unless you are the champion, it is not readable from the table, and the champion's notification carries it.

create or replace function public._tourney_json(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t live_tournaments%rowtype;
begin
  select * into t from live_tournaments where id = p_id;
  if not found then return null; end if;
  return jsonb_build_object('id', t.id, 'host', t.host_id, 'host_stream', t.host_stream, 'size', t.size, 'minutes', t.minutes, 'status', t.status,
    'round', t.round, 'rounds', t.rounds, 'next_at', t.next_at, 'champion', t.champion, 'bonus_vibez', t.bonus_vibez,
    'bonus_note', case when auth.uid() is not null and auth.uid() = t.champion then t.bonus_note end,
    'players', coalesce((select jsonb_agg(jsonb_build_object('creator_id', p.creator_id, 'username', pr.username, 'display_name', pr.display_name,
                'avatar_url', pr.avatar_url, 'stream_id', p.stream_id, 'status', p.status, 'pos', p.pos, 'seed', p.seed, 'out_round', p.out_round)
                order by coalesce(p.seed, 99), p.joined_at nulls last, p.invited_at)
              from live_tournament_players p join profiles pr on pr.id = p.creator_id where p.tournament_id = t.id), '[]'::jsonb),
    'battles', coalesce((select jsonb_agg(_battle_json(b) || jsonb_build_object('slot', b.slot) order by b.round, b.slot)
              from live_battles b where b.tournament_id = t.id), '[]'::jsonb),
    'now', clock_timestamp());
end $$;

do $$ begin
  execute 'revoke select on public.live_tournaments from authenticated';
  execute 'grant select (id, host_id, host_stream, size, minutes, rounds, status, round, next_at, created_at, started_at, ended_at, champion, bonus_vibez) on public.live_tournaments to authenticated';
end $$;

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
  perform _notify(p_champ, null, 'tournament_won', p_id, jsonb_build_object('vibez', v_amt, 'size', t.size, 'note', v_note));
end $$;

revoke execute on function public._tourney_json(uuid), public._tourney_award(uuid, uuid) from public, anon, authenticated;
