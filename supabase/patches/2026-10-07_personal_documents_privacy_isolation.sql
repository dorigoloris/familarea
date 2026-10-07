-- FamilArea - privacy dei documenti personali.
-- La Famiglia resta un contesto del soggetto, ma non autorizza piu' accesso ai documenti.
-- Questa patch e' intenzionalmente solo backend e non elimina alcun record esistente.

begin;

-- owner_account_id diventa il titolare reale quando il soggetto ha un account.
-- storage_owner_account_id conserva invece il namespace tecnico degli allegati esistenti.
alter table public.personal_documents
  add column if not exists storage_owner_account_id uuid references public.accounts(id) on delete restrict,
  add column if not exists ownership_state text not null default 'account_owner';

alter table public.personal_documents
  drop constraint if exists personal_documents_ownership_state_check;

alter table public.personal_documents
  alter column owner_account_id drop not null;

update public.personal_documents
set storage_owner_account_id = owner_account_id
where storage_owner_account_id is null;

-- A: intestatario "owner" -> conserva l'account owner storico.
-- B: membro con profilo collegato -> trasferisce la titolarita' all'account del profilo.
-- C: persona assistita -> nessun account titolare; verra' autorizzata solo da delega.
-- D: persona senza profilo collegato -> conserva il record senza trasferimenti automatici.
update public.personal_documents pd
set owner_account_id = case
      when pd.holder_kind = 'owner' then pd.owner_account_id
      when fm.linked_profile_id is not null then linked.account_id
      when fm.member_type = 'assisted_person' then null
      else pd.owner_account_id
    end,
    ownership_state = case
      when pd.holder_kind = 'owner' then 'account_owner'
      when fm.linked_profile_id is not null then 'account_owner'
      when fm.member_type = 'assisted_person' then 'assisted_person'
      else 'ambiguous_legacy'
    end
from public.family_members fm
left join public.profiles linked on linked.id = fm.linked_profile_id
where pd.holder_kind = 'family_member'
  and pd.family_member_id = fm.id;

alter table public.personal_documents
  alter column storage_owner_account_id set not null,
  add constraint personal_documents_ownership_state_check check (
    (ownership_state = 'account_owner' and owner_account_id is not null)
    or (ownership_state = 'assisted_person' and owner_account_id is null)
    or (ownership_state = 'ambiguous_legacy' and holder_kind = 'family_member' and family_member_id is not null)
  );

drop trigger if exists personal_documents_assert_consistency on public.personal_documents;
drop function if exists public.assert_personal_document_consistency();

create table if not exists public.assisted_person_document_delegations (
  id uuid primary key default gen_random_uuid(),
  family_member_id uuid not null references public.family_members(id) on delete cascade,
  delegate_account_id uuid not null references public.accounts(id) on delete cascade,
  granted_by_account_id uuid not null references public.accounts(id) on delete restrict,
  can_read boolean not null default true,
  can_write boolean not null default true,
  grant_origin text not null default 'manual' check (grant_origin = 'manual'),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by_account_id uuid references public.accounts(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint assisted_person_document_delegations_write_requires_read check (not can_write or can_read)
);

create unique index if not exists assisted_person_document_delegations_active_unique
  on public.assisted_person_document_delegations (family_member_id, delegate_account_id)
  where revoked_at is null;

create index if not exists assisted_person_document_delegations_delegate_idx
  on public.assisted_person_document_delegations (delegate_account_id, family_member_id)
  where revoked_at is null;

alter table public.assisted_person_document_delegations enable row level security;
revoke all on public.assisted_person_document_delegations from public, anon, authenticated;

create or replace function public.set_assisted_person_document_delegation_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists assisted_person_document_delegations_set_updated_at
  on public.assisted_person_document_delegations;
create trigger assisted_person_document_delegations_set_updated_at
before update on public.assisted_person_document_delegations
for each row execute function public.set_assisted_person_document_delegation_updated_at();

create or replace function public.can_manage_assisted_person_documents(
  p_family_member_id uuid,
  p_account_id uuid default public.require_current_account(),
  p_write boolean default false
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_family_member_id is not null
    and p_account_id is not null
    and exists (
      select 1
      from public.family_members fm
      join public.assisted_person_document_delegations d
        on d.family_member_id = fm.id
      where fm.id = p_family_member_id
        and fm.member_type = 'assisted_person'
        and d.delegate_account_id = p_account_id
        and d.revoked_at is null
        and d.can_read
        and (not p_write or d.can_write)
    );
$$;

create or replace function public.can_access_personal_document(
  p_document_id uuid,
  p_write boolean default false
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.personal_documents pd
    where pd.id = p_document_id
      and (
        (
          pd.ownership_state = 'account_owner'
          and pd.owner_account_id = public.require_current_account()
        )
        or (
          pd.ownership_state = 'assisted_person'
          and public.can_manage_assisted_person_documents(
            pd.family_member_id,
            public.require_current_account(),
            p_write
          )
        )
      )
  );
$$;

create or replace function public.assert_personal_document_subject_consistency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.family_members%rowtype;
  v_linked_account_id uuid;
begin
  if new.storage_owner_account_id is null then
    raise exception 'personal document storage owner required';
  end if;

  if new.ownership_state = 'account_owner' then
    if new.owner_account_id is null then
      raise exception 'personal document account owner required';
    end if;
    if new.holder_kind = 'owner' then
      if new.family_member_id is not null then
        raise exception 'invalid personal document holder';
      end if;
      return new;
    end if;

    select fm.*
      into v_member
    from public.family_members fm
    where fm.id = new.family_member_id
      and fm.family_id = new.family_id;
    if not found then
      raise exception 'invalid personal document account holder';
    end if;
    select p.account_id into v_linked_account_id
    from public.profiles p
    where p.id = v_member.linked_profile_id;
    if not found or v_linked_account_id <> new.owner_account_id then
      raise exception 'invalid personal document account holder';
    end if;
    return new;
  end if;

  if new.ownership_state = 'assisted_person' then
    select * into v_member
    from public.family_members fm
    where fm.id = new.family_member_id
      and fm.family_id = new.family_id;
    if not found or new.holder_kind <> 'family_member'
       or v_member.member_type <> 'assisted_person'
       or new.owner_account_id is not null then
      raise exception 'invalid assisted person document holder';
    end if;
    return new;
  end if;

  if new.ownership_state = 'ambiguous_legacy' then
    if tg_op = 'INSERT' then
      raise exception 'cannot create an ambiguous personal document';
    end if;
    select * into v_member
    from public.family_members fm
    where fm.id = new.family_member_id
      and fm.family_id = new.family_id;
    if not found or new.holder_kind <> 'family_member'
       or v_member.member_type <> 'person'
       or v_member.linked_profile_id is not null then
      raise exception 'invalid ambiguous personal document holder';
    end if;
    return new;
  end if;

  raise exception 'invalid personal document ownership state';
end;
$$;

create trigger personal_documents_assert_subject_consistency
before insert or update of family_id, owner_account_id, storage_owner_account_id,
  holder_kind, family_member_id, ownership_state
on public.personal_documents
for each row execute function public.assert_personal_document_subject_consistency();

-- Le scadenze create per documenti con un titolare account seguono il nuovo titolare.
-- Le scadenze delle persone assistite conservano il gestore tecnico storico.
update public.deadlines d
set owner_account_id = pd.owner_account_id
from public.personal_documents pd
where pd.deadline_id = d.id
  and pd.ownership_state = 'account_owner'
  and d.owner_account_id is distinct from pd.owner_account_id;

create or replace function public.get_my_personal_documents(
  p_family_id uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- p_family_id resta nella signature solo per compatibilita' frontend;
  -- non partecipa piu' all'autorizzazione o al filtro dei dati personali.
  return query
  select to_jsonb(pd) || jsonb_build_object(
    'expiry_date', d.first_due_on,
    'reminder_days', d.reminder_days,
    'deadline_status', d.status
  )
  from public.personal_documents pd
  left join public.deadlines d on d.id = pd.deadline_id
  where public.can_access_personal_document(pd.id, false)
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
begin
  if not public.can_access_personal_document(p_document_id, false) then
    raise exception 'personal document unavailable';
  end if;

  return (
    select to_jsonb(pd) || jsonb_build_object(
      'expiry_date', d.first_due_on,
      'reminder_days', d.reminder_days,
      'deadline_status', d.status
    )
    from public.personal_documents pd
    left join public.deadlines d on d.id = pd.deadline_id
    where pd.id = p_document_id
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
  v_actor_account_id uuid := public.require_personal_account();
  v_member public.family_members%rowtype;
  v_linked_account_id uuid;
  v_owner_account_id uuid;
  v_state text;
  v_document public.personal_documents%rowtype;
  v_deadline_id uuid;
begin
  if p_family_id is null or not exists (
    select 1 from public.families f where f.id = p_family_id
  ) then
    raise exception 'family context unavailable';
  end if;

  if p_holder_kind = 'owner' then
    if p_family_member_id is not null then
      raise exception 'invalid personal document holder';
    end if;
    v_owner_account_id := v_actor_account_id;
    v_state := 'account_owner';
  elsif p_holder_kind = 'family_member' then
    select fm.*
      into v_member
    from public.family_members fm
    where fm.id = p_family_member_id
      and fm.family_id = p_family_id;
    if not found then
      raise exception 'personal document holder unavailable';
    end if;
    v_linked_account_id := null;
    select p.account_id into v_linked_account_id
    from public.profiles p
    where p.id = v_member.linked_profile_id;

    if v_linked_account_id is not null then
      if v_linked_account_id <> v_actor_account_id then
        raise exception 'permission denied';
      end if;
      v_owner_account_id := v_linked_account_id;
      v_state := 'account_owner';
    elsif v_member.member_type = 'assisted_person' then
      if not public.can_manage_assisted_person_documents(v_member.id, v_actor_account_id, true) then
        raise exception 'assisted person document delegation required';
      end if;
      v_owner_account_id := null;
      v_state := 'assisted_person';
    else
      raise exception 'personal document holder is not linked to an account';
    end if;
  else
    raise exception 'invalid personal document holder';
  end if;

  insert into public.personal_documents(
    family_id, owner_account_id, storage_owner_account_id, ownership_state,
    holder_kind, family_member_id, document_type, document_number, issued_on,
    issuer, notes
  ) values (
    p_family_id, v_owner_account_id, v_actor_account_id, v_state,
    p_holder_kind, p_family_member_id, p_document_type,
    nullif(btrim(p_document_number), ''), p_issued_on,
    nullif(btrim(p_issuer), ''), nullif(btrim(p_notes), '')
  ) returning * into v_document;

  if v_state = 'assisted_person' and p_expiry_date is not null then
    raise exception 'assisted person document deadlines require an explicit supported ownership model';
  end if;

  if p_expiry_date is not null then
    insert into public.deadlines(
      owner_account_id, title, category, first_due_on, recurrence_months,
      reminder_days, notes, family_member_id, deadline_item_id, start_time, end_time
    ) values (
      coalesce(v_owner_account_id, v_actor_account_id),
      public.personal_document_deadline_title(v_document.document_type),
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
  v_actor_account_id uuid := public.require_personal_account();
  v_document public.personal_documents%rowtype;
  v_member public.family_members%rowtype;
  v_linked_account_id uuid;
  v_owner_account_id uuid;
  v_state text;
  v_deadline_id uuid;
  v_existing_expiry_date date;
  v_existing_reminder_days smallint;
begin
  select * into v_document
  from public.personal_documents
  where id = p_document_id
  for update;
  if not found or not public.can_access_personal_document(p_document_id, true) then
    raise exception 'personal document unavailable';
  end if;

  if p_holder_kind = 'owner' then
    if p_family_member_id is not null then
      raise exception 'invalid personal document holder';
    end if;
    if v_actor_account_id <> v_document.owner_account_id then
      raise exception 'permission denied';
    end if;
    v_owner_account_id := v_actor_account_id;
    v_state := 'account_owner';
  elsif p_holder_kind = 'family_member' then
    select fm.*
      into v_member
    from public.family_members fm
    where fm.id = p_family_member_id
      and fm.family_id = v_document.family_id;
    if not found then
      raise exception 'personal document holder unavailable';
    end if;
    v_linked_account_id := null;
    select p.account_id into v_linked_account_id
    from public.profiles p
    where p.id = v_member.linked_profile_id;

    if v_linked_account_id is not null then
      if v_linked_account_id <> v_actor_account_id then
        raise exception 'permission denied';
      end if;
      v_owner_account_id := v_linked_account_id;
      v_state := 'account_owner';
    elsif v_member.member_type = 'assisted_person' then
      if not public.can_manage_assisted_person_documents(v_member.id, v_actor_account_id, true) then
        raise exception 'assisted person document delegation required';
      end if;
      v_owner_account_id := null;
      v_state := 'assisted_person';
    else
      raise exception 'personal document holder is not linked to an account';
    end if;
  else
    raise exception 'invalid personal document holder';
  end if;

  if v_state = 'assisted_person' then
    if v_document.ownership_state <> 'assisted_person' then
      raise exception 'assisted person document ownership transition requires an explicit supported ownership model';
    end if;
    if v_document.deadline_id is not null then
      select d.first_due_on, d.reminder_days
        into v_existing_expiry_date, v_existing_reminder_days
      from public.deadlines d
      where d.id = v_document.deadline_id;

      if p_document_type is distinct from v_document.document_type
         or p_holder_kind is distinct from v_document.holder_kind
         or p_family_member_id is distinct from v_document.family_member_id
         or p_expiry_date is distinct from v_existing_expiry_date
         or coalesce(p_reminder_days, 30) is distinct from v_existing_reminder_days then
        raise exception 'assisted person document deadline requires an explicit supported ownership model';
      end if;
      v_deadline_id := v_document.deadline_id;
    elsif p_expiry_date is not null then
      raise exception 'assisted person document deadlines require an explicit supported ownership model';
    end if;
  elsif p_expiry_date is null and v_document.deadline_id is not null then
    delete from public.deadlines where id = v_document.deadline_id;
    v_deadline_id := null;
  elsif p_expiry_date is not null and v_document.deadline_id is not null then
    update public.deadlines
    set owner_account_id = v_owner_account_id,
        title = public.personal_document_deadline_title(p_document_type),
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
    returning id into v_deadline_id;
  elsif p_expiry_date is not null then
    insert into public.deadlines(
      owner_account_id, title, category, first_due_on, recurrence_months,
      reminder_days, notes, family_member_id, deadline_item_id, start_time, end_time
    ) values (
      v_owner_account_id,
      public.personal_document_deadline_title(p_document_type),
      'personal_document', p_expiry_date, null, coalesce(p_reminder_days, 30),
      null, case when p_holder_kind = 'family_member' then p_family_member_id else null end,
      null, null, null
    ) returning id into v_deadline_id;
  end if;

  update public.personal_documents
  set owner_account_id = v_owner_account_id,
      ownership_state = v_state,
      holder_kind = p_holder_kind,
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
  if not found or not public.can_access_personal_document(p_document_id, true) then
    raise exception 'personal document unavailable';
  end if;

  if v_document.deadline_id is not null then
    delete from public.deadlines where id = v_document.deadline_id;
  end if;

  delete from public.personal_documents where id = v_document.id;
end;
$$;

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
  v_document public.personal_documents%rowtype;
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
    select * into v_document
    from public.personal_documents pd
    where pd.id = p_target_id;
    if not found then
      raise exception 'target not found';
    end if;
    return query
    select v_document.storage_owner_account_id, null::uuid,
      public.can_access_personal_document(v_document.id, false),
      public.can_access_personal_document(v_document.id, true);
    return;
  else
    raise exception 'invalid target';
  end if;

  if v_owner is null and v_area is null then
    raise exception 'target not found';
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

-- A deadline linked to an unresolved personal document must never inherit
-- visibility or management from its historical technical owner. This guard is
-- intentionally state-based: storage_owner_account_id is never consulted.
create or replace function public.is_resolved_personal_document_deadline(
  p_deadline_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select not exists (
    select 1
    from public.personal_documents pd
    where pd.deadline_id = p_deadline_id
      and pd.ownership_state in ('assisted_person', 'ambiguous_legacy')
  );
$$;

create or replace function public.is_personal_document_deadline(
  p_deadline_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.personal_documents pd
    where pd.deadline_id = p_deadline_id
  );
$$;

-- Ordinary deadline access paths: personal-document deadlines are allowed only
-- when their document has a determined account owner (A/B).
create or replace function public.get_deadline(p_deadline_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(d)
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = public.require_current_account()
    and public.is_resolved_personal_document_deadline(d.id)
$$;

create or replace function public.get_my_deadlines()
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(d) || jsonb_build_object(
    'deadline_item_id', di.id,
    'deadline_item_name', di.name,
    'deadline_item_category', di.category,
    'deadline_item_image_path', di.image_path
  )
  from public.deadlines d
  left join public.deadline_items di
    on di.id = d.deadline_item_id
   and di.owner_account_id = d.owner_account_id
  where d.owner_account_id = public.require_current_account()
    and public.is_resolved_personal_document_deadline(d.id)
  order by d.first_due_on, d.created_at, d.id
$$;

create or replace function public.get_deadline_occurrences(
  p_from date,
  p_to date
)
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'deadline_id', d.id,
    'title', d.title,
    'occurrence_on', o.occurrence_on,
    'completed', c.deadline_id is not null
  )
  from public.deadlines d
  cross join lateral generate_series(
    d.first_due_on,
    least(coalesce(d.terminated_on, p_to), p_to),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) o(occurrence_on)
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id
   and c.occurrence_on = o.occurrence_on
  where d.owner_account_id = public.require_current_account()
    and d.status = 'active'
    and public.is_resolved_personal_document_deadline(d.id)
    and o.occurrence_on between p_from and p_to
$$;

create or replace function public.delete_deadline(p_deadline_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = public.require_current_account()
    and public.is_resolved_personal_document_deadline(d.id);
  if not found then raise exception 'permission denied'; end if;
end;
$$;

create or replace function public.complete_deadline_occurrence(
  p_deadline_id uuid,
  p_occurrence_on date,
  p_completed boolean default true
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from public.deadlines d
    where d.id = p_deadline_id
      and d.owner_account_id = public.require_current_account()
      and public.is_resolved_personal_document_deadline(d.id)
  ) then
    raise exception 'permission denied';
  end if;
  if p_completed then
    insert into public.deadline_occurrence_completions(
      deadline_id, occurrence_on, completed_by_account_id
    ) values (
      p_deadline_id, p_occurrence_on, public.require_current_account()
    ) on conflict(deadline_id, occurrence_on) do nothing;
  else
    delete from public.deadline_occurrence_completions
    where deadline_id = p_deadline_id
      and occurrence_on = p_occurrence_on;
  end if;
end;
$$;

create or replace function public.update_deadline(
  p_deadline_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_family_member_id uuid default null,
  p_status text default 'active',
  p_start_time time default null,
  p_end_time time default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v public.deadlines%rowtype;
begin
  if p_family_member_id is not null and not exists(
    select 1
    from public.family_members fm
    join public.families f on f.id = fm.family_id
    where fm.id = p_family_member_id
      and f.owner_account_id = public.require_current_account()
  ) then
    raise exception 'invalid family member';
  end if;

  update public.deadlines d
  set title = nullif(btrim(p_title), ''),
      category = nullif(btrim(p_category), ''),
      first_due_on = p_first_due_on,
      recurrence_months = p_recurrence_months,
      reminder_days = coalesce(p_reminder_days, 30),
      notes = nullif(btrim(p_notes), ''),
      family_member_id = p_family_member_id,
      status = p_status,
      start_time = p_start_time,
      end_time = p_end_time
  where d.id = p_deadline_id
    and d.owner_account_id = public.require_current_account()
    and public.is_resolved_personal_document_deadline(d.id)
  returning d.* into v;

  if not found then raise exception 'permission denied'; end if;
  return to_jsonb(v);
end;
$$;

create or replace function public.get_deadline_occurrence(
  p_deadline_id uuid,
  p_occurrence_on date
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'deadline_id', d.id,
    'title', d.title,
    'occurrence_on', o.occurrence_on::date,
    'completed', c.deadline_id is not null
  )
  from public.deadlines d
  left join public.family_members fm on fm.id = d.family_member_id
  cross join lateral generate_series(
    d.first_due_on,
    least(coalesce(d.terminated_on, p_occurrence_on), p_occurrence_on),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) o(occurrence_on)
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id
   and c.occurrence_on = o.occurrence_on::date
  where d.id = p_deadline_id
    and d.status = 'active'
    and public.is_resolved_personal_document_deadline(d.id)
    and o.occurrence_on::date = p_occurrence_on
    and (
      d.owner_account_id = public.require_current_account()
      or (
        not public.is_personal_document_deadline(d.id)
        and fm.family_id is not null
        and public.can_manage_family(fm.family_id)
      )
    );
$$;

create or replace function public.get_my_deadlines_for_item(
  p_item_id uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_current_account();
begin
  perform public.assert_my_deadline_item(p_item_id);
  return query
  select to_jsonb(d)
  from public.deadlines d
  where d.owner_account_id = v_account_id
    and d.deadline_item_id = p_item_id
    and public.is_resolved_personal_document_deadline(d.id)
  order by d.first_due_on, d.created_at, d.id;
end;
$$;

create or replace function public.set_my_deadline_item(
  p_deadline_id uuid,
  p_item_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_current_account();
  v_deadline public.deadlines%rowtype;
begin
  if not exists (
    select 1
    from public.deadlines d
    where d.id = p_deadline_id
      and d.owner_account_id = v_account_id
      and public.is_resolved_personal_document_deadline(d.id)
  ) then
    raise exception 'deadline unavailable';
  end if;
  if p_item_id is not null then perform public.assert_my_deadline_item(p_item_id); end if;
  update public.deadlines d
  set deadline_item_id = p_item_id,
      deadline_kind = case when p_item_id is null then null else d.deadline_kind end
  where d.id = p_deadline_id
    and d.owner_account_id = v_account_id
    and public.is_resolved_personal_document_deadline(d.id)
  returning d.* into v_deadline;
  return to_jsonb(v_deadline);
end;
$$;

-- Managed-family paths must not turn family membership into authority over an
-- unresolved personal document deadline.
create or replace function public.get_my_deadlines_for_managed_member(
  p_member_id uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;

  return query
  select to_jsonb(d)
  from public.deadlines d
  where d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
    and not public.is_personal_document_deadline(d.id)
  order by d.first_due_on, d.created_at, d.id;
end;
$$;

create or replace function public.get_my_managed_deadline(
  p_member_id uuid,
  p_deadline_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
  v_deadline jsonb;
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;

  select to_jsonb(d) into v_deadline
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
    and not public.is_personal_document_deadline(d.id);
  if v_deadline is null then raise exception 'deadline unavailable'; end if;
  return v_deadline;
end;
$$;

create or replace function public.update_my_managed_deadline(
  p_member_id uuid,
  p_deadline_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_start_time time default null,
  p_end_time time default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
  v_deadline public.deadlines%rowtype;
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;

  update public.deadlines d
  set title = nullif(btrim(p_title), ''),
      category = nullif(btrim(p_category), ''),
      first_due_on = p_first_due_on,
      recurrence_months = p_recurrence_months,
      reminder_days = coalesce(p_reminder_days, 30),
      notes = nullif(btrim(p_notes), ''),
      start_time = p_start_time,
      end_time = p_end_time
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
    and not public.is_personal_document_deadline(d.id)
  returning d.* into v_deadline;

  if not found then raise exception 'deadline unavailable'; end if;
  return to_jsonb(v_deadline);
end;
$$;

create or replace function public.complete_my_managed_deadline_occurrence(
  p_deadline_id uuid,
  p_managed_member_id uuid,
  p_occurrence_on date,
  p_completed boolean default true
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_personal_account();
  v_owner_account_id uuid;
  v_deadline public.deadlines%rowtype;
begin
  perform public.assert_manage_owned_family_member(p_managed_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = p_managed_member_id;
  select d.* into v_deadline
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_managed_member_id
    and not public.is_personal_document_deadline(d.id);
  if not found then raise exception 'deadline unavailable'; end if;
  if not exists (
    select 1 from generate_series(
      v_deadline.first_due_on,
      least(coalesce(v_deadline.terminated_on, p_occurrence_on), p_occurrence_on),
      make_interval(months => coalesce(v_deadline.recurrence_months, 1200))
    ) occurrence(occurrence_on)
    where occurrence.occurrence_on::date = p_occurrence_on
  ) then
    raise exception 'deadline occurrence unavailable';
  end if;
  if p_completed then
    insert into public.deadline_occurrence_completions(
      deadline_id, occurrence_on, completed_by_account_id
    ) values (
      p_deadline_id, p_occurrence_on, v_actor_account_id
    ) on conflict(deadline_id, occurrence_on) do nothing;
  else
    delete from public.deadline_occurrence_completions
    where deadline_id = p_deadline_id
      and occurrence_on = p_occurrence_on;
  end if;
end;
$$;

create or replace function public.delete_my_managed_deadline(
  p_deadline_id uuid,
  p_managed_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
begin
  perform public.assert_manage_owned_family_member(p_managed_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = p_managed_member_id;
  delete from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_managed_member_id
    and not public.is_personal_document_deadline(d.id);
  if not found then raise exception 'deadline unavailable'; end if;
end;
$$;

create or replace function public.get_my_managed_family_member_calendar(
  p_member_id uuid,
  p_from timestamptz,
  p_to timestamptz
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid occurrence range';
  end if;
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;

  return query
  select jsonb_build_object(
    'kind', 'deadline', 'deadline_id', d.id, 'title', d.title,
    'due_on', o.occurrence_on, 'occurs_on', o.occurrence_on,
    'all_day', d.start_time is null,
    'starts_at', case when d.start_time is null then null else o.occurrence_on::date + d.start_time end,
    'ends_at', case when d.end_time is null then null else o.occurrence_on::date + d.end_time end,
    'is_completed', c.deadline_id is not null,
    'family_member_id', fm.id,
    'family_member_name', nullif(btrim(concat_ws(' ', fm.first_name, fm.last_name)), ''),
    'family_member_type', fm.member_type,
    'family_member_avatar_path', fm.avatar_path,
    'calendar_owner_account_id', v_owner_account_id,
    'calendar_is_shared', false
  )
  from public.deadlines d
  join public.family_members fm on fm.id = d.family_member_id
  cross join lateral generate_series(
    d.first_due_on,
    least(coalesce(d.terminated_on, v_to_date), v_to_date),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) o(occurrence_on)
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id
   and c.occurrence_on = o.occurrence_on
  where d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
    and d.status = 'active'
    and not public.is_personal_document_deadline(d.id)
    and o.occurrence_on between p_from::date and v_to_date;
end;
$$;

-- Calendar sharing remains a read-only view for resolved A/B records. C/D
-- deadlines are removed before occurrence generation, for both own and shared
-- calendar sources.
create or replace function public.get_calendar_occurrences(
  p_from timestamptz,
  p_to timestamptz
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account uuid := public.require_current_account();
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  return query
    with calendar_accounts as (
      select v_account as account_id, false as is_shared
      where coalesce((select l.visible from public.person_calendar_links l
        where l.owner_account_id = v_account and l.viewer_account_id = v_account), true)
      union all
      select l.owner_account_id, true
      from public.person_calendar_links l
      where l.viewer_account_id = v_account and l.owner_account_id <> v_account
        and l.visible and public.can_view_person_calendar(l.owner_account_id, v_account)
    )
    select jsonb_build_object(
      'kind','activity','id',a.id,'activity_id',a.id,'title',a.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,
      'all_day',a.is_all_day,'area_id',a.area_id,'status',a.status,
      'area_name',(select ar.name from public.areas ar where ar.id = a.area_id),
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.activities a on a.status <> 'cancelled'
      and (a.owner_account_id = s.account_id or (a.area_id is not null and exists (
        select 1 from public.areas ar where ar.id = a.area_id and (
          ar.owner_account_id = s.account_id or exists (
            select 1 from public.area_memberships am
            join public.profiles ap on ap.id = am.profile_id
            where am.area_id = ar.id and ap.account_id = s.account_id
          )
        )
      )))
    cross join lateral public.expand_recurrence_occurrences(
      coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,
      a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,
      a.recurrence_timezone,p_from,p_to
    ) o
    union all
    select jsonb_build_object(
      'kind','event','event_kind',e.event_kind,'id',e.id,'event_id',e.id,'title',e.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,
      'all_day',e.is_all_day,'area_id',e.area_id,'status',e.status,
      'area_name',(select ar.name from public.areas ar where ar.id = e.area_id),
      'calendar_private',e.calendar_private,
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.events e on e.status <> 'cancelled'
      and (s.account_id = v_account or not e.calendar_private)
      and public.event_personal_source(e.id, s.account_id) is not null
    cross join lateral public.expand_recurrence_occurrences(
      e.starts_at,e.ends_at,e.recurrence_frequency,e.recurrence_interval,
      e.recurrence_weekdays,e.recurrence_until,e.recurrence_timezone,p_from,p_to
    ) o
    union all
    select jsonb_build_object(
      'kind','deadline','deadline_id',d.id,'title',d.title,
      'due_on',o.occurrence_on,'occurs_on',o.occurrence_on,
      'all_day',d.start_time is null,
      'starts_at',case when d.start_time is null then null else o.occurrence_on::date + d.start_time end,
      'ends_at',case when d.end_time is null then null else o.occurrence_on::date + d.end_time end,
      'is_completed',c.deadline_id is not null,
      'family_member_id',fm.id,
      'family_member_name',nullif(btrim(concat_ws(' ',fm.first_name,fm.last_name)),''),
      'family_member_type',fm.member_type,
      'family_member_avatar_path',fm.avatar_path,
      'deadline_item_id',di.id,
      'deadline_item_name',di.name,
      'deadline_item_category',di.category,
      'deadline_item_type',di.item_type,
      'deadline_item_image_path',di.image_path,
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.deadlines d
      on d.owner_account_id = s.account_id
     and d.status = 'active'
     and public.is_resolved_personal_document_deadline(d.id)
    left join public.family_members fm on fm.id = d.family_member_id
    left join public.deadline_items di on di.id = d.deadline_item_id and di.owner_account_id = d.owner_account_id
    cross join lateral generate_series(
      d.first_due_on, least(coalesce(d.terminated_on,v_to_date),v_to_date),
      make_interval(months => coalesce(d.recurrence_months,1200))
    ) o(occurrence_on)
    left join public.deadline_occurrence_completions c
      on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on
    where o.occurrence_on between p_from::date and v_to_date;
end;
$$;

alter table public.personal_documents owner to postgres;
alter table public.assisted_person_document_delegations owner to postgres;
alter function public.set_assisted_person_document_delegation_updated_at() owner to postgres;
alter function public.can_manage_assisted_person_documents(uuid,uuid,boolean) owner to postgres;
alter function public.can_access_personal_document(uuid,boolean) owner to postgres;
alter function public.assert_personal_document_subject_consistency() owner to postgres;
alter function public.is_resolved_personal_document_deadline(uuid) owner to postgres;
alter function public.is_personal_document_deadline(uuid) owner to postgres;
alter function public.get_deadline(uuid) owner to postgres;
alter function public.get_my_deadlines() owner to postgres;
alter function public.get_deadline_occurrences(date,date) owner to postgres;
alter function public.delete_deadline(uuid) owner to postgres;
alter function public.complete_deadline_occurrence(uuid,date,boolean) owner to postgres;
alter function public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text,time,time) owner to postgres;
alter function public.get_deadline_occurrence(uuid,date) owner to postgres;
alter function public.get_my_deadlines_for_item(uuid) owner to postgres;
alter function public.set_my_deadline_item(uuid,uuid) owner to postgres;
alter function public.get_my_deadlines_for_managed_member(uuid) owner to postgres;
alter function public.get_my_managed_deadline(uuid,uuid) owner to postgres;
alter function public.update_my_managed_deadline(uuid,uuid,text,text,date,smallint,smallint,text,time,time) owner to postgres;
alter function public.complete_my_managed_deadline_occurrence(uuid,uuid,date,boolean) owner to postgres;
alter function public.delete_my_managed_deadline(uuid,uuid) owner to postgres;
alter function public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz) owner to postgres;
alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;
alter function public.get_my_personal_documents(uuid) owner to postgres;
alter function public.get_my_personal_document(uuid) owner to postgres;
alter function public.create_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint) owner to postgres;
alter function public.update_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint) owner to postgres;
alter function public.delete_personal_document(uuid) owner to postgres;
alter function public.target_scope(text,uuid) owner to postgres;
alter function public.can_access_attachment_path(text,boolean) owner to postgres;
alter function public.replace_personal_document_attachment(uuid,text,text,text,bigint) owner to postgres;

revoke all on function public.set_assisted_person_document_delegation_updated_at(),
  public.can_manage_assisted_person_documents(uuid,uuid,boolean),
  public.can_access_personal_document(uuid,boolean),
  public.assert_personal_document_subject_consistency(),
  public.is_resolved_personal_document_deadline(uuid),
  public.is_personal_document_deadline(uuid) from public, anon, authenticated;
revoke all on function public.get_my_personal_documents(uuid),
  public.get_my_personal_document(uuid),
  public.create_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint),
  public.update_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint),
  public.delete_personal_document(uuid),
  public.replace_personal_document_attachment(uuid,text,text,text,bigint) from public, anon;
grant execute on function public.get_my_personal_documents(uuid),
  public.get_my_personal_document(uuid),
  public.create_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint),
  public.update_personal_document(uuid,text,text,uuid,text,date,text,text,date,smallint),
  public.delete_personal_document(uuid),
  public.replace_personal_document_attachment(uuid,text,text,text,bigint) to authenticated;
-- Le policy dello storage invocano questa funzione per ogni oggetto allegato.
grant execute on function public.can_access_attachment_path(text,boolean) to authenticated;

commit;
