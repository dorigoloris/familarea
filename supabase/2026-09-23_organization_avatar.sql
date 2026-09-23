begin;

alter table public.organizations
  add column if not exists avatar_path text;

create or replace function public.update_my_organization_avatar(p_avatar_path text default null)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v public.organizations%rowtype;
begin
  update public.organizations
  set avatar_path = nullif(btrim(coalesce(p_avatar_path, '')), '')
  where id = public.current_organization()
  returning * into v;

  if v.id is null then raise exception 'invalid organization'; end if;
  if v.avatar_path is not null and v.avatar_path <> v.id::text || '/avatar' then
    raise exception 'invalid avatar path';
  end if;

  return to_jsonb(v) - 'account_id';
end;
$$;

create or replace function public.can_manage_organization_avatar_storage_path(p_path text)
returns boolean
language sql
security definer
stable
set search_path=public,pg_temp
as $$
  select exists (
    select 1
    from public.accounts a
    join public.organizations o on o.account_id = a.id
    where a.auth_user_id = auth.uid()
      and a.account_type = 'organization'
      and p_path = o.id::text || '/avatar'
  );
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'organization-avatars',
  'organization-avatars',
  false,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists organization_avatars_select_own on storage.objects;
drop policy if exists organization_avatars_insert_own on storage.objects;
drop policy if exists organization_avatars_update_own on storage.objects;
drop policy if exists organization_avatars_delete_own on storage.objects;

create policy organization_avatars_select_own
  on storage.objects for select to authenticated
  using (bucket_id = 'organization-avatars' and public.can_manage_organization_avatar_storage_path(name));

create policy organization_avatars_insert_own
  on storage.objects for insert to authenticated
  with check (bucket_id = 'organization-avatars' and public.can_manage_organization_avatar_storage_path(name));

create policy organization_avatars_update_own
  on storage.objects for update to authenticated
  using (bucket_id = 'organization-avatars' and public.can_manage_organization_avatar_storage_path(name))
  with check (bucket_id = 'organization-avatars' and public.can_manage_organization_avatar_storage_path(name));

create policy organization_avatars_delete_own
  on storage.objects for delete to authenticated
  using (bucket_id = 'organization-avatars' and public.can_manage_organization_avatar_storage_path(name));

alter function public.update_my_organization_avatar(text) owner to postgres;
alter function public.can_manage_organization_avatar_storage_path(text) owner to postgres;
revoke all on function public.update_my_organization_avatar(text), public.can_manage_organization_avatar_storage_path(text) from public, anon;
grant execute on function public.update_my_organization_avatar(text), public.can_manage_organization_avatar_storage_path(text) to authenticated;

commit;
