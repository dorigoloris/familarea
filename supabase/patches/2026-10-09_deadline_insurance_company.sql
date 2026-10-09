-- FamilArea — compagnia assicurativa strutturata per le scadenze RCA veicolo.
-- Da applicare al database remoto solo previa autorizzazione esplicita.

begin;

alter table public.deadlines
  add column if not exists insurance_company text null;

comment on column public.deadlines.insurance_company is
  'Compagnia assicurativa facoltativa della scadenza; usata dalla UI solo per RCA associate a veicoli.';

-- Le signature PostgreSQL includono tutti gli argomenti. Rimuoviamo le versioni
-- precedenti per evitare overload RPC ambigui quando il nuovo parametro opzionale
-- viene aggiunto in coda.
drop function if exists public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid,time,time,text);
drop function if exists public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text,time,time,text);
drop function if exists public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text,time,time,text);
drop function if exists public.create_deadline(text,text,date,smallint,smallint,text,uuid,time,time,text);
drop function if exists public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid,time,time);
drop function if exists public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text,time,time);
drop function if exists public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text,time,time);
drop function if exists public.create_deadline(text,text,date,smallint,smallint,text,uuid,time,time);

create function public.create_deadline(
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_family_member_id uuid default null,
  p_start_time time default null,
  p_end_time time default null,
  p_insurance_company text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_current_account();
  v_id uuid;
begin
  if p_family_member_id is not null then
    perform public.assert_manage_managed_family_member(p_family_member_id);
  end if;

  insert into public.deadlines(
    owner_account_id, title, category, first_due_on, recurrence_months,
    reminder_days, notes, family_member_id, start_time, end_time,
    insurance_company
  ) values (
    v_actor_account_id, nullif(btrim(p_title), ''), nullif(btrim(p_category), ''),
    p_first_due_on, p_recurrence_months, coalesce(p_reminder_days, 30),
    nullif(btrim(p_notes), ''), p_family_member_id, p_start_time, p_end_time,
    nullif(btrim(p_insurance_company), '')
  ) returning id into v_id;

  return v_id;
end;
$$;

create function public.update_deadline(
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
  p_end_time time default null,
  p_insurance_company text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v public.deadlines%rowtype;
begin
  if p_family_member_id is not null then
    perform public.assert_manage_managed_family_member(p_family_member_id);
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
      end_time = p_end_time,
      -- p_insurance_company omitted by legacy callers preserves its value;
      -- an explicit empty string from the V2 form clears it.
      insurance_company = case
        when p_insurance_company is null then d.insurance_company
        else nullif(btrim(p_insurance_company), '')
      end
  where d.id = p_deadline_id
    and d.owner_account_id = public.require_current_account()
    and public.is_resolved_personal_document_deadline(d.id)
  returning d.* into v;

  if not found then
    raise exception 'permission denied';
  end if;
  return to_jsonb(v);
end;
$$;

create function public.create_deadline_for_item(
  p_item_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_deadline_kind text default null,
  p_start_time time default null,
  p_end_time time default null,
  p_insurance_company text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_current_account();
  v_deadline_id uuid;
begin
  perform public.assert_my_deadline_item(p_item_id);

  if p_deadline_kind is not null and p_deadline_kind not in (
    'vehicle_insurance', 'vehicle_tax', 'vehicle_inspection', 'vehicle_service',
    'home_heating', 'home_insurance', 'home_taxes', 'home_waste'
  ) then
    raise exception 'deadline kind unavailable';
  end if;

  if p_deadline_kind is not null and not exists (
    select 1
    from public.deadline_items di
    where di.id = p_item_id
      and di.owner_account_id = v_account_id
      and (
        (p_deadline_kind like 'vehicle_%' and di.category = 'vehicle')
        or (p_deadline_kind like 'home_%' and di.category = 'home')
      )
  ) then
    raise exception 'deadline kind requires an owned item of the matching category';
  end if;

  insert into public.deadlines(
    owner_account_id, deadline_item_id, deadline_kind, title, category,
    first_due_on, recurrence_months, reminder_days, notes, start_time, end_time,
    insurance_company
  ) values (
    v_account_id, p_item_id, p_deadline_kind, nullif(btrim(p_title), ''),
    nullif(btrim(p_category), ''), p_first_due_on, p_recurrence_months,
    coalesce(p_reminder_days, 30), nullif(btrim(p_notes), ''), p_start_time,
    p_end_time, nullif(btrim(p_insurance_company), '')
  ) returning id into v_deadline_id;

  return v_deadline_id;
end;
$$;

create function public.update_my_deadline_with_item(
  p_deadline_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_deadline_item_id uuid default null,
  p_start_time time default null,
  p_end_time time default null,
  p_insurance_company text default null
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
  select d.* into v_deadline
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_account_id;

  if not found then
    raise exception 'deadline unavailable';
  end if;

  perform public.update_deadline(
    p_deadline_id, p_title, p_category, p_first_due_on, p_recurrence_months,
    p_reminder_days, p_notes, v_deadline.family_member_id, v_deadline.status,
    p_start_time, p_end_time, p_insurance_company
  );

  return public.set_my_deadline_item(p_deadline_id, p_deadline_item_id);
end;
$$;

alter function public.create_deadline(text,text,date,smallint,smallint,text,uuid,time,time,text) owner to postgres;
alter function public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text,time,time,text) owner to postgres;
alter function public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text,time,time,text) owner to postgres;
alter function public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid,time,time,text) owner to postgres;

revoke all on function public.create_deadline(text,text,date,smallint,smallint,text,uuid,time,time,text),
  public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text,time,time,text),
  public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text,time,time,text),
  public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid,time,time,text)
from public, anon;

grant execute on function public.create_deadline(text,text,date,smallint,smallint,text,uuid,time,time,text),
  public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text,time,time,text),
  public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text,time,time,text),
  public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid,time,time,text)
to authenticated;

commit;
