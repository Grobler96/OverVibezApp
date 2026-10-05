# Previous OVAPP schema (replaced 2026-10-05)

The Supabase project `OVAPP` (tjwadjqyuxkwgrtsbgez) was created in June 2026 with a different,
never-used schema (0 users, 0 rows). It was replaced by `supabase/migrations/001..003`.
Its six original migrations remain in `supabase_migrations.schema_migrations`:

- 20260626100337 create_profiles_and_auth
- 20260626100350 create_posts_and_media
- 20260626100407 create_subscriptions_and_payments
- 20260626100416 create_messaging
- 20260626100432 create_live_streams_and_raffles
- 20260626100447 create_notifications_and_storage

Design differences worth remembering if you revisit them:
- Amounts were `numeric(10,2)` in GBP with Stripe ids on profiles/subscriptions/payments/payouts
  (direct card payments, no wallet). The new schema uses integer cents, a USD wallet and an 85/15 split.
- It had `notifications`, `age_verifications`, `live_stream_tickets`, `live_comments` and a
  `creator_earnings_summary` view. These are NOT in the new schema yet.
- Known problems: users could update their own `is_age_verified` / `total_earnings` via the profiles
  UPDATE policy; `post_unlocks`, `subscriptions` and `raffle_entries` accepted client INSERTs with no
  payment; `draw_raffle_winner()` was executable by `anon`; the earnings view was SECURITY DEFINER.
