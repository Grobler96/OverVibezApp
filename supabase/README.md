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

## Not built yet (needed before launch)
- Automated bank payouts (Stripe Connect). Payouts are paid by hand and marked paid in the admin console. Admins can still mark a user 18+ verified by hand.
- Notifications, live recording/replays, and multi-guest streams. Terms/Privacy pages exist as lawyer-review drafts.
- Auth: decide whether email confirmation stays on (the app handles both).
