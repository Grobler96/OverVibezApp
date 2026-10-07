-- 021: hardening from the Supabase advisors (security + performance).
-- * fixed search_path on _money
-- * covering indexes for foreign keys (faster joins/deletes)
-- * RLS policies evaluate auth.uid() once per query instead of once per row
-- * invite_redemptions gets a primary key

alter function public._money(bigint) set search_path = public;

alter table public.invite_redemptions drop constraint if exists invite_redemptions_user_id_key;
alter table public.invite_redemptions add primary key (user_id);

create index if not exists raffle_voids_user_id_fk on public.raffle_voids (user_id);
create index if not exists raffles_host_id_fk on public.raffles (host_id);
create index if not exists reports_reporter_id_fk on public.reports (reporter_id);
create index if not exists reports_resolved_by_fk on public.reports (resolved_by);
create index if not exists admin_actions_admin_id_fk on public.admin_actions (admin_id);
create index if not exists live_comments_user_id_fk on public.live_comments (user_id);
create index if not exists invite_codes_created_by_fk on public.invite_codes (created_by);
create index if not exists invite_redemptions_code_fk on public.invite_redemptions (code);
create index if not exists notifications_actor_id_fk on public.notifications (actor_id);
create index if not exists campaigns_created_by_fk on public.campaigns (created_by);
create index if not exists prize_claims_user_id_fk on public.prize_claims (user_id);
create index if not exists blocks_blocked_id_fk on public.blocks (blocked_id);
create index if not exists appeals_user_id_fk on public.appeals (user_id);
create index if not exists appeals_resolved_by_fk on public.appeals (resolved_by);
create index if not exists stripe_topups_user_id_fk on public.stripe_topups (user_id);
create index if not exists client_errors_user_id_fk on public.client_errors (user_id);
create index if not exists email_queue_user_id_fk on public.email_queue (user_id);

alter policy profiles_update on public.profiles using (((select auth.uid()) = id)) with check ((((select auth.uid()) = id) AND ((sub_price_cents IS NULL) OR (account_type = 'creator'::account_type))));
alter policy follows_delete on public.follows using (((select auth.uid()) = follower_id));
alter policy subs_read on public.subscriptions using ((((select auth.uid()) = subscriber_id) OR ((select auth.uid()) = creator_id)));
alter policy posts_update on public.posts using (((select auth.uid()) = creator_id));
alter policy posts_delete on public.posts using (((select auth.uid()) = creator_id));
alter policy entries_read on public.raffle_entries using (((select auth.uid()) = user_id));
alter policy unlocks_read on public.post_unlocks using ((((select auth.uid()) = user_id) OR ((select auth.uid()) IN (SELECT posts.creator_id FROM posts WHERE (posts.id = post_unlocks.post_id)))));
alter policy likes_delete on public.likes using (((select auth.uid()) = user_id));
alter policy comments_delete on public.comments using (((select auth.uid()) = user_id));
alter policy stories_delete on public.stories using (((select auth.uid()) = creator_id));
alter policy tx_read on public.transactions using ((((select auth.uid()) = payer_id) OR ((select auth.uid()) = payee_id)));
alter policy likes_insert on public.likes with check ((((select auth.uid()) = user_id) AND not_banned()));
alter policy comments_insert on public.comments with check ((((select auth.uid()) = user_id) AND not_banned() AND (NOT is_blocked_between(user_id, (SELECT p.creator_id FROM posts p WHERE (p.id = comments.post_id))))));
alter policy streams_update on public.live_streams using (((select auth.uid()) = creator_id));
alter policy conv_read on public.conversations using ((((select auth.uid()) = user_a) OR ((select auth.uid()) = user_b)));
alter policy msg_mark_read on public.messages using (((sender_id <> (select auth.uid())) AND (EXISTS (SELECT 1 FROM conversations c WHERE ((c.id = messages.conversation_id) AND (((select auth.uid()) = c.user_a) OR ((select auth.uid()) = c.user_b)))))));
alter policy msg_insert on public.messages with check ((((select auth.uid()) = sender_id) AND not_banned() AND (EXISTS (SELECT 1 FROM conversations c WHERE ((c.id = messages.conversation_id) AND (((select auth.uid()) = c.user_a) OR ((select auth.uid()) = c.user_b)) AND (NOT is_blocked_between(c.user_a, c.user_b)))))));
alter policy payouts_read on public.payouts using (((select auth.uid()) = creator_id));
alter policy reports_insert on public.reports with check (((select auth.uid()) = reporter_id));
alter policy reports_read on public.reports using (((select auth.uid()) = reporter_id));
alter policy stories_insert on public.stories with check ((((select auth.uid()) = creator_id) AND is_verified_creator()));
alter policy posts_insert on public.posts with check ((((select auth.uid()) = creator_id) AND is_verified_creator()));
alter policy streams_insert on public.live_streams with check ((((select auth.uid()) = creator_id) AND is_verified_creator()));
alter policy msg_read on public.messages using (((removed_at IS NULL) AND (EXISTS (SELECT 1 FROM conversations c WHERE ((c.id = messages.conversation_id) AND (((select auth.uid()) = c.user_a) OR ((select auth.uid()) = c.user_b)))))));
alter policy live_tickets_read on public.live_tickets using (((select auth.uid()) = user_id));
alter policy live_comments_insert on public.live_comments with check ((((select auth.uid()) = user_id) AND not_banned() AND live_can_watch(stream_id) AND (EXISTS (SELECT 1 FROM live_streams s WHERE ((s.id = live_comments.stream_id) AND (s.status = 'live'::live_status))))));
alter policy notifications_read_own on public.notifications using (((select auth.uid()) = user_id));
alter policy prize_claims_own on public.prize_claims using (((select auth.uid()) = user_id));
alter policy blocks_read_own on public.blocks using (((select auth.uid()) = blocker_id));
alter policy follows_insert on public.follows with check ((((select auth.uid()) = follower_id) AND not_banned() AND (NOT is_blocked_between(follower_id, creator_id))));
alter policy appeals_read_own on public.appeals using (((select auth.uid()) = user_id));
alter policy debts_read_own on public.debts using (((select auth.uid()) = user_id));
