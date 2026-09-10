begin;

-- Allegati privati: un solo target, con FK reali e cascade sul record padre.
create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('deadline', 'event', 'activity')),
  deadline_id uuid references public.deadlines(id) on delete cascade,
  event_id uuid references public.area_events(id) on delete cascade,
  activity_id uuid references public.area_activities(id) on delete cascade,
  storage_path text not null unique,
  original_filename text not null check (original_filename = btrim(original_filename) and char_length(original_filename) between 1 and 255),
  mime_type text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  byte_size bigint not null check (byte_size > 0 and byte_size <= 2097152),
  uploaded_by_profile_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint attachments_one_matching_target_check check (
    (target_type = 'deadline' and deadline_id is not null and event_id is null and activity_id is null)
    or (target_type = 'event' and event_id is not null and deadline_id is null and activity_id is null)
    or (target_type = 'activity' and activity_id is not null and deadline_id is null and event_id is null)
  )
);

create index attachments_deadline_idx on public.attachments(deadline_id, created_at, id) where deadline_id is not null;
create index attachments_event_idx on public.attachments(event_id, created_at, id) where event_id is not null;
create index attachments_activity_idx on public.attachments(activity_id, created_at, id) where activity_id is not null;

alter table public.attachments enable row level security;
alter table public.attachments no force row level security;
revoke all on public.attachments from public, anon, authenticated;

-- Le funzioni replicano le condizioni di visibilita gia usate dai getter del
-- relativo dominio: nessun bypass per gli admin su contenuti privati/selettivi.
create function public.can_manage_attachment_target(p_target_type text, p_target_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null or p_target_id is null then return false; end if;
  select id into v_profile_id from public.profiles where user_id = auth.uid();
  if v_profile_id is null then return false; end if;

  if p_target_type = 'deadline' then
    return exists (
      select 1 from public.deadlines d
      where d.id = p_target_id and d.owner_profile_id = v_profile_id
    );
  end if;

  if p_target_type = 'event' then
    return exists (
      select 1
      from public.area_events e
      join public.area_memberships am on am.area_id = e.area_id
        and am.profile_id = v_profile_id and am.role in ('admin', 'member')
      where e.id = p_target_id and e.created_by_profile_id = v_profile_id
    );
  end if;

  if p_target_type = 'activity' then
    return exists (
      select 1
      from public.area_activities a
      join public.area_memberships am on am.area_id = a.area_id
        and am.profile_id = v_profile_id and am.role in ('admin', 'member')
      where a.id = p_target_id
        and (
          a.created_by_profile_id = v_profile_id
          or (a.visibility = 'area' and am.role = 'admin')
        )
    );
  end if;

  return false;
end;
$$;

create function public.can_view_attachment(p_attachment_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null or p_attachment_id is null then return false; end if;
  select id into v_profile_id from public.profiles where user_id = auth.uid();
  if v_profile_id is null then return false; end if;

  return exists (
    select 1
    from public.attachments x
    left join public.deadlines d on d.id = x.deadline_id
    left join public.area_events e on e.id = x.event_id
    left join public.area_activities a on a.id = x.activity_id
    where x.id = p_attachment_id
      and (
        (x.target_type = 'deadline' and d.owner_profile_id = v_profile_id)
        or (
          x.target_type = 'event'
          and exists (
            select 1
            from public.area_memberships am
            left join public.event_participants ep
              on ep.event_id = e.id and ep.profile_id = v_profile_id
            where am.area_id = e.area_id and am.profile_id = v_profile_id
              and am.role in ('admin', 'member')
              and (
                e.visibility = 'area'
                or e.created_by_profile_id = v_profile_id
                or (e.visibility = 'creator_participants' and ep.profile_id is not null)
              )
          )
        )
        or (
          x.target_type = 'activity'
          and exists (
            select 1
            from public.area_memberships am
            where am.area_id = a.area_id and am.profile_id = v_profile_id
              and am.role in ('admin', 'member')
              and (
                a.visibility = 'area'
                or a.created_by_profile_id = v_profile_id
                or (
                  a.visibility = 'creator_assignees'
                  and exists (
                    select 1 from public.activity_assignees aa
                    where aa.activity_id = a.id and aa.profile_id = v_profile_id
                  )
                )
              )
          )
        )
      )
  );
end;
$$;

create function public.can_manage_attachment(p_attachment_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.can_manage_attachment_target(x.target_type, coalesce(x.deadline_id, x.event_id, x.activity_id))
  from public.attachments x
  where x.id = p_attachment_id;
$$;

create function public.create_my_attachment(
  p_target_type text,
  p_target_id uuid,
  p_original_filename text,
  p_mime_type text,
  p_byte_size bigint
)
returns table(id uuid, storage_path text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile_id uuid;
  v_id uuid := gen_random_uuid();
  v_extension text;
  v_filename text := btrim(coalesce(p_original_filename, ''));
begin
  if auth.uid() is null then raise exception 'Utente non autenticato'; end if;
  select p.id into v_profile_id from public.profiles p where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'Profilo non trovato per l''utente corrente'; end if;
  if p_target_type not in ('deadline', 'event', 'activity') or p_target_id is null then
    raise exception 'Destinazione allegato non valida';
  end if;
  if v_filename = '' or char_length(v_filename) > 255 then raise exception 'Nome file non valido'; end if;
  if p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp') then raise exception 'Formato file non consentito'; end if;
  if p_byte_size is null or p_byte_size <= 0 or p_byte_size > 2097152 then raise exception 'Il file deve pesare al massimo 2 MB'; end if;
  if not public.can_manage_attachment_target(p_target_type, p_target_id) then raise exception 'Non sei autorizzato a caricare allegati qui'; end if;

  v_extension := case p_mime_type
    when 'application/pdf' then 'pdf'
    when 'image/jpeg' then 'jpg'
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
  end;

  id := v_id;
  storage_path := 'attachments/' || v_id::text || '/file.' || v_extension;
  insert into public.attachments(
    id, target_type, deadline_id, event_id, activity_id, storage_path,
    original_filename, mime_type, byte_size, uploaded_by_profile_id
  ) values (
    v_id,
    p_target_type,
    case when p_target_type = 'deadline' then p_target_id end,
    case when p_target_type = 'event' then p_target_id end,
    case when p_target_type = 'activity' then p_target_id end,
    storage_path, v_filename, p_mime_type, p_byte_size, v_profile_id
  );
  return next;
end;
$$;

create function public.get_my_attachments(p_target_type text, p_target_id uuid)
returns table(
  id uuid, original_filename text, mime_type text, byte_size bigint,
  created_at timestamptz, storage_path text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_target_type not in ('deadline', 'event', 'activity') or p_target_id is null then
    raise exception 'Destinazione allegato non valida';
  end if;
  return query
  select x.id, x.original_filename, x.mime_type, x.byte_size, x.created_at, x.storage_path
  from public.attachments x
  where x.target_type = p_target_type
    and coalesce(x.deadline_id, x.event_id, x.activity_id) = p_target_id
    and public.can_view_attachment(x.id)
  order by x.created_at, x.id;
end;
$$;

create function public.get_my_attachment_download(p_attachment_id uuid)
returns table(storage_path text, original_filename text, mime_type text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.can_view_attachment(p_attachment_id) then
    raise exception 'Allegato non trovato o non accessibile';
  end if;
  return query
  select x.storage_path, x.original_filename, x.mime_type
  from public.attachments x where x.id = p_attachment_id;
end;
$$;

create function public.delete_my_attachment(p_attachment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.can_manage_attachment(p_attachment_id) then
    raise exception 'Allegato non trovato o non gestibile';
  end if;
  delete from public.attachments where id = p_attachment_id;
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'familarea-attachments',
  'familarea-attachments',
  false,
  2097152,
  array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists familarea_attachments_select_visible on storage.objects;
drop policy if exists familarea_attachments_insert_authorized on storage.objects;
drop policy if exists familarea_attachments_delete_authorized on storage.objects;

create policy familarea_attachments_select_visible
  on storage.objects for select to authenticated
  using (
    bucket_id = 'familarea-attachments'
    and exists (
      select 1 from public.attachments x
      where x.storage_path = name and public.can_view_attachment(x.id)
    )
  );

create policy familarea_attachments_insert_authorized
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'familarea-attachments'
    and exists (
      select 1 from public.attachments x
      where x.storage_path = name and public.can_manage_attachment(x.id)
    )
  );

create policy familarea_attachments_delete_authorized
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'familarea-attachments'
    and exists (
      select 1 from public.attachments x
      where x.storage_path = name and public.can_manage_attachment(x.id)
    )
  );

alter table public.attachments owner to postgres;
alter function public.can_manage_attachment_target(text, uuid) owner to postgres;
alter function public.can_view_attachment(uuid) owner to postgres;
alter function public.can_manage_attachment(uuid) owner to postgres;
alter function public.create_my_attachment(text, uuid, text, text, bigint) owner to postgres;
alter function public.get_my_attachments(text, uuid) owner to postgres;
alter function public.get_my_attachment_download(uuid) owner to postgres;
alter function public.delete_my_attachment(uuid) owner to postgres;

revoke all on function public.can_manage_attachment_target(text, uuid) from public, anon, authenticated;
revoke all on function public.can_view_attachment(uuid) from public, anon;
revoke all on function public.can_manage_attachment(uuid) from public, anon;
revoke all on function public.create_my_attachment(text, uuid, text, text, bigint) from public, anon;
revoke all on function public.get_my_attachments(text, uuid) from public, anon;
revoke all on function public.get_my_attachment_download(uuid) from public, anon;
revoke all on function public.delete_my_attachment(uuid) from public, anon;

-- Necessari alle policy Storage; restituiscono solo un booleano autorizzativo.
grant execute on function public.can_view_attachment(uuid) to authenticated;
grant execute on function public.can_manage_attachment(uuid) to authenticated;
grant execute on function public.create_my_attachment(text, uuid, text, text, bigint) to authenticated;
grant execute on function public.get_my_attachments(text, uuid) to authenticated;
grant execute on function public.get_my_attachment_download(uuid) to authenticated;
grant execute on function public.delete_my_attachment(uuid) to authenticated;

commit;
