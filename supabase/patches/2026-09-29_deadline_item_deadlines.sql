-- FamilArea — link ordinary deadlines to a personal deadline-management item.
-- The relationship is optional: existing deadlines continue to work unchanged.

begin;

alter table public.deadlines
  add column if not exists deadline_item_id uuid
  references public.deadline_items(id) on delete set null;

create index if not exists deadlines_owner_deadline_item_due_idx
  on public.deadlines (owner_account_id, deadline_item_id, first_due_on, id);

-- Keep the account boundary true even if a future server-side writer sets the
-- foreign key directly. Client calls continue to use the RPCs below.
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

  return new;
end;
$$;

create trigger deadlines_assert_deadline_item_owner
before insert or update of owner_account_id, deadline_item_id on public.deadlines
for each row execute function public.assert_deadline_item_owner();

create or replace function public.get_my_deadlines_for_item(
  p_item_id uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
begin
  perform public.assert_my_deadline_item(p_item_id);

  return query
  select to_jsonb(d)
  from public.deadlines d
  where d.owner_account_id = v_account_id
    and d.deadline_item_id = p_item_id
  order by d.first_due_on, d.created_at, d.id;
end;
$$;

create or replace function public.create_deadline_for_item(
  p_item_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null
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

  insert into public.deadlines(
    owner_account_id,
    deadline_item_id,
    title,
    category,
    first_due_on,
    recurrence_months,
    reminder_days,
    notes
  ) values (
    v_account_id,
    p_item_id,
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

alter function public.assert_deadline_item_owner() owner to postgres;
alter function public.get_my_deadlines_for_item(uuid) owner to postgres;
alter function public.create_deadline_for_item(uuid, text, text, date, smallint, smallint, text) owner to postgres;

revoke all on function public.assert_deadline_item_owner() from public, anon, authenticated;
revoke all on function public.get_my_deadlines_for_item(uuid) from public, anon;
revoke all on function public.create_deadline_for_item(uuid, text, text, date, smallint, smallint, text) from public, anon;

grant execute on function public.get_my_deadlines_for_item(uuid) to authenticated;
grant execute on function public.create_deadline_for_item(uuid, text, text, date, smallint, smallint, text) to authenticated;

commit;
