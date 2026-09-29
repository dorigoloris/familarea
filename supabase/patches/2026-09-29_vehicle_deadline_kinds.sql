-- FamilArea — stable functional identities for the standard vehicle deadlines.

begin;

alter table public.deadlines
  add column if not exists deadline_kind text null;

alter table public.deadlines
  add constraint deadlines_deadline_kind_check
  check (
    deadline_kind is null
    or deadline_kind in (
      'vehicle_insurance',
      'vehicle_tax',
      'vehicle_inspection',
      'vehicle_service'
    )
  );

create or replace function public.assert_deadline_item_owner()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.deadline_item_id is not null and not exists (
    select 1
    from public.deadline_items di
    where di.id = new.deadline_item_id
      and di.owner_account_id = new.owner_account_id
  ) then
    raise exception 'deadline item unavailable';
  end if;

  if new.deadline_kind is not null and (
    new.deadline_item_id is null
    or not exists (
      select 1
      from public.deadline_items di
      where di.id = new.deadline_item_id
        and di.owner_account_id = new.owner_account_id
        and di.category = 'vehicle'
    )
  ) then
    raise exception 'vehicle deadline kind requires an owned vehicle item';
  end if;

  return new;
end;
$$;

drop trigger if exists deadlines_assert_deadline_item_owner on public.deadlines;
create trigger deadlines_assert_deadline_item_owner
before insert or update of owner_account_id, deadline_item_id, deadline_kind on public.deadlines
for each row execute function public.assert_deadline_item_owner();

update public.deadlines d
set deadline_kind = case lower(regexp_replace(btrim(d.title), '\s+', ' ', 'g'))
  when 'assicurazione rca' then 'vehicle_insurance'
  when 'rca' then 'vehicle_insurance'
  when 'bollo' then 'vehicle_tax'
  when 'collaudo / revisione' then 'vehicle_inspection'
  when 'collaudo' then 'vehicle_inspection'
  when 'revisione' then 'vehicle_inspection'
  when 'tagliando' then 'vehicle_service'
end
from public.deadline_items di
where d.deadline_item_id = di.id
  and di.category = 'vehicle'
  and d.deadline_kind is null
  and lower(regexp_replace(btrim(d.title), '\s+', ' ', 'g')) in (
    'assicurazione rca',
    'rca',
    'bollo',
    'collaudo / revisione',
    'collaudo',
    'revisione',
    'tagliando'
  );

drop function if exists public.create_deadline_for_item(uuid, text, text, date, smallint, smallint, text);
create function public.create_deadline_for_item(
  p_item_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_deadline_kind text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
  v_deadline_id uuid;
begin
  perform public.assert_my_deadline_item(p_item_id);

  if p_deadline_kind is not null and p_deadline_kind not in (
    'vehicle_insurance',
    'vehicle_tax',
    'vehicle_inspection',
    'vehicle_service'
  ) then
    raise exception 'deadline kind unavailable';
  end if;

  if p_deadline_kind is not null and not exists (
    select 1
    from public.deadline_items di
    where di.id = p_item_id
      and di.owner_account_id = v_account_id
      and di.category = 'vehicle'
  ) then
    raise exception 'vehicle deadline kind requires an owned vehicle item';
  end if;

  insert into public.deadlines(
    owner_account_id,
    deadline_item_id,
    deadline_kind,
    title,
    category,
    first_due_on,
    recurrence_months,
    reminder_days,
    notes
  ) values (
    v_account_id,
    p_item_id,
    p_deadline_kind,
    nullif(btrim(p_title), ''),
    nullif(btrim(p_category), ''),
    p_first_due_on,
    p_recurrence_months,
    coalesce(p_reminder_days, 30),
    nullif(btrim(p_notes), '')
  ) returning id into v_deadline_id;

  return v_deadline_id;
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
  v_account_id uuid := public.require_personal_account();
  v_deadline public.deadlines%rowtype;
begin
  if not exists (
    select 1
    from public.deadlines d
    where d.id = p_deadline_id
      and d.owner_account_id = v_account_id
  ) then
    raise exception 'deadline unavailable';
  end if;

  if p_item_id is not null then
    perform public.assert_my_deadline_item(p_item_id);
  end if;

  update public.deadlines d
  set deadline_item_id = p_item_id,
      deadline_kind = case when p_item_id is null then null else d.deadline_kind end
  where d.id = p_deadline_id
    and d.owner_account_id = v_account_id
  returning d.* into v_deadline;

  return to_jsonb(v_deadline);
end;
$$;

alter function public.assert_deadline_item_owner() owner to postgres;
alter function public.create_deadline_for_item(uuid, text, text, date, smallint, smallint, text, text) owner to postgres;
alter function public.set_my_deadline_item(uuid, uuid) owner to postgres;

revoke all on function public.create_deadline_for_item(uuid, text, text, date, smallint, smallint, text, text) from public, anon;
grant execute on function public.create_deadline_for_item(uuid, text, text, date, smallint, smallint, text, text) to authenticated;

commit;
