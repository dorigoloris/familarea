-- FamilArea — managed Family-member deadline detail and update.

begin;

create or replace function public.get_my_managed_deadline(
  p_member_id uuid,
  p_deadline_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
  v_deadline jsonb;
begin
  perform public.assert_manage_owned_family_member(p_member_id);

  select to_jsonb(d)
  into v_deadline
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id;

  if v_deadline is null then
    raise exception 'deadline unavailable';
  end if;

  return v_deadline;
end;
$$;

create or replace function public.update_my_managed_deadline(
  p_member_id uuid,
  p_deadline_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
  v_deadline public.deadlines%rowtype;
begin
  perform public.assert_manage_owned_family_member(p_member_id);

  update public.deadlines d
  set title = nullif(btrim(p_title), ''),
      category = nullif(btrim(p_category), ''),
      first_due_on = p_first_due_on,
      recurrence_months = p_recurrence_months,
      reminder_days = coalesce(p_reminder_days, 30),
      notes = nullif(btrim(p_notes), '')
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
  returning d.* into v_deadline;

  if not found then
    raise exception 'deadline unavailable';
  end if;

  return to_jsonb(v_deadline);
end;
$$;

create or replace function public.get_deadline_occurrence(
  p_deadline_id uuid,
  p_occurrence_on date
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'deadline_id', d.id,
    'title', d.title,
    'occurrence_on', o.occurrence_on,
    'completed', c.deadline_id is not null
  )
  from public.deadlines d
  cross join lateral generate_series(
    d.first_due_on,
    least(coalesce(d.terminated_on, p_occurrence_on), p_occurrence_on),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) o(occurrence_on)
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id
   and c.occurrence_on = o.occurrence_on
  where d.id = p_deadline_id
    and d.owner_account_id = public.require_current_account()
    and d.status = 'active'
    and o.occurrence_on = p_occurrence_on;
$$;

revoke all on function public.get_my_managed_deadline(uuid, uuid) from public, anon;
revoke all on function public.update_my_managed_deadline(uuid, uuid, text, text, date, smallint, smallint, text) from public, anon;
revoke all on function public.get_deadline_occurrence(uuid, date) from public, anon;

grant execute on function public.get_my_managed_deadline(uuid, uuid) to authenticated;
grant execute on function public.update_my_managed_deadline(uuid, uuid, text, text, date, smallint, smallint, text) to authenticated;
grant execute on function public.get_deadline_occurrence(uuid, date) to authenticated;

alter function public.get_my_managed_deadline(uuid, uuid) owner to postgres;
alter function public.update_my_managed_deadline(uuid, uuid, text, text, date, smallint, smallint, text) owner to postgres;
alter function public.get_deadline_occurrence(uuid, date) owner to postgres;

commit;
