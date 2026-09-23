begin;

alter table public.organizations
  add column if not exists dashboard_cover_path text;

create or replace function public.update_my_organization_name(p_name text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.organizations%rowtype;
begin
  if char_length(btrim(coalesce(p_name, ''))) = 0 then raise exception 'organization name is required'; end if;
  if char_length(btrim(p_name)) > 120 then raise exception 'organization name is too long'; end if;
  update public.organizations set name = btrim(p_name) where id = public.current_organization() returning * into v;
  if v.id is null then raise exception 'invalid organization'; end if;
  return to_jsonb(v) - 'account_id';
end;
$$;

create or replace function public.update_my_organization_dashboard_cover(p_cover_path text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.organizations%rowtype;
begin
  update public.organizations set dashboard_cover_path = nullif(btrim(coalesce(p_cover_path, '')), '') where id = public.current_organization() returning * into v;
  if v.id is null then raise exception 'invalid organization'; end if;
  if v.dashboard_cover_path is not null and v.dashboard_cover_path <> v.id::text || '/cover' then raise exception 'invalid dashboard cover path'; end if;
  return to_jsonb(v) - 'account_id';
end;
$$;

create or replace function public.can_manage_organization_dashboard_cover_storage_path(p_path text)
returns boolean language sql security definer stable set search_path=public,pg_temp as $$
  select exists (
    select 1 from public.accounts a join public.organizations o on o.account_id = a.id
    where a.auth_user_id = auth.uid() and a.account_type = 'organization' and p_path = o.id::text || '/cover'
  );
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('organization-dashboard-covers', 'organization-dashboard-covers', false, 5242880, array['image/jpeg', 'image/png', 'image/webp']::text[])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists organization_dashboard_covers_select_own on storage.objects;
drop policy if exists organization_dashboard_covers_insert_own on storage.objects;
drop policy if exists organization_dashboard_covers_update_own on storage.objects;
drop policy if exists organization_dashboard_covers_delete_own on storage.objects;

create policy organization_dashboard_covers_select_own on storage.objects for select to authenticated using (bucket_id = 'organization-dashboard-covers' and public.can_manage_organization_dashboard_cover_storage_path(name));
create policy organization_dashboard_covers_insert_own on storage.objects for insert to authenticated with check (bucket_id = 'organization-dashboard-covers' and public.can_manage_organization_dashboard_cover_storage_path(name));
create policy organization_dashboard_covers_update_own on storage.objects for update to authenticated using (bucket_id = 'organization-dashboard-covers' and public.can_manage_organization_dashboard_cover_storage_path(name)) with check (bucket_id = 'organization-dashboard-covers' and public.can_manage_organization_dashboard_cover_storage_path(name));
create policy organization_dashboard_covers_delete_own on storage.objects for delete to authenticated using (bucket_id = 'organization-dashboard-covers' and public.can_manage_organization_dashboard_cover_storage_path(name));

create or replace function public.get_my_contacts()
returns setof jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select to_jsonb(c) || jsonb_build_object(
    'primary_email', (select cm.value from public.contact_methods cm where cm.contact_id = c.id and cm.method_type = 'email' order by cm.is_primary desc, cm.id limit 1),
    'primary_phone', (select cm.value from public.contact_methods cm where cm.contact_id = c.id and cm.method_type = 'phone' order by cm.is_primary desc, cm.id limit 1)
  ) from public.contacts c
  where c.owner_account_id = public.require_current_account()
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
$$;

alter function public.update_my_organization_name(text) owner to postgres;
alter function public.update_my_organization_dashboard_cover(text) owner to postgres;
alter function public.can_manage_organization_dashboard_cover_storage_path(text) owner to postgres;
alter function public.get_my_contacts() owner to postgres;
revoke all on function public.update_my_organization_name(text), public.update_my_organization_dashboard_cover(text), public.can_manage_organization_dashboard_cover_storage_path(text), public.get_my_contacts() from public, anon;
grant execute on function public.update_my_organization_name(text), public.update_my_organization_dashboard_cover(text), public.can_manage_organization_dashboard_cover_storage_path(text), public.get_my_contacts() to authenticated;

commit;
