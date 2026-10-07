# OverVibez backend (Supabase)

Project: `overvibez-prod` (ref `ectwnzhuebgnvejdpgdk`, eu-west-2)
URL: https://ectwnzhuebgnvejdpgdk.supabase.co (publishable key is embedded in `index.html`; it is safe to ship — RLS enforces access)

Apply migrations in order: `001_core_schema.sql`, `002_storage_realtime.sql`, `003_post_id_and_creator_defaults.sql`.
(On `overvibez-prod` 001+003 were applied as one migration, `core_schema`, then `storage_realtime`.)

## Security model
- Clients can only write low-risk columns directly (column-level grants). Wallet, earnings, `age_verified`, post counters,
  subscriptions, unlocks, raffle entries, transactions and payouts are written only by SECURITY DEFINER functions.
- Money moves only through `purchase_post`, `subscribe_to_creator`, `tip_creator`, `buy_raffle_entries`, `request_payout`
  (85/15 split in `_settle`). All require `age_verified`.
- Paid media lives in the private `paid-media` bucket; storage RLS defers to `can_view_post()`.

## Invite-only beta, profiles and account safety (migration 010 + `features`, `delete-account` functions)
- **Sign-up is invite-only by default** and enforced in the database (the `handle_new_user` trigger), not just the form. Admins make
  codes in Admin console → **Invites** (single- or multi-use, optional expiry), can copy an invite *link* (`?invite=CODE` pre-fills sign-up),
  revoke codes, or switch invite-only off to open sign-up. Turning it off is a one-click admin action; existing users are never affected.
- Profile pictures/covers are stored in `public-media/<user id>/…`; `avatar_url`/`cover_url` hold a path that must be inside the user's
  own folder (database constraint), so a profile can never load an outside tracking URL. Photos are resized and re-encoded in the browser.
- Users can change their password, reset it by email, download their data (`export_my_data`) and delete their account (`delete-account`:
  refuses while money is owed either way or if they are the only admin; removes uploaded files; financial records are kept without a name).
- `features` (public) tells the app which integrations have secrets set, so Go live / Add funds / ID check are hidden or say "coming soon" until then.
- **Password-reset emails need Supabase's Site URL set** (Authentication → URL Configuration) to `https://grobler96.github.io/OverVibezApp/`.

## Staff roles (migration 007)
- `profiles.staff_role` is `moderator` or `admin`. Users cannot set it (no column grant); only an admin can change roles in the app
  (Admin console → Users → Set staff role), or you can set it directly in the Supabase SQL editor:
  `update profiles set staff_role = 'admin' where username = 'your.username';`
- Moderators: reports queue, remove/restore content, ban/unban users, user investigation. They cannot see money or run raffles.
- Admins: everything above plus stats, 18+/badge flags, wallet credits, payouts, raffles, staff roles and the audit log.
- Every staff action is written to `admin_actions`. Content removal is soft (`removed_at`) so evidence is kept.
- Banned users can still log in and read but cannot post, comment, message, like, follow or spend.
- `dev.creator` is currently an admin.

## Live streaming (migration 008 + `live-token` edge function)
Video is carried by **LiveKit Cloud**; our database decides who may broadcast or watch.
- Creators (verified) start a stream with `start_live_stream`; viewers of paid streams buy a ticket with `buy_live_ticket`
  (85/15 split like every other purchase); tips use `tip_creator`.
- The `live-token` edge function calls `live_access()` with the caller's own login, and only then mints a short-lived LiveKit
  token. Viewers get subscribe-only tokens (no publishing, no data); broadcasters may publish camera + microphone only.
- Chat is stored in `live_comments` (rate limited, moderated, ban-aware). A heartbeat every 30s detects crashed streams; if a
  moderator ends a stream, the broadcaster and viewers are cut off within about 30 seconds.
- **To switch it on:** create a LiveKit Cloud project, then in Supabase Dashboard → Edge Functions → Secrets add
  `LIVEKIT_URL` (wss://your-project.livekit.cloud), `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`. Until they exist the function
  answers `503 not_configured` and the app says "Live streaming is not switched on yet".
- Source: `supabase/functions/live-token/` (`token.js` is dependency-free and was verified against LiveKit's official SDK).

## Stripe (migration 009 + 3 edge functions)
- `create-topup`: signed-in, age-verified users pick $10/$25/$50/$100 and are sent to Stripe Checkout.
- `stripe-webhook`: Stripe calls this after payment. It verifies Stripe's signature (the authentication, so it is deployed without
  JWT checking), then credits the wallet exactly once via `credit_wallet_from_stripe()` (callable only by the service role; one row
  per Checkout session in `stripe_events`). Also records Stripe Identity results.
- `create-verification`: starts a Stripe Identity check (ID + selfie). The webhook reads the verified date of birth and only sets
  `age_verified` if the person is 18+; if the date of birth is unavailable it fails closed (not verified).
- **Secrets** (Supabase Dashboard → Edge Functions → Secrets): `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` (the endpoint's `whsec_…`).
  Optional: `SITE_URL` (default the GitHub Pages URL), `STRIPE_CURRENCY` (default `usd`). Without them the functions answer `503 not_configured`.
- Card payments use Stripe-hosted Checkout, so card details never touch our servers.
- **Going live checklist:** finish Stripe business verification, enable Stripe Identity in live mode, create a LIVE webhook endpoint
  (same URL, events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `identity.verification_session.verified`),
  replace the two secrets with live values, and change the "payments run in test mode" line on the signup screen.
- Not automated: refunds and chargebacks (handle in the Stripe dashboard; an admin can adjust balances), and creator payouts
  (Stripe Connect). Stripe's fee (~1.5%+20p UK cards / 2.9%+30c) comes out of the platform's 15%, not the creator's 85%.

## Following, Explore and notifications (migration 011)
- `profiles.follower_count` is kept by a trigger on `follows`; `profiles.category` is a creator-chosen category (10 fixed values).
- The **Following** feed tab shows your own posts plus creators you follow or subscribe to. Explore has Trending / New / Live / category tabs and name search via `search_people()` (min 2 characters, wildcards escaped, banned users hidden).
- `notifications` is written only by triggers (follow, subscribe/renew, tip, unlock, ticket, comment, like) and by `start_live_stream` (fan-out to up to 1000 followers), payout-paid and content-removed. Users can read only their own rows; `mark_notifications_read()` marks them read. The app polls every 30s and also listens over Realtime.

## Free giveaways (migration 012)
- **Campaign links** (`?campaign=CODE`) are invite codes with an entry allowance, so they work while the beta is invite-only. Created in Admin → Giveaways; sign-ups and entries are counted per campaign.
- **Free raffles** (`raffles.is_free`) cost nothing. A member can enter every free raffle, one entry each, via `claim_free_entry()` (the campaign's `entries_per_user` column is no longer used). It requires: joined through a campaign, email confirmed, not banned. Browsers cannot write `raffle_entries`; paid purchases are refused on free raffles.
- **Winners** are drawn with the same sealed-seed method. They add a UK delivery address (`submit_prize_address`, UK postcode checked, 14-day claim window); admins mark prizes posted. `admin_redraw_raffle` voids a non-responding or fake winner and draws the next number from the same seed.
- Not enforced by the database: 18+ is self-declared at sign-up (check the winner's ID before posting a prize). Sending sign-up emails at volume needs custom SMTP (e.g. Resend with a verified domain) configured in the Supabase dashboard.
- Quirk: the SQL console stalls on text containing `delete from` at the start of a statement; the redraw function builds that statement from two strings for that reason.

## Safety, appeals and legal pages (migration 013)
- **Block / mute** (`blocks`, `set_block`): a block ends any follow between the two people and is enforced by the database for following, commenting and messaging in both directions; a mute only hides content for the muter. The app also hides blocked/muted people's posts, comments, chats and search results.
- **Appeals** (`appeals`, `submit_appeal`, `admin_list_appeals`, `admin_resolve_appeal`): members can appeal a suspension or a removed post/comment (max 5 a day, one open per item). Staff answer in Admin → Appeals; accepting restores the content or lifts the ban (suspension appeals are admin-only) and notifies the member.
- **Reports**: illegal / under-18 / copyright reports sort to the top of the queue and are marked PRIORITY; copyright reports require details.
- **Support email**: set by an admin in Admin → Invites and shown under Help & contact (`public_settings()` returns it).
- **18+ entry screen** is a self-declaration stored in the browser; real age assurance remains the ID check.
- Pages: `terms.html` (now with free prize draw, blocking/appeals and copyright sections), `privacy.html` (cookies/local storage, giveaway and safety data), `guidelines.html`. All still need a solicitor's review and the bracketed company details filled in.

## Pounds, refunds and Connect payouts (migration 015 + `payouts`, updated `stripe-webhook`)
- **Currency is GBP** everywhere (`STRIPE_CURRENCY` now defaults to `gbp`; database messages were rewritten to £).
- **Top-up refunds and chargebacks** arrive from Stripe (`charge.refunded`, `charge.dispute.created`, `charge.dispute.closed`) and reverse the wallet credit. Whatever the member has already spent becomes a **debt** (`debts`), taken from their next top-up (or, for creators, their next sales) before anything else. A won dispute gives the money back and cancels the debt.
- **Staff refunds** (Admin → Users → Transactions & refunds, admins only) cover unlocks, subscriptions, tips and live tickets: the buyer gets the full amount, the creator's earnings are reduced, access is removed, and both are notified. Everything is audit-logged.
- **Connect payouts**: `payouts` edge function (`onboard`, `status`, `payout`). A creator sets up a Stripe Express account once; "Withdraw" then debits earnings (`request_payout`), sends a Stripe Transfer (idempotency key = payout id) and records it. If the transfer fails the earnings are put back automatically. Until the Stripe key is set the app falls back to manual payouts in the admin console.
- **To switch payouts on**: enable Connect in the Stripe dashboard (Settings → Connect, free), add `STRIPE_SECRET_KEY`, and fund the platform balance (top-ups land there; in test mode use card 4000 0000 0000 0077 for instantly-available test funds).
- The Stripe webhook endpoint must receive: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `identity.verification_session.verified`, `charge.refunded`, `charge.dispute.created`, `charge.dispute.closed`.

## App polish, errors and email (migration 016, `send-emails`)
- **Installable app (PWA)**: `manifest.webmanifest`, `sw.js` and `icons/`. The service worker keeps the app shell available offline (pages are network-first so a new release always shows up; Supabase/Stripe/LiveKit calls are never cached or touched). "Install the app" appears under Me. Icons, favicon and the share image (`og.png`) are generated from the OV mark; the share-image URL in `index.html` is absolute, so **update the two `grobler96.github.io` image URLs when the custom domain goes live**.
- **Landing page**: signed-out visitors see a short public page first; invite/giveaway links skip straight to sign-up.
- **Error monitoring**: browsers report uncaught errors to `log_client_error` (deduplicated, throttled, works signed out). Admins see them under Admin → Errors.
- **Email notifications**: important notifications (prize won/posted, refund, reversed top-up, appeal result, removal, payout sent) are queued in `email_queue` for members who have email notifications on (Me → Email notifications). The `send-emails` edge function sends them through Resend. It stays dormant (503) until these secrets exist: `RESEND_API_KEY`, `EMAIL_FROM` (an address on a domain verified in Resend) and `CRON_SECRET`.
- **To turn email sending on**: verify the domain in Resend, add the three secrets, then store the secret in the vault and schedule the sender once a minute:
  ```sql
  select vault.create_secret('<the same CRON_SECRET>', 'cron_secret');
  select cron.schedule('send-emails', '* * * * *', $$
    select net.http_post(url := 'https://<project-ref>.supabase.co/functions/v1/send-emails',
      headers := jsonb_build_object('x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')))
  $$);
  ```
  (`pg_cron` and `pg_net` are available; enable them under Database → Extensions first.)

## Not built yet (needed before launch)
- Automated bank payouts (Stripe Connect). Payouts are paid by hand and marked paid in the admin console. Admins can still mark a user 18+ verified by hand.
- Notifications, live recording/replays, and multi-guest streams. Terms/Privacy pages exist as lawyer-review drafts.
- Auth: decide whether email confirmation stays on (the app handles both).
