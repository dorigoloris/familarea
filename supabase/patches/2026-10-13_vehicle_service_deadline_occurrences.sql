-- FamilArea — link a vehicle-service record to exactly one deadline occurrence.
--
-- This patch is intentionally additive: existing service records remain valid
-- historical records with a null link. New linked RPCs are used only by the
-- future V2 form once it asks the user to choose an occurrence.

begin;

alter table public.vehicle_service_records
  add column if not exists deadline_id uuid,
  add column if not exists occurrence_on date;

alter table public.deadline_occurrence_completions
  add column if not exists vehicle_service_record_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.vehicle_service_records'::regclass
      and conname = 'vehicle_service_records_deadline_id_fkey'
  ) then
    alter table public.vehicle_service_records
      add constraint vehicle_service_records_deadline_id_fkey
      foreign key (deadline_id) references public.deadlines(id) on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.vehicle_service_records'::regclass
      and conname = 'vehicle_service_records_deadline_occurrence_pair_check'
  ) then
    alter table public.vehicle_service_records
      add constraint vehicle_service_records_deadline_occurrence_pair_check
      check ((deadline_id is null) = (occurrence_on is null));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.deadline_occurrence_completions'::regclass
      and conname = 'deadline_occurrence_completions_vehicle_service_record_fkey'
  ) then
    alter table public.deadline_occurrence_completions
      add constraint deadline_occurrence_completions_vehicle_service_record_fkey
      foreign key (vehicle_service_record_id)
      references public.vehicle_service_records(id) on delete set null;
  end if;
end;
$$;

create unique index if not exists vehicle_service_records_deadline_occurrence_unique
  on public.vehicle_service_records (deadline_id, occurrence_on)
  where deadline_id is not null;

create unique index if not exists deadline_occurrence_completions_vehicle_service_record_unique
  on public.deadline_occurrence_completions (vehicle_service_record_id)
  where vehicle_service_record_id is not null;

-- A direct manual un-completion must not detach a service record from its
-- occurrence. The linked-delete RPC below clears the source marker first.
create or replace function public.prevent_linked_vehicle_service_completion_removal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.vehicle_service_record_id is not null then
    raise exception 'deadline occurrence is completed by a vehicle service record';
  end if;
  return old;
end;
$$;

drop trigger if exists prevent_linked_vehicle_service_completion_removal
  on public.deadline_occurrence_completions;

create trigger prevent_linked_vehicle_service_completion_removal
before delete on public.deadline_occurrence_completions
for each row execute function public.prevent_linked_vehicle_service_completion_removal();

create or replace function public.get_my_vehicle_service_record(p_record_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_item_id uuid;
  v_result jsonb;
begin
  v_item_id := public.assert_my_vehicle_service_record(p_record_id);

  select jsonb_build_object(
    'id', r.id,
    'deadline_item_id', r.deadline_item_id,
    'deadline_id', r.deadline_id,
    'occurrence_on', r.occurrence_on,
    'completion_source', case when c.vehicle_service_record_id = r.id then 'vehicle_service' else null end,
    'performed_at', r.performed_at,
    'mileage', r.mileage,
    'performed_by', r.performed_by,
    'notes', r.notes,
    'created_at', r.created_at,
    'updated_at', r.updated_at,
    'tasks', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'task_key', t.task_key, 'label', t.label) order by t.created_at, t.id)
      from public.vehicle_service_record_tasks t
      where t.service_record_id = r.id
    ), '[]'::jsonb)
  ) into v_result
  from public.vehicle_service_records r
  left join public.deadline_occurrence_completions c
    on c.deadline_id = r.deadline_id
   and c.occurrence_on = r.occurrence_on
   and c.vehicle_service_record_id = r.id
  where r.id = p_record_id
    and r.deadline_item_id = v_item_id;

  return v_result;
end;
$$;

create or replace function public.get_my_vehicle_service_records(p_deadline_item_id uuid)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_current_account();
begin
  perform public.assert_my_deadline_item(p_deadline_item_id);
  if not exists (
    select 1 from public.deadline_items di
    where di.id = p_deadline_item_id
      and di.owner_account_id = v_account_id
      and di.category = 'vehicle'
  ) then
    raise exception 'vehicle unavailable';
  end if;

  return query
  select jsonb_build_object(
    'id', r.id,
    'deadline_item_id', r.deadline_item_id,
    'deadline_id', r.deadline_id,
    'occurrence_on', r.occurrence_on,
    'completion_source', case when c.vehicle_service_record_id = r.id then 'vehicle_service' else null end,
    'performed_at', r.performed_at,
    'mileage', r.mileage,
    'performed_by', r.performed_by,
    'notes', r.notes,
    'created_at', r.created_at,
    'updated_at', r.updated_at,
    'tasks', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'task_key', t.task_key, 'label', t.label) order by t.created_at, t.id)
      from public.vehicle_service_record_tasks t
      where t.service_record_id = r.id
    ), '[]'::jsonb)
  )
  from public.vehicle_service_records r
  left join public.deadline_occurrence_completions c
    on c.deadline_id = r.deadline_id
   and c.occurrence_on = r.occurrence_on
   and c.vehicle_service_record_id = r.id
  where r.deadline_item_id = p_deadline_item_id
  order by r.performed_at desc, r.created_at desc, r.id;
end;
$$;

create or replace function public.create_my_vehicle_service_record_for_deadline(
  p_deadline_id uuid,
  p_occurrence_on date,
  p_performed_at date,
  p_mileage integer default null,
  p_performed_by text default null,
  p_notes text default null,
  p_tasks jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_current_account();
  v_deadline public.deadlines%rowtype;
  v_record public.vehicle_service_records%rowtype;
begin
  if p_deadline_id is null or p_occurrence_on is null then
    raise exception 'deadline occurrence required';
  end if;
  if p_performed_at is null then
    raise exception 'vehicle service date required';
  end if;
  if p_mileage is not null and p_mileage < 0 then
    raise exception 'vehicle service mileage unavailable';
  end if;

  select d.* into v_deadline
  from public.deadlines d
  join public.deadline_items di on di.id = d.deadline_item_id
  where d.id = p_deadline_id
    and d.owner_account_id = v_account_id
    and d.deadline_kind = 'vehicle_service'
    and d.status = 'active'
    and di.owner_account_id = v_account_id
    and di.category = 'vehicle'
  for update of d;
  if not found then
    raise exception 'vehicle service deadline unavailable';
  end if;

  if not exists (
    select 1
    from generate_series(
      v_deadline.first_due_on,
      least(coalesce(v_deadline.terminated_on, p_occurrence_on), p_occurrence_on),
      make_interval(months => coalesce(v_deadline.recurrence_months, 1200))
    ) occurrence(occurrence_on)
    where occurrence.occurrence_on::date = p_occurrence_on
  ) then
    raise exception 'deadline occurrence unavailable';
  end if;

  if exists (
    select 1 from public.deadline_occurrence_completions c
    where c.deadline_id = p_deadline_id
      and c.occurrence_on = p_occurrence_on
  ) then
    raise exception 'deadline occurrence already completed';
  end if;

  insert into public.vehicle_service_records(
    deadline_item_id, deadline_id, occurrence_on, performed_at, mileage, performed_by, notes
  ) values (
    v_deadline.deadline_item_id, p_deadline_id, p_occurrence_on, p_performed_at, p_mileage,
    nullif(btrim(p_performed_by), ''), nullif(btrim(p_notes), '')
  ) returning * into v_record;

  perform public.replace_my_vehicle_service_record_tasks(v_record.id, p_tasks);

  insert into public.deadline_occurrence_completions(
    deadline_id, occurrence_on, completed_by_account_id, vehicle_service_record_id
  ) values (
    p_deadline_id, p_occurrence_on, v_account_id, v_record.id
  ) on conflict (deadline_id, occurrence_on) do nothing;
  if not found then
    raise exception 'deadline occurrence already completed';
  end if;

  return public.get_my_vehicle_service_record(v_record.id);
end;
$$;

create or replace function public.update_my_linked_vehicle_service_record(
  p_record_id uuid,
  p_performed_at date,
  p_mileage integer default null,
  p_performed_by text default null,
  p_notes text default null,
  p_tasks jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.assert_my_vehicle_service_record(p_record_id);
  if p_performed_at is null then
    raise exception 'vehicle service date required';
  end if;
  if p_mileage is not null and p_mileage < 0 then
    raise exception 'vehicle service mileage unavailable';
  end if;
  if not exists (
    select 1 from public.vehicle_service_records r
    where r.id = p_record_id
      and r.deadline_id is not null
      and r.occurrence_on is not null
  ) then
    raise exception 'vehicle service record is not linked to a deadline occurrence';
  end if;

  update public.vehicle_service_records
  set performed_at = p_performed_at,
      mileage = p_mileage,
      performed_by = nullif(btrim(p_performed_by), ''),
      notes = nullif(btrim(p_notes), ''),
      updated_at = now()
  where id = p_record_id;
  perform public.replace_my_vehicle_service_record_tasks(p_record_id, p_tasks);

  return public.get_my_vehicle_service_record(p_record_id);
end;
$$;

create or replace function public.delete_my_linked_vehicle_service_record(p_record_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_record public.vehicle_service_records%rowtype;
  v_service_completion boolean := false;
begin
  perform public.assert_my_vehicle_service_record(p_record_id);
  select * into v_record
  from public.vehicle_service_records
  where id = p_record_id
  for update;
  if not found or v_record.deadline_id is null or v_record.occurrence_on is null then
    raise exception 'vehicle service record is not linked to a deadline occurrence';
  end if;

  -- Only remove the completion that this record created. A manual completion
  -- has a null source and is deliberately left untouched.
  update public.deadline_occurrence_completions
  set vehicle_service_record_id = null
  where deadline_id = v_record.deadline_id
    and occurrence_on = v_record.occurrence_on
    and vehicle_service_record_id = v_record.id
  returning true into v_service_completion;

  if v_service_completion then
    delete from public.deadline_occurrence_completions
    where deadline_id = v_record.deadline_id
      and occurrence_on = v_record.occurrence_on
      and vehicle_service_record_id is null;
  end if;

  delete from public.vehicle_service_records where id = v_record.id;
end;
$$;

-- Legacy callers may still delete unlinked records. They must not be allowed
-- to bypass the source-aware deletion above for a record linked to an occurrence.
create or replace function public.delete_my_vehicle_service_record(p_record_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.assert_my_vehicle_service_record(p_record_id);

  if exists (
    select 1
    from public.vehicle_service_records
    where id = p_record_id
      and deadline_id is not null
  ) then
    raise exception 'linked vehicle service records must be deleted through delete_my_linked_vehicle_service_record';
  end if;

  delete from public.vehicle_service_records where id = p_record_id;
end;
$$;

alter table public.vehicle_service_records owner to postgres;
alter table public.deadline_occurrence_completions owner to postgres;
alter function public.prevent_linked_vehicle_service_completion_removal() owner to postgres;
alter function public.get_my_vehicle_service_record(uuid) owner to postgres;
alter function public.get_my_vehicle_service_records(uuid) owner to postgres;
alter function public.create_my_vehicle_service_record_for_deadline(uuid,date,date,integer,text,text,jsonb) owner to postgres;
alter function public.update_my_linked_vehicle_service_record(uuid,date,integer,text,text,jsonb) owner to postgres;
alter function public.delete_my_linked_vehicle_service_record(uuid) owner to postgres;
alter function public.delete_my_vehicle_service_record(uuid) owner to postgres;

revoke all on function public.prevent_linked_vehicle_service_completion_removal() from public, anon, authenticated;
revoke all on function public.create_my_vehicle_service_record_for_deadline(uuid,date,date,integer,text,text,jsonb) from public, anon;
revoke all on function public.update_my_linked_vehicle_service_record(uuid,date,integer,text,text,jsonb) from public, anon;
revoke all on function public.delete_my_linked_vehicle_service_record(uuid) from public, anon;
grant execute on function public.create_my_vehicle_service_record_for_deadline(uuid,date,date,integer,text,text,jsonb) to authenticated;
grant execute on function public.update_my_linked_vehicle_service_record(uuid,date,integer,text,text,jsonb) to authenticated;
grant execute on function public.delete_my_linked_vehicle_service_record(uuid) to authenticated;

commit;
