-- FamilArea — immagini di copertina per Area.
-- Verificata contro lo schema remoto del progetto FamilArea.

begin;

alter table public.areas add column if not exists image_path text;

create or replace function public.update_area_image(p_area_id uuid, p_image_path text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v public.areas%rowtype;
begin
  perform public.require_area_manage(p_area_id);
  update public.areas set image_path = nullif(btrim(coalesce(p_image_path, '')), '') where id = p_area_id returning * into v;
  if v.id is null then raise exception 'invalid area'; end if;
  if v.image_path is not null and v.image_path <> v.id::text || '/cover' then raise exception 'invalid area image path'; end if;
  return to_jsonb(v);
end;
$$;

create or replace function public.can_read_area_image_storage_path(p_path text)
returns boolean language sql security definer stable set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.areas a
    where p_path = a.id::text || '/cover'
      and (public.is_area_owner(a.id) or public.is_area_member(a.id))
  );
$$;

create or replace function public.can_manage_area_image_storage_path(p_path text)
returns boolean language sql security definer stable set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.areas a
    where p_path = a.id::text || '/cover'
      and public.can_manage_area(a.id)
  );
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('area-images', 'area-images', false, 5242880, array['image/jpeg', 'image/png', 'image/webp']::text[])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists area_images_select_readable on storage.objects;
drop policy if exists area_images_insert_manageable on storage.objects;
drop policy if exists area_images_update_manageable on storage.objects;
drop policy if exists area_images_delete_manageable on storage.objects;

create policy area_images_select_readable on storage.objects for select to authenticated
  using (bucket_id = 'area-images' and public.can_read_area_image_storage_path(name));
create policy area_images_insert_manageable on storage.objects for insert to authenticated
  with check (bucket_id = 'area-images' and public.can_manage_area_image_storage_path(name));
create policy area_images_update_manageable on storage.objects for update to authenticated
  using (bucket_id = 'area-images' and public.can_manage_area_image_storage_path(name))
  with check (bucket_id = 'area-images' and public.can_manage_area_image_storage_path(name));
create policy area_images_delete_manageable on storage.objects for delete to authenticated
  using (bucket_id = 'area-images' and public.can_manage_area_image_storage_path(name));

-- get_area() restituisce già to_jsonb(areas), quindi eredita image_path.
-- get_my_areas() espone un JSON selettivo e va estesa senza cambiare la firma.
create or replace function public.get_my_areas()
returns setof jsonb language sql security definer stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', a.id, 'name', a.name, 'area_type', a.area_type,
    'description', a.description, 'image_path', a.image_path,
    'role', case when a.owner_account_id = public.current_account_id() then 'owner' else am.role::text end
  )
  from public.areas a
  left join public.area_memberships am on am.area_id = a.id and am.profile_id = public.current_personal_profile_or_null()
  where a.owner_account_id = public.current_account_id() or am.profile_id is not null
  order by a.name;
$$;

alter function public.update_area_image(uuid, text) owner to postgres;
alter function public.can_read_area_image_storage_path(text) owner to postgres;
alter function public.can_manage_area_image_storage_path(text) owner to postgres;
alter function public.get_my_areas() owner to postgres;
revoke all on function public.update_area_image(uuid, text), public.can_read_area_image_storage_path(text), public.can_manage_area_image_storage_path(text), public.get_my_areas() from public, anon;
grant execute on function public.update_area_image(uuid, text), public.can_read_area_image_storage_path(text), public.can_manage_area_image_storage_path(text), public.get_my_areas() to authenticated;

commit;
