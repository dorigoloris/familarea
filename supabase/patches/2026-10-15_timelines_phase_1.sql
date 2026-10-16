-- FamilArea V2 — Fase 1 Timeline account-owned.
--
-- Introduce contenitori cronologici per Ricordi e Documenti, senza toccare
-- personal_documents, allegati, Storage o policy Storage esistenti.
-- I Ricordi esistenti vengono collegati alla Timeline Ricordi predefinita
-- del loro stesso account, senza duplicare record o file.

begin;

create table if not exists public.timelines (
  id uuid primary key default gen_random_uuid(),
  owner_account_id uuid not null references public.accounts(id) on delete restrict,
  timeline_type text not null check (timeline_type in ('memory', 'document')),
  name text not null check (nullif(btrim(name), '') is not null),
  description text,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists timelines_owner_type_default_unique
  on public.timelines (owner_account_id, timeline_type)
  where is_default;

create index if not exists timelines_owner_type_name_idx
  on public.timelines (owner_account_id, timeline_type, name, created_at, id);

alter table public.timelines enable row level security;
revoke all on public.timelines from public, anon, authenticated;

alter table public.memories
  add column if not exists timeline_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint c
    where c.conrelid = 'public.memories'::regclass
      and c.conname = 'memories_timeline_id_fkey'
  ) then
    alter table public.memories
      add constraint memories_timeline_id_fkey
      foreign key (timeline_id)
      references public.timelines(id)
      on delete restrict;
  end if;
end;
$$;

create index if not exists memories_timeline_occurred_on_idx
  on public.memories (timeline_id, occurred_on desc, created_at desc, id desc);

create table if not exists public.timeline_documents (
  id uuid primary key default gen_random_uuid(),
  owner_account_id uuid not null references public.accounts(id) on delete restrict,
  timeline_id uuid not null references public.timelines(id) on delete restrict,
  occurred_on date not null,
  title text not null check (nullif(btrim(title), '') is not null),
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists timeline_documents_owner_occurred_on_idx
  on public.timeline_documents (owner_account_id, occurred_on desc, created_at desc, id desc);

create index if not exists timeline_documents_timeline_occurred_on_idx
  on public.timeline_documents (timeline_id, occurred_on desc, created_at desc, id desc);

alter table public.timeline_documents enable row level security;
revoke all on public.timeline_documents from public, anon, authenticated;

create or replace function public.set_timeline_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.assert_timeline_identity_immutable()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.owner_account_id is distinct from old.owner_account_id
     or new.timeline_type is distinct from old.timeline_type then
    raise exception 'timeline owner and type cannot be changed';
  end if;
  return new;
end;
$$;

drop trigger if exists timelines_set_updated_at on public.timelines;
create trigger timelines_set_updated_at
before update on public.timelines
for each row execute function public.set_timeline_updated_at();

drop trigger if exists timelines_assert_identity_immutable on public.timelines;
create trigger timelines_assert_identity_immutable
before update of owner_account_id, timeline_type on public.timelines
for each row execute function public.assert_timeline_identity_immutable();

drop trigger if exists timeline_documents_set_updated_at on public.timeline_documents;
create trigger timeline_documents_set_updated_at
before update on public.timeline_documents
for each row execute function public.set_timeline_updated_at();

create or replace function public.assert_memory_timeline_scope()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.timeline_id is null or not exists (
    select 1
    from public.timelines t
    where t.id = new.timeline_id
      and t.owner_account_id = new.owner_account_id
      and t.timeline_type = 'memory'
  ) then
    raise exception 'invalid memory timeline';
  end if;
  return new;
end;
$$;

create or replace function public.assert_timeline_document_scope()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from public.timelines t
    where t.id = new.timeline_id
      and t.owner_account_id = new.owner_account_id
      and t.timeline_type = 'document'
  ) then
    raise exception 'invalid document timeline';
  end if;
  return new;
end;
$$;

drop trigger if exists memories_assert_timeline_scope on public.memories;
create trigger memories_assert_timeline_scope
before insert or update of owner_account_id, timeline_id on public.memories
for each row execute function public.assert_memory_timeline_scope();

drop trigger if exists timeline_documents_assert_timeline_scope on public.timeline_documents;
create trigger timeline_documents_assert_timeline_scope
before insert or update of owner_account_id, timeline_id on public.timeline_documents
for each row execute function public.assert_timeline_document_scope();

create or replace function public.ensure_default_memory_timeline(
  p_owner_account_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_timeline_id uuid;
begin
  if p_owner_account_id is null then
    raise exception 'timeline owner required';
  end if;

  insert into public.timelines (
    owner_account_id,
    timeline_type,
    name,
    description,
    is_default
  ) values (
    p_owner_account_id,
    'memory',
    'I miei ricordi',
    null,
    true
  )
  on conflict (owner_account_id, timeline_type) where is_default do nothing;

  select t.id
  into v_timeline_id
  from public.timelines t
  where t.owner_account_id = p_owner_account_id
    and t.timeline_type = 'memory'
    and t.is_default
  limit 1;

  if v_timeline_id is null then
    raise exception 'default memory timeline unavailable';
  end if;

  return v_timeline_id;
end;
$$;

-- Create exactly one default Timeline Ricordi for every existing memory owner,
-- then attach only records still not associated with a Timeline.
select public.ensure_default_memory_timeline(owners.owner_account_id)
from (
  select distinct m.owner_account_id
  from public.memories m
  where m.owner_account_id is not null
) owners;

update public.memories m
set timeline_id = public.ensure_default_memory_timeline(m.owner_account_id)
where m.timeline_id is null;

do $$
begin
  if exists (
    select 1
    from public.memories m
    left join public.timelines t on t.id = m.timeline_id
    where m.timeline_id is null
       or t.owner_account_id is distinct from m.owner_account_id
       or t.timeline_type <> 'memory'
  ) then
    raise exception 'memory timeline migration validation failed';
  end if;

  alter table public.memories
    alter column timeline_id set not null;
end;
$$;

-- Existing public contract remains unchanged: callers still create a memory
-- without passing a Timeline identifier and receive the full memory JSON.
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
  v_owner_account_id uuid := public.require_current_account();
  v_timeline_id uuid;
  v_memory public.memories%rowtype;
begin
  if p_occurred_on is null then
    raise exception 'memory date is required';
  end if;
  if nullif(btrim(p_title), '') is null then
    raise exception 'memory title is required';
  end if;

  v_timeline_id := public.ensure_default_memory_timeline(v_owner_account_id);

  insert into public.memories(
    owner_account_id,
    timeline_id,
    occurred_on,
    title,
    description
  ) values (
    v_owner_account_id,
    v_timeline_id,
    p_occurred_on,
    nullif(btrim(p_title), ''),
    nullif(btrim(p_description), '')
  )
  returning * into v_memory;

  return to_jsonb(v_memory);
end;
$$;

create or replace function public.create_timeline(
  p_timeline_type text,
  p_name text,
  p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_timeline public.timelines%rowtype;
begin
  if p_timeline_type not in ('memory', 'document') then
    raise exception 'invalid timeline type';
  end if;
  if nullif(btrim(p_name), '') is null then
    raise exception 'timeline name is required';
  end if;

  insert into public.timelines(
    owner_account_id,
    timeline_type,
    name,
    description,
    is_default
  ) values (
    public.require_current_account(),
    p_timeline_type,
    nullif(btrim(p_name), ''),
    nullif(btrim(p_description), ''),
    false
  )
  returning * into v_timeline;

  return to_jsonb(v_timeline);
end;
$$;

create or replace function public.get_my_timelines(
  p_timeline_type text default null
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if p_timeline_type is not null and p_timeline_type not in ('memory', 'document') then
    raise exception 'invalid timeline type';
  end if;

  return query
  select to_jsonb(t)
  from public.timelines t
  where t.owner_account_id = public.require_current_account()
    and (p_timeline_type is null or t.timeline_type = p_timeline_type)
  order by t.timeline_type, t.is_default desc, t.name, t.created_at, t.id;
end;
$$;

create or replace function public.update_timeline(
  p_timeline_id uuid,
  p_name text,
  p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_timeline public.timelines%rowtype;
begin
  if nullif(btrim(p_name), '') is null then
    raise exception 'timeline name is required';
  end if;

  update public.timelines t
  set name = nullif(btrim(p_name), ''),
      description = nullif(btrim(p_description), '')
  where t.id = p_timeline_id
    and t.owner_account_id = public.require_current_account()
  returning * into v_timeline;

  if not found then
    raise exception 'timeline unavailable';
  end if;

  return to_jsonb(v_timeline);
end;
$$;

create or replace function public.delete_timeline(
  p_timeline_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_timeline public.timelines%rowtype;
begin
  select *
  into v_timeline
  from public.timelines t
  where t.id = p_timeline_id
    and t.owner_account_id = public.require_current_account()
  for update;

  if not found then
    raise exception 'timeline unavailable';
  end if;

  if v_timeline.is_default then
    raise exception 'cannot delete a default timeline';
  end if;

  if exists (
    select 1
    from public.memories m
    where m.timeline_id = v_timeline.id
  ) or exists (
    select 1
    from public.timeline_documents d
    where d.timeline_id = v_timeline.id
  ) then
    raise exception 'cannot delete a non-empty timeline';
  end if;

  delete from public.timelines
  where id = v_timeline.id
    and owner_account_id = public.require_current_account();
end;
$$;

alter table public.timelines owner to postgres;
alter table public.timeline_documents owner to postgres;
alter function public.set_timeline_updated_at() owner to postgres;
alter function public.assert_timeline_identity_immutable() owner to postgres;
alter function public.assert_memory_timeline_scope() owner to postgres;
alter function public.assert_timeline_document_scope() owner to postgres;
alter function public.ensure_default_memory_timeline(uuid) owner to postgres;
alter function public.create_memory(date, text, text) owner to postgres;
alter function public.create_timeline(text, text, text) owner to postgres;
alter function public.get_my_timelines(text) owner to postgres;
alter function public.update_timeline(uuid, text, text) owner to postgres;
alter function public.delete_timeline(uuid) owner to postgres;

revoke all on function public.set_timeline_updated_at() from public, anon, authenticated;
revoke all on function public.assert_timeline_identity_immutable() from public, anon, authenticated;
revoke all on function public.assert_memory_timeline_scope() from public, anon, authenticated;
revoke all on function public.assert_timeline_document_scope() from public, anon, authenticated;
revoke all on function public.ensure_default_memory_timeline(uuid) from public, anon, authenticated;
revoke all on function public.create_memory(date, text, text) from public, anon;
revoke all on function public.create_timeline(text, text, text) from public, anon;
revoke all on function public.get_my_timelines(text) from public, anon;
revoke all on function public.update_timeline(uuid, text, text) from public, anon;
revoke all on function public.delete_timeline(uuid) from public, anon;

grant execute on function public.create_timeline(text, text, text) to authenticated;
grant execute on function public.get_my_timelines(text) to authenticated;
grant execute on function public.update_timeline(uuid, text, text) to authenticated;
grant execute on function public.delete_timeline(uuid) to authenticated;
grant execute on function public.create_memory(date, text, text) to authenticated;

commit;
