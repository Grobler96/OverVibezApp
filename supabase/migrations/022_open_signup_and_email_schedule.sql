-- 022: what was switched on in production at launch prep.
-- * Sign-up is open (no invite code needed). Giveaway links still work and are still credited to their campaign.
--   Turn invite-only back on any time from Admin -> Invites.
-- * The email sender runs once a minute. The shared secret itself is NOT in this file: create it once with
--     select vault.create_secret('<the same value as the CRON_SECRET function secret>', 'cron_secret');
--   (see supabase/README.md). The schedule below is skipped until that vault secret exists.

insert into public.app_settings(key, value) values ('invite_only', 'false'::jsonb)
  on conflict (key) do update set value = excluded.value;

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

do $$ begin
  if exists (select 1 from vault.decrypted_secrets where name = 'cron_secret') and not exists (select 1 from cron.job where jobname = 'send-emails') then
    perform cron.schedule('send-emails', '* * * * *', $job$
      select net.http_post(url := 'https://ectwnzhuebgnvejdpgdk.supabase.co/functions/v1/send-emails',
        headers := jsonb_build_object('x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')))
    $job$);
  end if;
end $$;
