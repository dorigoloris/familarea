begin;

-- Le policy Storage sono valutate come utente autenticato: la lettura dei
-- metadati deve quindi restare dentro helper SECURITY DEFINER.
create function public.can_view_attachment_storage_path(p_storage_path text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_storage_path is null or btrim(p_storage_path) = '' then return false; end if;
  return exists (
    select 1
    from public.attachments x
    where x.storage_path = p_storage_path
      and public.can_view_attachment(x.id)
  );
end;
$$;

create function public.can_manage_attachment_storage_path(p_storage_path text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_storage_path is null or btrim(p_storage_path) = '' then return false; end if;
  return exists (
    select 1
    from public.attachments x
    where x.storage_path = p_storage_path
      and public.can_manage_attachment(x.id)
  );
end;
$$;

alter function public.can_view_attachment_storage_path(text) owner to postgres;
alter function public.can_manage_attachment_storage_path(text) owner to postgres;

revoke all on function public.can_view_attachment_storage_path(text) from public, anon;
revoke all on function public.can_manage_attachment_storage_path(text) from public, anon;
grant execute on function public.can_view_attachment_storage_path(text) to authenticated;
grant execute on function public.can_manage_attachment_storage_path(text) to authenticated;

drop policy if exists familarea_attachments_select_visible on storage.objects;
drop policy if exists familarea_attachments_insert_authorized on storage.objects;
drop policy if exists familarea_attachments_delete_authorized on storage.objects;

create policy familarea_attachments_select_visible
  on storage.objects for select to authenticated
  using (
    bucket_id = 'familarea-attachments'
    and public.can_view_attachment_storage_path(name)
  );

create policy familarea_attachments_insert_authorized
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'familarea-attachments'
    and public.can_manage_attachment_storage_path(name)
  );

create policy familarea_attachments_delete_authorized
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'familarea-attachments'
    and public.can_manage_attachment_storage_path(name)
  );

commit;
