-- 039: keep the whole cover photo.
-- The cover banner is a 3:1 crop the creator frames, which throws away the rest of the photo. We now also keep the full photo (resized, with hidden camera data
-- removed) so tapping a cover shows the whole picture. Covers set before this have no full copy and fall back to the banner.
alter table public.profiles add column if not exists cover_full_url text;
alter table public.profiles add constraint profiles_cover_full_own_path check (cover_full_url is null or (length(cover_full_url) <= 200 and cover_full_url like id::text || '/%'));
grant select (cover_full_url) on public.profiles to anon, authenticated;   -- like the other profile photo columns
grant update (cover_full_url) on public.profiles to authenticated;
