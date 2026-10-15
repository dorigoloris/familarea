-- FamilArea V2 — Timeline dei ricordi account-owned.
--
-- Contratto UI del Ricordo: Data → Titolo → Descrizione → Fotografie → Documenti.
-- Fotografie e documenti non sono duplicati: usano public.attachments con
-- target_type = 'memory' e il bucket privato familarea-attachments esistente.

begin;

create table if not exists public.memories (
  id uuid primary key default gen_random_uuid(),
  owner_account_id uuid not null references public.accounts(id) on delete restrict,
  occurred_on date not null,
  title text not null check (nullif(btrim(title), '') is not null),
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists memories_owner_occurred_on_idx
  on public.memories (owner_account_id, occurred_on desc, created_at desc, id desc);

alter table public.memories enable row level security;
revoke all on public.memories from public, anon, authenticated;

-- The generic attachment table is intentionally polymorphic.  Preserve every
-- existing target type and add only the account-owned memory target.
alter table public.attachments
  drop constraint if exists attachments_target_type_check;

alter table public.attachments
  add constraint attachments_target_type_check
  check (target_type in ('activity', 'event', 'deadline', 'personal_document', 'memory'));

-- Extend the current attachment authorization resolver.  Existing activity,
-- event, deadline and personal-document branches are retained unchanged.
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

create or replace function public.create_memory(
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
  v_memory public.memories%rowtype;
begin
  if p_occurred_on is null then
    raise exception 'memory date is required';
  end if;
  if nullif(btrim(p_title), '') is null then
    raise exception 'memory title is required';
  end if;

  insert into public.memories(owner_account_id, occurred_on, title, description)
  values (
    public.require_current_account(),
    p_occurred_on,
    nullif(btrim(p_title), ''),
    nullif(btrim(p_description), '')
  )
  returning * into v_memory;

  return to_jsonb(v_memory);
end;
$$;

create or replace function public.get_my_memories()
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(m)
  from public.memories m
  where m.owner_account_id = public.require_current_account()
  order by m.occurred_on desc, m.created_at desc, m.id desc;
$$;

create or replace function public.get_memory(p_memory_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_memory public.memories%rowtype;
begin
  select * into v_memory
  from public.memories m
  where m.id = p_memory_id
    and m.owner_account_id = public.require_current_account();

  if not found then
    raise exception 'memory unavailable';
  end if;

  return to_jsonb(v_memory);
end;
$$;

create or replace function public.update_memory(
  p_memory_id uuid,
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
  v_memory public.memories%rowtype;
begin
  if p_occurred_on is null then
    raise exception 'memory date is required';
  end if;
  if nullif(btrim(p_title), '') is null then
    raise exception 'memory title is required';
  end if;

  update public.memories m
  set occurred_on = p_occurred_on,
      title = nullif(btrim(p_title), ''),
      description = nullif(btrim(p_description), ''),
      updated_at = now()
  where m.id = p_memory_id
    and m.owner_account_id = public.require_current_account()
  returning * into v_memory;

  if not found then
    raise exception 'permission denied';
  end if;

  return to_jsonb(v_memory);
end;
$$;

-- File Storage must be removed through the existing authorized attachment flow
-- before deleting the record.  This prevents orphaned private blobs.
create or replace function public.delete_memory(p_memory_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (
    select 1
    from public.attachments a
    where a.target_type = 'memory'
      and a.target_id = p_memory_id
  ) then
    raise exception 'remove memory attachments before deleting the memory';
  end if;

  delete from public.memories m
  where m.id = p_memory_id
    and m.owner_account_id = public.require_current_account();

  if not found then
    raise exception 'permission denied';
  end if;
end;
$$;

alter function public.create_memory(date, text, text) owner to postgres;
alter function public.get_my_memories() owner to postgres;
alter function public.get_memory(uuid) owner to postgres;
alter function public.update_memory(uuid, date, text, text) owner to postgres;
alter function public.delete_memory(uuid) owner to postgres;

revoke all on function public.create_memory(date, text, text) from public, anon;
revoke all on function public.get_my_memories() from public, anon;
revoke all on function public.get_memory(uuid) from public, anon;
revoke all on function public.update_memory(uuid, date, text, text) from public, anon;
revoke all on function public.delete_memory(uuid) from public, anon;

grant execute on function public.create_memory(date, text, text) to authenticated;
grant execute on function public.get_my_memories() to authenticated;
grant execute on function public.get_memory(uuid) to authenticated;
grant execute on function public.update_memory(uuid, date, text, text) to authenticated;
grant execute on function public.delete_memory(uuid) to authenticated;

commit;
