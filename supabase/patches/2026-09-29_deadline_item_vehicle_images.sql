-- FamilArea — private optional images for vehicle deadline items.

begin;

alter table public.deadline_items
  add column if not exists image_path text null;

create or replace function public.can_read_my_deadline_item_image_path(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_path is not null and exists (
    select 1
    from public.accounts a
    join public.deadline_items di on di.owner_account_id = a.id
    where a.auth_user_id = auth.uid()
      and a.account_type = 'personal'
      and p_path = a.id::text || '/' || di.id::text || '/image'
  )
$$;

create or replace function public.can_manage_my_deadline_item_image_path(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.can_read_my_deadline_item_image_path(p_path)
$$;

create or replace function public.set_my_deadline_item_image(
  p_item_id uuid,
  p_image_path text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
  v_expected_path text := v_account_id::text || '/' || p_item_id::text || '/image';
  v_item public.deadline_items%rowtype;
begin
  perform public.assert_my_deadline_item(p_item_id);

  if p_image_path is not null and p_image_path <> v_expected_path then
    raise exception 'invalid deadline item image path';
  end if;

  update public.deadline_items di
  set image_path = p_image_path,
      updated_at = now()
  where di.id = p_item_id
    and di.owner_account_id = v_account_id
  returning di.* into v_item;

  if not found then
    raise exception 'deadline item unavailable';
  end if;

  return to_jsonb(v_item);
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'deadline-item-images',
  'deadline-item-images',
  false,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists deadline_item_images_select_authorized on storage.objects;
drop policy if exists deadline_item_images_insert_authorized on storage.objects;
drop policy if exists deadline_item_images_update_authorized on storage.objects;
drop policy if exists deadline_item_images_delete_authorized on storage.objects;

create policy deadline_item_images_select_authorized
on storage.objects for select to authenticated
using (
  bucket_id = 'deadline-item-images'
  and public.can_read_my_deadline_item_image_path(name)
);

create policy deadline_item_images_insert_authorized
on storage.objects for insert to authenticated
with check (
  bucket_id = 'deadline-item-images'
  and public.can_manage_my_deadline_item_image_path(name)
);

create policy deadline_item_images_update_authorized
on storage.objects for update to authenticated
using (
  bucket_id = 'deadline-item-images'
  and public.can_manage_my_deadline_item_image_path(name)
)
with check (
  bucket_id = 'deadline-item-images'
  and public.can_manage_my_deadline_item_image_path(name)
);

create policy deadline_item_images_delete_authorized
on storage.objects for delete to authenticated
using (
  bucket_id = 'deadline-item-images'
  and public.can_manage_my_deadline_item_image_path(name)
);

alter function public.can_read_my_deadline_item_image_path(text) owner to postgres;
alter function public.can_manage_my_deadline_item_image_path(text) owner to postgres;
alter function public.set_my_deadline_item_image(uuid,text) owner to postgres;

revoke all on function public.can_read_my_deadline_item_image_path(text), public.can_manage_my_deadline_item_image_path(text) from public, anon, authenticated;
revoke all on function public.set_my_deadline_item_image(uuid,text) from public, anon;
grant execute on function public.set_my_deadline_item_image(uuid,text) to authenticated;

commit;
