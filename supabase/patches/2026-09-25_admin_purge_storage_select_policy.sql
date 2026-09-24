-- Storage remove requires SELECT visibility in addition to DELETE.
-- This grants visibility only to paths listed in the caller's active purge job.

drop policy if exists system_admin_purge_storage_select on storage.objects;
create policy system_admin_purge_storage_select
  on storage.objects
  for select
  to authenticated
  using (public.can_delete_account_purge_storage_object(bucket_id, name));
