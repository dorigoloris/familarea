-- FamilArea V2 — Timeline Documenti account-owned.
--
-- Incremental patch: enables private attachments and CRUD RPCs for existing
-- public.timeline_documents. It preserves all existing attachment targets,
-- Storage policies and legacy Area authorization branches.

begin;

-- Preserve every current target type and add only Timeline Documenti.
alter table public.attachments
  drop constraint if exists attachments_target_type_check;

alter table public.attachments
  add constraint attachments_target_type_check
  check (
    target_type in (
      'activity',
      'event',
      'deadline',
      'personal_document',
      'memory',
      'timeline_document'
    )
  );

-- This is the existing resolver, reproduced in full. The only behavioural
-- addition is the account-owned timeline_document branch.
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
    from public.deadlines d
    where d.id = p_target_id
      and public.is_resolved_personal_document_deadline(d.id);
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
  elsif p_target_type = 'memory' then
    select m.owner_account_id, null into v_owner, v_area
    from public.memories m
    where m.id = p_target_id;
  elsif p_target_type = 'timeline_document' then
    select d.owner_account_id, null into v_owner, v_area
    from public.timeline_documents d
    where d.id = p_target_id;
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

create or replace function public.create_timeline_document(
  p_timeline_id uuid,
  p_occurred_on date,
  p_title text,
  p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_document public.timeline_documents%rowtype;
begin
  if p_timeline_id is null then
    raise exception 'document timeline is required';
  end if;
  if p_occurred_on is null then
    raise exception 'document date is required';
  end if;
  if nullif(btrim(p_title), '') is null then
    raise exception 'document title is required';
  end if;

  if not exists (
    select 1
    from public.timelines t
    where t.id = p_timeline_id
      and t.owner_account_id = v_owner_account_id
      and t.timeline_type = 'document'
  ) then
    raise exception 'document timeline unavailable';
  end if;

  insert into public.timeline_documents (
    owner_account_id,
    timeline_id,
    occurred_on,
    title,
    description
  ) values (
    v_owner_account_id,
    p_timeline_id,
    p_occurred_on,
    nullif(btrim(p_title), ''),
    nullif(btrim(p_description), '')
  )
  returning * into v_document;

  return to_jsonb(v_document);
end;
$$;

create or replace function public.get_timeline_documents(
  p_timeline_id uuid
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
begin
  if p_timeline_id is null or not exists (
    select 1
    from public.timelines t
    where t.id = p_timeline_id
      and t.owner_account_id = v_owner_account_id
      and t.timeline_type = 'document'
  ) then
    raise exception 'document timeline unavailable';
  end if;

  return query
  select to_jsonb(d)
  from public.timeline_documents d
  where d.timeline_id = p_timeline_id
    and d.owner_account_id = v_owner_account_id
  order by d.occurred_on desc, d.created_at desc, d.id desc;
end;
$$;

create or replace function public.get_timeline_document(
  p_timeline_document_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_document public.timeline_documents%rowtype;
begin
  select * into v_document
  from public.timeline_documents d
  where d.id = p_timeline_document_id
    and d.owner_account_id = public.require_current_account();

  if not found then
    raise exception 'timeline document unavailable';
  end if;

  return to_jsonb(v_document);
end;
$$;

create or replace function public.update_timeline_document(
  p_timeline_document_id uuid,
  p_occurred_on date,
  p_title text,
  p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_document public.timeline_documents%rowtype;
begin
  if p_occurred_on is null then
    raise exception 'document date is required';
  end if;
  if nullif(btrim(p_title), '') is null then
    raise exception 'document title is required';
  end if;

  update public.timeline_documents d
  set occurred_on = p_occurred_on,
      title = nullif(btrim(p_title), ''),
      description = nullif(btrim(p_description), '')
  where d.id = p_timeline_document_id
    and d.owner_account_id = public.require_current_account()
  returning * into v_document;

  if not found then
    raise exception 'timeline document unavailable';
  end if;

  return to_jsonb(v_document);
end;
$$;

-- Storage objects must be removed through delete_attachment before deleting
-- their metadata record. This mirrors the existing Memories contract and
-- avoids deleting a document while authorized attachments still exist.
create or replace function public.delete_timeline_document(
  p_timeline_document_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
begin
  if not exists (
    select 1
    from public.timeline_documents d
    where d.id = p_timeline_document_id
      and d.owner_account_id = v_owner_account_id
  ) then
    raise exception 'timeline document unavailable';
  end if;

  if exists (
    select 1
    from public.attachments a
    where a.target_type = 'timeline_document'
      and a.target_id = p_timeline_document_id
  ) then
    raise exception 'remove timeline document attachments before deleting the document';
  end if;

  delete from public.timeline_documents d
  where d.id = p_timeline_document_id
    and d.owner_account_id = v_owner_account_id;
end;
$$;

alter function public.target_scope(text, uuid) owner to postgres;
alter function public.create_timeline_document(uuid, date, text, text) owner to postgres;
alter function public.get_timeline_documents(uuid) owner to postgres;
alter function public.get_timeline_document(uuid) owner to postgres;
alter function public.update_timeline_document(uuid, date, text, text) owner to postgres;
alter function public.delete_timeline_document(uuid) owner to postgres;

-- target_scope remains intentionally non-public: its existing grants are
-- retained by CREATE OR REPLACE. New public RPCs are authenticated-only.
revoke all on function public.create_timeline_document(uuid, date, text, text) from public, anon;
revoke all on function public.get_timeline_documents(uuid) from public, anon;
revoke all on function public.get_timeline_document(uuid) from public, anon;
revoke all on function public.update_timeline_document(uuid, date, text, text) from public, anon;
revoke all on function public.delete_timeline_document(uuid) from public, anon;

grant execute on function public.create_timeline_document(uuid, date, text, text) to authenticated;
grant execute on function public.get_timeline_documents(uuid) to authenticated;
grant execute on function public.get_timeline_document(uuid) to authenticated;
grant execute on function public.update_timeline_document(uuid, date, text, text) to authenticated;
grant execute on function public.delete_timeline_document(uuid) to authenticated;

commit;
