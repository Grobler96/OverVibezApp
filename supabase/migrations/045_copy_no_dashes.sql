-- 045: plain-English wording. Rewrites the messages members see from database functions (errors and email text) so they
-- no longer use long dashes: sentences are split with full stops or commas and number ranges read "1 to 3".
-- It rewrites each affected function from its own current definition, so it is safe to run more than once.
do $$
declare r record; d text; pr text[][] := array[
  ['Admins cannot be banned — remove','Admins cannot be banned. Remove'],
  ['No entries — nothing to draw','No entries, nothing to draw'],
  ['Good news — your prize','Good news, your prize'],
  ['accepted it — the decision has been put right.','accepted it, and the decision has been put right.'],
  ['and cancel — you keep access','and cancel. You keep access'],
  ['switched off — all raffles are free to enter','switched off. All raffles are free to enter'],
  ['switched off — free giveaways only','switched off, free giveaways only'],
  ['Write a short reply — the member will see it','Write a short reply. The member will see it'],
  ['still holds % — spend it','still holds %. Spend it'],
  ['pending payout — request a payout','pending payout. Request a payout'],
  ['the only admin — make someone','the only admin. Make someone'],
  ['switched off — please request','switched off. Please request'],
  ['address first — check your inbox','address first. Check your inbox'],
  ['free post — it cannot','free post. It cannot'],
  ['waiting — wait for some','waiting. Wait for some'],
  ['subscribers only — subscribe to','subscribers only. Subscribe to'],
  ['request waiting — we will be in touch','request waiting. We will be in touch'],
  ['requests today — please try again','requests today. Please try again'],
  ['Too many tries — please wait','Too many tries. Please wait'],
  ['too fast — slow down','too fast. Slow down'],
  ['Posting limit reached — try again','Posting limit reached. Try again'],
  ['reports submitted — try again','reports submitted. Try again'],
  ['drafts — publish or delete','drafts. Publish or delete'],
  ['too long — please keep it','too long. Please keep it'],
  ['a lot today — we will get back','a lot today. We will get back'],
  ['for this — we will reply soon','for this. We will reply soon'],
  ['appeals today — please wait','appeals today. Please wait'],
  ['has closed — contact support','has closed. Contact support'],
  ['postcode — prizes are sent','postcode. Prizes are sent']];
  i int;
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.prokind = 'f' and (p.prosrc like '%—%' or p.prosrc like '%–%') loop
    d := pg_get_functiondef(r.oid);
    for i in 1 .. array_length(pr, 1) loop d := replace(d, pr[i][1], pr[i][2]); end loop;
    d := regexp_replace(d, '([0-9])–([£0-9])', '\1 to \2', 'g');
    d := replace(d, ' — ', ', ');
    execute d;
  end loop;
end $$;
