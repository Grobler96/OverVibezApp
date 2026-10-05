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

## Not built yet (needed before launch)
- Automatic ID verification: until a provider is connected, an admin marks users 18+ verified by hand (Users → Mark 18+ verified).
- Wallet top-ups (Stripe webhook that credits `wallet_cents` and logs a `wallet_topup` transaction) and automated bank payouts (Stripe Connect). Payouts are paid by hand and marked paid in the admin console.
- Live streaming and notifications. Terms/Privacy pages exist as lawyer-review drafts.
- Auth: decide whether email confirmation stays on (the app handles both).
