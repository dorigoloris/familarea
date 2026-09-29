-- FamilArea — vehicle service history, independent from the next service deadline.

begin;

create table public.vehicle_service_records (
  id uuid primary key default gen_random_uuid(),
  deadline_item_id uuid not null references public.deadline_items(id) on delete cascade,
  performed_at date not null,
  mileage integer null check (mileage is null or mileage >= 0),
  performed_by text null check (performed_by is null or (performed_by = btrim(performed_by) and char_length(performed_by) > 0)),
  notes text null check (notes is null or (notes = btrim(notes) and char_length(notes) > 0)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index vehicle_service_records_item_performed_idx
  on public.vehicle_service_records (deadline_item_id, performed_at desc, created_at desc, id);

create table public.vehicle_service_record_tasks (
  id uuid primary key default gen_random_uuid(),
  service_record_id uuid not null references public.vehicle_service_records(id) on delete cascade,
  task_key text null check (task_key is null or task_key in ('engine_oil', 'engine_oil_filter', 'spark_plugs', 'wheel_balancing')),
  label text not null check (label = btrim(label) and char_length(label) > 0),
  created_at timestamptz not null default now()
);

create index vehicle_service_record_tasks_record_idx
  on public.vehicle_service_record_tasks (service_record_id, created_at, id);

alter table public.vehicle_service_records enable row level security;
alter table public.vehicle_service_record_tasks enable row level security;
revoke all on public.vehicle_service_records from public, anon, authenticated;
revoke all on public.vehicle_service_record_tasks from public, anon, authenticated;

create function public.assert_my_vehicle_service_record(p_record_id uuid)
returns uuid
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_item_id uuid;
begin
  select r.deadline_item_id into v_item_id from public.vehicle_service_records r where r.id = p_record_id;
  if not found then raise exception 'vehicle service record unavailable'; end if;
  perform public.assert_my_deadline_item(v_item_id);
  if not exists (select 1 from public.deadline_items di where di.id = v_item_id and di.category = 'vehicle') then
    raise exception 'vehicle unavailable';
  end if;
  return v_item_id;
end;
$$;

create function public.replace_my_vehicle_service_record_tasks(p_record_id uuid, p_tasks jsonb)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_task jsonb; v_key text; v_label text; v_seen_labels text[] := array[]::text[];
begin
  perform public.assert_my_vehicle_service_record(p_record_id);
  if p_tasks is null or jsonb_typeof(p_tasks) <> 'array' then raise exception 'vehicle service tasks unavailable'; end if;
  delete from public.vehicle_service_record_tasks where service_record_id = p_record_id;
  for v_task in select value from jsonb_array_elements(p_tasks) loop
    if jsonb_typeof(v_task) <> 'object' then raise exception 'vehicle service task unavailable'; end if;
    v_key := nullif(btrim(v_task->>'task_key'), '');
    v_label := nullif(btrim(v_task->>'label'), '');
    if v_key is not null then
      v_label := case v_key
        when 'engine_oil' then 'Cambio olio motore'
        when 'engine_oil_filter' then 'Cambio filtro olio motore'
        when 'spark_plugs' then 'Cambio candele'
        when 'wheel_balancing' then 'Equilibratura gomme'
        else null end;
      if v_label is null then raise exception 'vehicle service task unavailable'; end if;
    elsif v_label is null then
      raise exception 'vehicle service task label required';
    end if;
    if lower(v_label) = any(v_seen_labels) then raise exception 'duplicate vehicle service task'; end if;
    v_seen_labels := array_append(v_seen_labels, lower(v_label));
    insert into public.vehicle_service_record_tasks(service_record_id, task_key, label)
    values (p_record_id, v_key, v_label);
  end loop;
end;
$$;

create function public.get_my_vehicle_service_record(p_record_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_item_id uuid; v_result jsonb;
begin
  v_item_id := public.assert_my_vehicle_service_record(p_record_id);
  select jsonb_build_object('id', r.id, 'deadline_item_id', r.deadline_item_id, 'performed_at', r.performed_at,
    'mileage', r.mileage, 'performed_by', r.performed_by, 'notes', r.notes, 'created_at', r.created_at,
    'updated_at', r.updated_at, 'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'task_key', t.task_key, 'label', t.label) order by t.created_at, t.id) from public.vehicle_service_record_tasks t where t.service_record_id = r.id), '[]'::jsonb))
  into v_result from public.vehicle_service_records r where r.id = p_record_id and r.deadline_item_id = v_item_id;
  return v_result;
end;
$$;

create function public.get_my_vehicle_service_records(p_deadline_item_id uuid)
returns setof jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_account_id uuid := public.require_personal_account();
begin
  perform public.assert_my_deadline_item(p_deadline_item_id);
  if not exists (select 1 from public.deadline_items di where di.id = p_deadline_item_id and di.owner_account_id = v_account_id and di.category = 'vehicle') then raise exception 'vehicle unavailable'; end if;
  return query select jsonb_build_object('id', r.id, 'deadline_item_id', r.deadline_item_id, 'performed_at', r.performed_at,
    'mileage', r.mileage, 'performed_by', r.performed_by, 'notes', r.notes, 'created_at', r.created_at, 'updated_at', r.updated_at,
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'task_key', t.task_key, 'label', t.label) order by t.created_at, t.id) from public.vehicle_service_record_tasks t where t.service_record_id = r.id), '[]'::jsonb))
  from public.vehicle_service_records r where r.deadline_item_id = p_deadline_item_id order by r.performed_at desc, r.created_at desc, r.id;
end;
$$;

create function public.create_my_vehicle_service_record(p_deadline_item_id uuid, p_performed_at date, p_mileage integer default null, p_performed_by text default null, p_notes text default null, p_tasks jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_record public.vehicle_service_records%rowtype;
begin
  perform public.assert_my_deadline_item(p_deadline_item_id);
  if not exists (select 1 from public.deadline_items di where di.id = p_deadline_item_id and di.category = 'vehicle') then raise exception 'vehicle unavailable'; end if;
  if p_performed_at is null then raise exception 'vehicle service date required'; end if;
  if p_mileage is not null and p_mileage < 0 then raise exception 'vehicle service mileage unavailable'; end if;
  insert into public.vehicle_service_records(deadline_item_id, performed_at, mileage, performed_by, notes)
  values (p_deadline_item_id, p_performed_at, p_mileage, nullif(btrim(p_performed_by), ''), nullif(btrim(p_notes), '')) returning * into v_record;
  perform public.replace_my_vehicle_service_record_tasks(v_record.id, p_tasks);
  return public.get_my_vehicle_service_record(v_record.id);
end;
$$;

create function public.update_my_vehicle_service_record(p_record_id uuid, p_performed_at date, p_mileage integer default null, p_performed_by text default null, p_notes text default null, p_tasks jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform public.assert_my_vehicle_service_record(p_record_id);
  if p_performed_at is null then raise exception 'vehicle service date required'; end if;
  if p_mileage is not null and p_mileage < 0 then raise exception 'vehicle service mileage unavailable'; end if;
  update public.vehicle_service_records set performed_at = p_performed_at, mileage = p_mileage, performed_by = nullif(btrim(p_performed_by), ''), notes = nullif(btrim(p_notes), ''), updated_at = now() where id = p_record_id;
  perform public.replace_my_vehicle_service_record_tasks(p_record_id, p_tasks);
  return public.get_my_vehicle_service_record(p_record_id);
end;
$$;

create function public.delete_my_vehicle_service_record(p_record_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform public.assert_my_vehicle_service_record(p_record_id);
  delete from public.vehicle_service_records where id = p_record_id;
end;
$$;

alter table public.vehicle_service_records owner to postgres;
alter table public.vehicle_service_record_tasks owner to postgres;
alter function public.assert_my_vehicle_service_record(uuid) owner to postgres;
alter function public.replace_my_vehicle_service_record_tasks(uuid, jsonb) owner to postgres;
alter function public.get_my_vehicle_service_record(uuid) owner to postgres;
alter function public.get_my_vehicle_service_records(uuid) owner to postgres;
alter function public.create_my_vehicle_service_record(uuid, date, integer, text, text, jsonb) owner to postgres;
alter function public.update_my_vehicle_service_record(uuid, date, integer, text, text, jsonb) owner to postgres;
alter function public.delete_my_vehicle_service_record(uuid) owner to postgres;
revoke all on function public.assert_my_vehicle_service_record(uuid) from public, anon, authenticated;
revoke all on function public.replace_my_vehicle_service_record_tasks(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.get_my_vehicle_service_record(uuid) from public, anon;
revoke all on function public.get_my_vehicle_service_records(uuid) from public, anon;
revoke all on function public.create_my_vehicle_service_record(uuid, date, integer, text, text, jsonb) from public, anon;
revoke all on function public.update_my_vehicle_service_record(uuid, date, integer, text, text, jsonb) from public, anon;
revoke all on function public.delete_my_vehicle_service_record(uuid) from public, anon;
grant execute on function public.get_my_vehicle_service_record(uuid) to authenticated;
grant execute on function public.get_my_vehicle_service_records(uuid) to authenticated;
grant execute on function public.create_my_vehicle_service_record(uuid, date, integer, text, text, jsonb) to authenticated;
grant execute on function public.update_my_vehicle_service_record(uuid, date, integer, text, text, jsonb) to authenticated;
grant execute on function public.delete_my_vehicle_service_record(uuid) to authenticated;

commit;
