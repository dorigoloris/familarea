-- FamilArea next Storage. LOCAL DESIGN ONLY: do not apply to the current project.
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('profile-avatars','profile-avatars',false,5242880,array['image/jpeg','image/png','image/webp']),
 ('familarea-attachments','familarea-attachments',false,10485760,array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
-- Paths are server-validated: avatars/<personal-account-id>/<opaque-file-name> and
-- attachments/<current-account-id>/<target-type>/<target-id>/<opaque-file-name>.
create function public.can_manage_own_avatar_path(p_path text) returns boolean language sql security definer stable set search_path=public,pg_temp as $$
  select public.current_account_type()='personal'
     and split_part(p_path,'/',1)='avatars'
     and split_part(p_path,'/',2)=public.require_personal_account()::text
     and array_length(string_to_array(p_path,'/'),1)=3
$$;
revoke all on function public.can_manage_own_avatar_path(text) from public;
alter function public.can_manage_own_avatar_path(text) owner to postgres;
-- Storage RLS evaluates these helpers as the authenticated caller; grant only
-- EXECUTE so the helpers can enforce their own account/target checks.
grant execute on function public.can_manage_own_avatar_path(text) to authenticated;
grant execute on function public.can_access_attachment_path(text,boolean) to authenticated;

drop policy if exists profile_avatars_select on storage.objects;
drop policy if exists profile_avatars_insert on storage.objects;
drop policy if exists profile_avatars_update on storage.objects;
drop policy if exists profile_avatars_delete on storage.objects;
create policy profile_avatars_select on storage.objects for select to authenticated using (bucket_id='profile-avatars' and public.can_manage_own_avatar_path(name));
create policy profile_avatars_insert on storage.objects for insert to authenticated with check (bucket_id='profile-avatars' and public.can_manage_own_avatar_path(name));
create policy profile_avatars_update on storage.objects for update to authenticated using (bucket_id='profile-avatars' and public.can_manage_own_avatar_path(name)) with check (bucket_id='profile-avatars' and public.can_manage_own_avatar_path(name));
create policy profile_avatars_delete on storage.objects for delete to authenticated using (bucket_id='profile-avatars' and public.can_manage_own_avatar_path(name));

drop policy if exists familarea_attachments_select on storage.objects;
drop policy if exists familarea_attachments_insert on storage.objects;
drop policy if exists familarea_attachments_update on storage.objects;
drop policy if exists familarea_attachments_delete on storage.objects;
create policy familarea_attachments_select on storage.objects for select to authenticated using (bucket_id='familarea-attachments' and public.can_access_attachment_path(name,false));
create policy familarea_attachments_insert on storage.objects for insert to authenticated with check (bucket_id='familarea-attachments' and public.can_access_attachment_path(name,true));
create policy familarea_attachments_update on storage.objects for update to authenticated using (bucket_id='familarea-attachments' and public.can_access_attachment_path(name,true)) with check (bucket_id='familarea-attachments' and public.can_access_attachment_path(name,true));
create policy familarea_attachments_delete on storage.objects for delete to authenticated using (bucket_id='familarea-attachments' and public.can_access_attachment_path(name,true));
commit;
