-- FamilArea — documenti personali collegati alle scadenze e agli allegati privati.
begin;

create table public.personal_documents (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  holder_kind text not null check (holder_kind in ('owner', 'family_member')),
  family_member_id uuid null references public.family_members(id) on delete restrict,
  document_type text not null check (document_type in (
    'identity_card', 'driving_license', 'passport', 'health_card', 'permit_license', 'other'
  )),
  document_number text null,
  issued_on date null,
  issuer text null,
  notes text null,
  deadline_id uuid null unique references public.deadlines(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint personal_documents_holder_check check (
    (holder_kind = 'owner' and family_member_id is null)
    or (holder_kind = 'family_member' and family_member_id is not null)
  )
);

create index personal_documents_family_member_idx
  on public.personal_documents (family_id, family_member_id);

alter table public.personal_documents enable row level security;
revoke all on public.personal_documents from public, anon, authenticated;

create or replace function public.assert_personal_document_consistency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
begin
  select f.owner_account_id into v_owner_account_id
  from public.families f
  where f.id = new.family_id;

  if v_owner_account_id is null or new.owner_account_id <> v_owner_account_id then
    raise exception 'invalid personal document family owner';
  end if;

  if new.holder_kind = 'family_member' and not exists (
    select 1
    from public.family_members fm
    where fm.id = new.family_member_id
      and fm.family_id = new.family_id
      and fm.member_type in ('person', 'assisted_person')
  ) then
    raise exception 'invalid personal document holder';
  end if;

  return new;
end;
$$;

create trigger personal_documents_assert_consistency
before insert or update of family_id, owner_account_id, holder_kind, family_member_id
on public.personal_documents
for each row execute function public.assert_personal_document_consistency();

create or replace function public.personal_document_deadline_title(p_document_type text)
returns text
language sql
immutable
security definer
set search_path = public, pg_temp
as $$
  select 'Scadenza documento: ' || case p_document_type
    when 'identity_card' then 'Carta d''identità'
    when 'driving_license' then 'Patente'
    when 'passport' then 'Passaporto'
    when 'health_card' then 'Tessera sanitaria'
    when 'permit_license' then 'Permesso/licenza'
    else 'Altro documento'
  end
$$;

create or replace function public.get_my_personal_documents(
  p_family_id uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_manage_family(p_family_id);

  return query
  select to_jsonb(pd) || jsonb_build_object(
    'expiry_date', d.first_due_on,
    'reminder_days', d.reminder_days,
    'deadline_status', d.status
  )
  from public.personal_documents pd
  left join public.deadlines d on d.id = pd.deadline_id
  where pd.family_id = p_family_id
  order by pd.created_at, pd.id;
end;
$$;

create or replace function public.get_my_personal_document(
  p_document_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_document public.personal_documents%rowtype;
begin
  select * into v_document
  from public.personal_documents
  where id = p_document_id;
  if not found then
    raise exception 'personal document unavailable';
  end if;

  perform public.require_manage_family(v_document.family_id);

  return (
    select to_jsonb(pd) || jsonb_build_object(
      'expiry_date', d.first_due_on,
      'reminder_days', d.reminder_days,
      'deadline_status', d.status
    )
    from public.personal_documents pd
    left join public.deadlines d on d.id = pd.deadline_id
    where pd.id = v_document.id
  );
end;
$$;

create or replace function public.create_personal_document(
  p_family_id uuid,
  p_holder_kind text,
  p_document_type text,
  p_family_member_id uuid default null,
  p_document_number text default null,
  p_issued_on date default null,
  p_issuer text default null,
  p_notes text default null,
  p_expiry_date date default null,
  p_reminder_days smallint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
  v_document public.personal_documents%rowtype;
  v_deadline_id uuid;
begin
  select f.owner_account_id into v_owner_account_id
  from public.families f
  where f.id = p_family_id;
  if v_owner_account_id is null then
    raise exception 'family unavailable';
  end if;
  perform public.require_manage_family(p_family_id);

  insert into public.personal_documents(
    family_id, owner_account_id, holder_kind, family_member_id, document_type,
    document_number, issued_on, issuer, notes
  ) values (
    p_family_id, v_owner_account_id, p_holder_kind, p_family_member_id, p_document_type,
    nullif(btrim(p_document_number), ''), p_issued_on, nullif(btrim(p_issuer), ''), nullif(btrim(p_notes), '')
  ) returning * into v_document;

  if p_expiry_date is not null then
    insert into public.deadlines(
      owner_account_id, title, category, first_due_on, recurrence_months,
      reminder_days, notes, family_member_id, deadline_item_id, start_time, end_time
    ) values (
      v_owner_account_id, public.personal_document_deadline_title(v_document.document_type),
      'personal_document', p_expiry_date, null, coalesce(p_reminder_days, 30),
      null, case when v_document.holder_kind = 'family_member' then v_document.family_member_id else null end,
      null, null, null
    ) returning id into v_deadline_id;

    update public.personal_documents
    set deadline_id = v_deadline_id,
        updated_at = now()
    where id = v_document.id
    returning * into v_document;
  end if;

  return public.get_my_personal_document(v_document.id);
end;
$$;

create or replace function public.update_personal_document(
  p_document_id uuid,
  p_holder_kind text,
  p_document_type text,
  p_family_member_id uuid default null,
  p_document_number text default null,
  p_issued_on date default null,
  p_issuer text default null,
  p_notes text default null,
  p_expiry_date date default null,
  p_reminder_days smallint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_document public.personal_documents%rowtype;
  v_deadline_id uuid;
begin
  select * into v_document
  from public.personal_documents
  where id = p_document_id
  for update;
  if not found then
    raise exception 'personal document unavailable';
  end if;
  perform public.require_manage_family(v_document.family_id);

  if p_expiry_date is null and v_document.deadline_id is not null then
    delete from public.deadlines
    where id = v_document.deadline_id
      and owner_account_id = v_document.owner_account_id;
    v_deadline_id := null;
  elsif p_expiry_date is not null and v_document.deadline_id is not null then
    update public.deadlines
    set title = public.personal_document_deadline_title(p_document_type),
        category = 'personal_document',
        first_due_on = p_expiry_date,
        recurrence_months = null,
        reminder_days = coalesce(p_reminder_days, 30),
        notes = null,
        family_member_id = case when p_holder_kind = 'family_member' then p_family_member_id else null end,
        deadline_item_id = null,
        start_time = null,
        end_time = null,
        status = 'active',
        terminated_on = null,
        updated_at = now()
    where id = v_document.deadline_id
      and owner_account_id = v_document.owner_account_id
    returning id into v_deadline_id;
  elsif p_expiry_date is not null then
    insert into public.deadlines(
      owner_account_id, title, category, first_due_on, recurrence_months,
      reminder_days, notes, family_member_id, deadline_item_id, start_time, end_time
    ) values (
      v_document.owner_account_id, public.personal_document_deadline_title(p_document_type),
      'personal_document', p_expiry_date, null, coalesce(p_reminder_days, 30),
      null, case when p_holder_kind = 'family_member' then p_family_member_id else null end,
      null, null, null
    ) returning id into v_deadline_id;
  end if;

  update public.personal_documents
  set holder_kind = p_holder_kind,
      family_member_id = p_family_member_id,
      document_type = p_document_type,
      document_number = nullif(btrim(p_document_number), ''),
      issued_on = p_issued_on,
      issuer = nullif(btrim(p_issuer), ''),
      notes = nullif(btrim(p_notes), ''),
      deadline_id = v_deadline_id,
      updated_at = now()
  where id = v_document.id;

  return public.get_my_personal_document(v_document.id);
end;
$$;

create or replace function public.delete_personal_document(
  p_document_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_document public.personal_documents%rowtype;
begin
  select * into v_document
  from public.personal_documents
  where id = p_document_id
  for update;
  if not found then
    raise exception 'personal document unavailable';
  end if;
  perform public.require_manage_family(v_document.family_id);

  if v_document.deadline_id is not null then
    delete from public.deadlines
    where id = v_document.deadline_id
      and owner_account_id = v_document.owner_account_id;
  end if;

  delete from public.personal_documents where id = v_document.id;
end;
$$;

alter table public.attachments
  drop constraint attachments_target_type_check;

alter table public.attachments
  add constraint attachments_target_type_check
  check (target_type in ('activity', 'event', 'deadline', 'personal_document'));

create unique index attachments_personal_document_one_main_idx
  on public.attachments (target_type, target_id)
  where target_type = 'personal_document';

create or replace function public.target_scope(
  p_target_type text,
  p_target_id uuid
)
returns table(owner_account_id uuid, area_id uuid, can_read boolean, can_write boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
  v_area uuid;
  v_family uuid;
begin
  if p_target_type = 'activity' then
    select a.owner_account_id, a.area_id into v_owner, v_area
    from public.activities a where a.id = p_target_id;
  elsif p_target_type = 'event' then
    select e.owner_account_id, e.area_id into v_owner, v_area
    from public.events e where e.id = p_target_id;
  elsif p_target_type = 'deadline' then
    select d.owner_account_id, null into v_owner, v_area
    from public.deadlines d where d.id = p_target_id;
  elsif p_target_type = 'personal_document' then
    select pd.owner_account_id, pd.family_id into v_owner, v_family
    from public.personal_documents pd where pd.id = p_target_id;
  else
    raise exception 'invalid target';
  end if;

  if v_owner is null and v_area is null and v_family is null then
    raise exception 'target not found';
  end if;

  if p_target_type = 'personal_document' then
    return query
    select v_owner, null::uuid,
      public.can_manage_family(v_family),
      public.can_manage_family(v_family);
    return;
  end if;

  return query
  select v_owner, v_area,
    (v_owner = public.current_account_id() or (v_area is not null and (public.is_area_owner(v_area) or public.is_area_member(v_area)))),
    (v_owner = public.current_account_id() or (v_area is not null and public.can_manage_area(v_area)));
end;
$$;

create or replace function public.can_access_attachment_path(
  p_path text,
  p_write boolean default false
)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v text[] := string_to_array(p_path, '/');
  v_account uuid := public.current_account_id();
  v_scope record;
begin
  if array_length(v, 1) <> 5 or v[1] <> 'attachments' or nullif(v[5], '') is null then
    return false;
  end if;

  if v[3] = 'personal_document' then
    select * into v_scope from public.target_scope(v[3], v[4]::uuid);
    if v[2] <> v_scope.owner_account_id::text then
      return false;
    end if;
    return case when p_write then v_scope.can_write else v_scope.can_read end;
  end if;

  if v[2] <> v_account::text then
    return false;
  end if;
  select * into v_scope from public.target_scope(v[3], v[4]::uuid);
  return case when p_write then v_scope.can_write else v_scope.can_read end;
exception when others then
  return false;
end;
$$;

create or replace function public.replace_personal_document_attachment(
  p_document_id uuid,
  p_storage_path text,
  p_original_filename text,
  p_mime_type text,
  p_byte_size bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope record;
  v_previous public.attachments%rowtype;
  v_attachment public.attachments%rowtype;
begin
  select * into v_scope from public.target_scope('personal_document', p_document_id);
  if not v_scope.can_write or not public.can_access_attachment_path(p_storage_path, true) then
    raise exception 'permission denied';
  end if;

  select * into v_previous
  from public.attachments
  where target_type = 'personal_document'
    and target_id = p_document_id
  for update;

  if found then
    update public.attachments
    set storage_path = p_storage_path,
        original_filename = nullif(btrim(p_original_filename), ''),
        mime_type = nullif(btrim(p_mime_type), ''),
        byte_size = p_byte_size,
        uploaded_by_account_id = public.require_current_account()
    where id = v_previous.id
    returning * into v_attachment;
  else
    insert into public.attachments(
      owner_account_id, area_id, target_type, target_id, storage_path,
      original_filename, mime_type, byte_size, uploaded_by_account_id
    ) values (
      v_scope.owner_account_id, null, 'personal_document', p_document_id, p_storage_path,
      nullif(btrim(p_original_filename), ''), nullif(btrim(p_mime_type), ''),
      p_byte_size, public.require_current_account()
    ) returning * into v_attachment;
  end if;

  return jsonb_build_object(
    'attachment_id', v_attachment.id,
    'storage_path', v_attachment.storage_path,
    'previous_storage_path', case when v_previous.id is null then null else v_previous.storage_path end
  );
end;
$$;

alter table public.personal_documents owner to postgres;
alter function public.assert_personal_document_consistency() owner to postgres;
alter function public.personal_document_deadline_title(text) owner to postgres;
alter function public.get_my_personal_documents(uuid) owner to postgres;
alter function public.get_my_personal_document(uuid) owner to postgres;
alter function public.create_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint) owner to postgres;
alter function public.update_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint) owner to postgres;
alter function public.delete_personal_document(uuid) owner to postgres;
alter function public.target_scope(text,uuid) owner to postgres;
alter function public.can_access_attachment_path(text,boolean) owner to postgres;
alter function public.replace_personal_document_attachment(uuid,text,text,text,bigint) owner to postgres;

revoke all on function public.get_my_personal_documents(uuid), public.get_my_personal_document(uuid), public.create_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint), public.update_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint), public.delete_personal_document(uuid), public.replace_personal_document_attachment(uuid,text,text,text,bigint) from public, anon;

grant execute on function public.get_my_personal_documents(uuid), public.get_my_personal_document(uuid), public.create_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint), public.update_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint), public.delete_personal_document(uuid), public.replace_personal_document_attachment(uuid,text,text,text,bigint) to authenticated;

commit;
