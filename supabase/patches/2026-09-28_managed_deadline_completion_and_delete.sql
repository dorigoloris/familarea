-- FamilArea — managed Family-member deadline completion and deletion.

begin;

create or replace function public.complete_my_managed_deadline_occurrence(
  p_deadline_id uuid,
  p_managed_member_id uuid,
  p_occurrence_on date,
  p_completed boolean default true
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
  v_deadline public.deadlines%rowtype;
begin
  perform public.assert_manage_owned_family_member(p_managed_member_id);

  select d.*
  into v_deadline
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_managed_member_id;

  if not found then
    raise exception 'deadline unavailable';
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

  if p_completed then
    insert into public.deadline_occurrence_completions(
      deadline_id, occurrence_on, completed_by_account_id
    ) values (
      p_deadline_id, p_occurrence_on, v_owner_account_id
    ) on conflict(deadline_id, occurrence_on) do nothing;
  else
    delete from public.deadline_occurrence_completions
    where deadline_id = p_deadline_id
      and occurrence_on = p_occurrence_on;
  end if;
end;
$$;

create or replace function public.delete_my_managed_deadline(
  p_deadline_id uuid,
  p_managed_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
begin
  perform public.assert_manage_owned_family_member(p_managed_member_id);

  delete from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_managed_member_id;

  if not found then
    raise exception 'deadline unavailable';
  end if;
end;
$$;

revoke all on function public.complete_my_managed_deadline_occurrence(uuid, uuid, date, boolean) from public, anon;
revoke all on function public.delete_my_managed_deadline(uuid, uuid) from public, anon;

grant execute on function public.complete_my_managed_deadline_occurrence(uuid, uuid, date, boolean) to authenticated;
grant execute on function public.delete_my_managed_deadline(uuid, uuid) to authenticated;

alter function public.complete_my_managed_deadline_occurrence(uuid, uuid, date, boolean) owner to postgres;
alter function public.delete_my_managed_deadline(uuid, uuid) owner to postgres;

commit;
