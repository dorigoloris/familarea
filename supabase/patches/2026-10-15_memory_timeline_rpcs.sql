-- FamilArea V2 — RPC Ricordi per le Timeline di tipo memory.
-- Mantiene inalterate le firme esistenti create_memory, get_my_memories e
-- update_memory; i nuovi contratti sono usati soltanto dal frontend N Timeline.

begin;

create or replace function public.assert_my_memory_timeline(
  p_timeline_id uuid
)
returns public.timelines
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
    and t.timeline_type = 'memory';

  if not found then
    raise exception 'memory timeline unavailable';
  end if;

  return v_timeline;
end;
$$;

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
  from public.memories m
  where m.timeline_id = p_timeline_id
    and m.owner_account_id = public.require_current_account()
  order by m.occurred_on desc, m.created_at desc, m.id desc;
end;
$$;

-- New accounts may have no existing memories yet.  Loading their memory
-- Timeline list creates the same default container used by create_memory.
create or replace function public.get_my_timelines(
  p_timeline_type text default null
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
begin
  if p_timeline_type is not null and p_timeline_type not in ('memory', 'document') then
    raise exception 'invalid timeline type';
  end if;

  if p_timeline_type = 'memory' then
    perform public.ensure_default_memory_timeline(v_owner_account_id);
  end if;

  return query
  select to_jsonb(t)
  from public.timelines t
  where t.owner_account_id = v_owner_account_id
    and (p_timeline_type is null or t.timeline_type = p_timeline_type)
  order by t.timeline_type, t.is_default desc, t.name, t.created_at, t.id;
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

  insert into public.memories(
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
  returning * into v_memory;

  return to_jsonb(v_memory);
end;
$$;

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
  set timeline_id = p_timeline_id,
      occurred_on = p_occurred_on,
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

alter function public.assert_my_memory_timeline(uuid) owner to postgres;
alter function public.get_my_timelines(text) owner to postgres;
alter function public.get_my_memories_for_timeline(uuid) owner to postgres;
alter function public.create_memory_in_timeline(uuid, date, text, text) owner to postgres;
alter function public.update_memory_in_timeline(uuid, uuid, date, text, text) owner to postgres;

revoke all on function public.assert_my_memory_timeline(uuid) from public, anon, authenticated;
revoke all on function public.get_my_timelines(text) from public, anon;
revoke all on function public.get_my_memories_for_timeline(uuid) from public, anon;
revoke all on function public.create_memory_in_timeline(uuid, date, text, text) from public, anon;
revoke all on function public.update_memory_in_timeline(uuid, uuid, date, text, text) from public, anon;

grant execute on function public.get_my_memories_for_timeline(uuid) to authenticated;
grant execute on function public.get_my_timelines(text) to authenticated;
grant execute on function public.create_memory_in_timeline(uuid, date, text, text) to authenticated;
grant execute on function public.update_memory_in_timeline(uuid, uuid, date, text, text) to authenticated;

commit;
