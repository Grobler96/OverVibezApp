# OverVibez launch runbook

What is built is live and tested. What is left is mostly **accounts and paperwork that only you can do**. Work top to bottom.

## 1. Blocked on business verification (you + your business partner)
- [ ] Verify the business with Stripe (Dashboard → Settings → Business).
- [ ] Turn on **Connect** (Express accounts) so creator payouts work.
- [ ] Add live keys as Supabase Edge Function secrets: `STRIPE_SECRET_KEY` (live), `STRIPE_WEBHOOK_SECRET` (live webhook endpoint → `stripe-webhook` function).
- [ ] Test once with a small real top-up, then refund it from Admin → Transactions.

## 2. Email (Resend)
- [ ] Verify your sending domain in Resend (add the DNS records it shows).
- [ ] Create a **sending-only** API key (replace any key that was ever shared in chat).
- [ ] Supabase secrets: `RESEND_API_KEY`, `EMAIL_FROM` (e.g. `OverVibez <hello@yourdomain>`), `CRON_SECRET`.
- [ ] Supabase → Auth → SMTP: use the same Resend details so sign-up confirmation emails come from your domain.
- [ ] Schedule the sender (SQL in `supabase/README.md`, "errors / email" section).

## 3. Supabase
- [ ] Upgrade to **Pro** (daily backups, no pausing, higher limits).
- [ ] Auth → Providers → Email: turn on **leaked password protection**.
- [ ] Auth → URL configuration: set Site URL and redirect URLs to the real domain.
- [ ] Delete dev/test accounts and change the dev admin password; make sure only your real account is admin.

## 4. Live streaming
- [ ] Create a LiveKit Cloud project; set `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` as secrets.

## 5. Legal and compliance (needs a solicitor)
- [ ] Have Terms, Privacy and Guidelines reviewed; fill the bracketed company details.
- [ ] Register with the ICO (data protection fee).
- [ ] Get gambling-law advice **before** running any paid raffle (free giveaways are the safe starting point).
- [ ] Check Online Safety Act duties for adult content, and your age/identity verification provider.
- [ ] Put a real support email in Admin → Invites (settings).

## 6. Domain
- [ ] Buy/point a domain at GitHub Pages (Settings → Pages → Custom domain, enforce HTTPS).
- [ ] Update the absolute `og:image` / `og:url` addresses in `index.html` from `grobler96.github.io` to the new domain.

## 7. Day-one checks
- [ ] Sign up with a fresh email: confirm email arrives, age gate works.
- [ ] Create a free raffle with a photo; enter it from a second account; run the live draw and announce.
- [ ] Check Admin → Errors is empty after a click-through.
- [ ] Run Supabase advisors (security + performance) again.

## Already handled in code
Row-level security everywhere, locked-down money functions, 85/15 split, refunds/chargebacks/debts, provably fair raffles with public verification, block/mute, appeals, error monitoring, PWA, GBP, advisor fixes (migration 021).
Remaining advisor warnings are intentional: public RPCs for signed-out pages (raffle proof, invite check) and signed-in RPCs that check permissions inside.
