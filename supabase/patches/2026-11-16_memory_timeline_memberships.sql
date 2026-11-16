-- FamilArea V2 — collegamenti multipli fra album personali e Timeline Ricordi.
-- La Timeline Generale resta una vista virtuale su public.memories: questa
-- migrazione aggiunge soltanto le raccolte tematiche e non duplica album o file.

begin;

-- Prevent a concurrent legacy create_memory call from inserting an album in
-- the short interval between validation/backfill and the replaced RPCs.
lock table public.memories in share row exclusive mode;

create table if not exists public.memory_timeline_memberships (
  memory_id uuid not null references public.memories(id) on delete cascade,
  timeline_id uuid not null references public.timelines(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (memory_id, timeline_id)
);

create index if not exists memory_timeline_memberships_timeline_memory_idx
  on public.memory_timeline_memberships (timeline_id, memory_id);

alter table public.memory_timeline_memberships enable row level security;
revoke all on public.memory_timeline_memberships from public, anon, authenticated;

create or replace function public.assert_memory_timeline_membership_scope()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
begin
  select m.owner_account_id
  into v_owner_account_id
  from public.memories m
  where m.id = new.memory_id;

  if v_owner_account_id is null or not exists (
    select 1
    from public.timelines t
    where t.id = new.timeline_id
      and t.owner_account_id = v_owner_account_id
      and t.timeline_type = 'memory'
  ) then
    raise exception 'invalid memory timeline membership';
  end if;

  return new;
end;
$$;

drop trigger if exists memory_timeline_memberships_assert_scope on public.memory_timeline_memberships;
create trigger memory_timeline_memberships_assert_scope
before insert or update of memory_id, timeline_id on public.memory_timeline_memberships
for each row execute function public.assert_memory_timeline_membership_scope();

-- Validate before backfilling.  If a historical link is inconsistent, the
-- transaction fails without changing any row instead of silently moving it.
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
    raise exception 'memory timeline membership migration validation failed';
  end if;
end;
$$;

insert into public.memory_timeline_memberships (memory_id, timeline_id)
select m.id, m.timeline_id
from public.memories m
on conflict (memory_id, timeline_id) do nothing;

create or replace function public.get_my_memories_for_timeline(
  p_timeline_id uuid
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.assert_my_memory_timeline(p_timeline_id);

  return query
  select to_jsonb(m)
  from public.memory_timeline_memberships mtm
  join public.memories m on m.id = mtm.memory_id
  where mtm.timeline_id = p_timeline_id
    and m.owner_account_id = public.require_current_account()
  order by m.occurred_on desc, m.created_at desc, m.id desc;
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

  insert into public.memories (owner_account_id, timeline_id, occurred_on, title, description)
  values (
    v_owner_account_id,
    v_timeline_id,
    p_occurred_on,
    nullif(btrim(p_title), ''),
    nullif(btrim(p_description), '')
  )
  returning * into v_memory;

  insert into public.memory_timeline_memberships (memory_id, timeline_id)
  values (v_memory.id, v_timeline_id);

  return to_jsonb(v_memory);
end;
$$;

create or replace function public.create_memory_in_timeline(
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
  v_memory public.memories%rowtype;
begin
  perform public.assert_my_memory_timeline(p_timeline_id);

  if p_occurred_on is null then
    raise exception 'memory date is required';
  end if;
  if nullif(btrim(p_title), '') is null then
    raise exception 'memory title is required';
  end if;

  insert into public.memories (owner_account_id, timeline_id, occurred_on, title, description)
  values (
    v_owner_account_id,
    p_timeline_id,
    p_occurred_on,
    nullif(btrim(p_title), ''),
    nullif(btrim(p_description), '')
  )
  returning * into v_memory;

  insert into public.memory_timeline_memberships (memory_id, timeline_id)
  values (v_memory.id, p_timeline_id);

  return to_jsonb(v_memory);
end;
$$;

-- The timeline argument remains in the public contract for the editor route,
-- but editing an album must not rewrite its historical link or memberships.
create or replace function public.update_memory_in_timeline(
  p_memory_id uuid,
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
  v_memory public.memories%rowtype;
begin
  perform public.assert_my_memory_timeline(p_timeline_id);

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
    raise exception 'memory unavailable';
  end if;

  return to_jsonb(v_memory);
end;
$$;

create or replace function public.get_my_memory_timeline_memberships(
  p_memory_id uuid
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from public.memories m
    where m.id = p_memory_id
      and m.owner_account_id = public.require_current_account()
  ) then
    raise exception 'memory unavailable';
  end if;

  return query
  select jsonb_build_object('timeline_id', mtm.timeline_id)
  from public.memory_timeline_memberships mtm
  where mtm.memory_id = p_memory_id
  order by mtm.timeline_id;
end;
$$;

create or replace function public.replace_my_memory_timeline_memberships(
  p_memory_id uuid,
  p_timeline_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_timeline_ids uuid[] := coalesce(p_timeline_ids, '{}'::uuid[]);
  v_locked_timeline_count integer;
begin
  if array_position(v_timeline_ids, null) is not null
     or cardinality(v_timeline_ids) <> (
       select count(distinct timeline_id)
       from unnest(v_timeline_ids) as requested(timeline_id)
     ) then
    raise exception 'invalid memory timeline selection';
  end if;

  if exists (
    select 1
    from unnest(v_timeline_ids) as requested(timeline_id)
    left join public.timelines t on t.id = requested.timeline_id
    where t.id is null
       or t.owner_account_id is distinct from v_owner_account_id
       or t.timeline_type <> 'memory'
  ) then
    raise exception 'memory timeline unavailable';
  end if;

  -- Lock selected Timelines before the album row.  delete_timeline takes its
  -- Timeline lock first too, so concurrent organization and deletion either
  -- serialize or fail cleanly instead of creating a lock-order deadlock.
  perform 1
  from public.timelines t
  where t.id = any(v_timeline_ids)
  order by t.id
  for key share;

  get diagnostics v_locked_timeline_count = row_count;
  if v_locked_timeline_count <> cardinality(v_timeline_ids) then
    raise exception 'memory timeline unavailable';
  end if;

  perform 1
  from public.memories m
  where m.id = p_memory_id
    and m.owner_account_id = v_owner_account_id
  for update;

  if not found then
    raise exception 'memory unavailable';
  end if;

  delete from public.memory_timeline_memberships mtm
  where mtm.memory_id = p_memory_id
    and not (mtm.timeline_id = any(v_timeline_ids));

  insert into public.memory_timeline_memberships (memory_id, timeline_id)
  select p_memory_id, requested.timeline_id
  from unnest(v_timeline_ids) as requested(timeline_id)
  on conflict (memory_id, timeline_id) do nothing;
end;
$$;

create or replace function public.remove_my_memory_from_timeline(
  p_memory_id uuid,
  p_timeline_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
begin
  perform 1
  from public.timelines t
  where t.id = p_timeline_id
    and t.owner_account_id = v_owner_account_id
    and t.timeline_type = 'memory'
  for key share;

  if not found then
    raise exception 'memory timeline unavailable';
  end if;

  perform 1
  from public.memories m
  where m.id = p_memory_id
    and m.owner_account_id = v_owner_account_id
  for update;

  if not found then
    raise exception 'memory unavailable';
  end if;

  delete from public.memory_timeline_memberships mtm
  using public.timelines t
  where mtm.memory_id = p_memory_id
    and mtm.timeline_id = p_timeline_id
    and t.id = mtm.timeline_id
    and t.owner_account_id = v_owner_account_id
    and t.timeline_type = 'memory';

  if not found then
    raise exception 'memory timeline membership unavailable';
  end if;
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
    select 1 from public.memory_timeline_memberships mtm where mtm.timeline_id = v_timeline.id
  ) or exists (
    select 1 from public.timeline_documents d where d.timeline_id = v_timeline.id
  ) then
    raise exception 'cannot delete a non-empty timeline';
  end if;

  -- timeline_id remains for compatibility with the existing memory contract.
  -- Once this thematic Timeline has no membership rows, rehome only that
  -- legacy pointer.  The album, files and any remaining memberships are kept.
  update public.memories m
  set timeline_id = coalesce(
        (
          select mtm.timeline_id
          from public.memory_timeline_memberships mtm
          where mtm.memory_id = m.id
          order by mtm.created_at, mtm.timeline_id
          limit 1
        ),
        public.ensure_default_memory_timeline(m.owner_account_id)
      ),
      updated_at = now()
  where m.timeline_id = v_timeline.id;

  delete from public.timelines
  where id = v_timeline.id
    and owner_account_id = public.require_current_account();
end;
$$;

alter table public.memory_timeline_memberships owner to postgres;
alter function public.assert_memory_timeline_membership_scope() owner to postgres;
alter function public.get_my_memories_for_timeline(uuid) owner to postgres;
alter function public.create_memory(date, text, text) owner to postgres;
alter function public.create_memory_in_timeline(uuid, date, text, text) owner to postgres;
alter function public.update_memory_in_timeline(uuid, uuid, date, text, text) owner to postgres;
alter function public.get_my_memory_timeline_memberships(uuid) owner to postgres;
alter function public.replace_my_memory_timeline_memberships(uuid, uuid[]) owner to postgres;
alter function public.remove_my_memory_from_timeline(uuid, uuid) owner to postgres;
alter function public.delete_timeline(uuid) owner to postgres;

revoke all on function public.assert_memory_timeline_membership_scope() from public, anon, authenticated;
revoke all on function public.get_my_memories_for_timeline(uuid) from public, anon, authenticated;
revoke all on function public.create_memory(date, text, text) from public, anon, authenticated;
revoke all on function public.create_memory_in_timeline(uuid, date, text, text) from public, anon, authenticated;
revoke all on function public.update_memory_in_timeline(uuid, uuid, date, text, text) from public, anon, authenticated;
revoke all on function public.get_my_memory_timeline_memberships(uuid) from public, anon, authenticated;
revoke all on function public.replace_my_memory_timeline_memberships(uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.remove_my_memory_from_timeline(uuid, uuid) from public, anon, authenticated;
revoke all on function public.delete_timeline(uuid) from public, anon, authenticated;

grant execute on function public.get_my_memories_for_timeline(uuid) to authenticated;
grant execute on function public.create_memory(date, text, text) to authenticated;
grant execute on function public.create_memory_in_timeline(uuid, date, text, text) to authenticated;
grant execute on function public.update_memory_in_timeline(uuid, uuid, date, text, text) to authenticated;
grant execute on function public.get_my_memory_timeline_memberships(uuid) to authenticated;
grant execute on function public.replace_my_memory_timeline_memberships(uuid, uuid[]) to authenticated;
grant execute on function public.remove_my_memory_from_timeline(uuid, uuid) to authenticated;
grant execute on function public.delete_timeline(uuid) to authenticated;

commit;
