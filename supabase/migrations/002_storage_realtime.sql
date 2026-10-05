-- OverVibez storage buckets + realtime. Apply as migration 2 of 2.
-- Path convention: {creator_id}/{post_id}/{filename}

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('public-media', 'public-media', true,  52428800, array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/quicktime','video/webm']),
  ('paid-media',   'paid-media',   false, 524288000, array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/quicktime','video/webm'])
on conflict (id) do nothing;

create policy "media_upload_own_folder" on storage.objects for insert to authenticated
  with check (bucket_id in ('public-media','paid-media') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "media_update_own_folder" on storage.objects for update to authenticated
  using (bucket_id in ('public-media','paid-media') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "media_delete_own_folder" on storage.objects for delete to authenticated
  using (bucket_id in ('public-media','paid-media') and (storage.foldername(name))[1] = auth.uid()::text);

-- Paid media is readable by the owner, or by anyone for whom can_view_post() is true.
create policy "paid_media_read" on storage.objects for select to authenticated
  using (
    bucket_id = 'paid-media' and (
      (storage.foldername(name))[1] = auth.uid()::text
      or case when (storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then public.can_view_post(((storage.foldername(name))[2])::uuid) else false end
    )
  );

alter publication supabase_realtime add table public.messages;
