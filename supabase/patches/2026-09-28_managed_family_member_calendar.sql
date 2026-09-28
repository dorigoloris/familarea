-- FamilArea — Calendar occurrences for a managed Family member.
-- A managed member is never an authenticated account: the owner remains the caller.

begin;

create or replace function public.get_my_managed_family_member_calendar(
  p_member_id uuid,
  p_from timestamptz,
  p_to timestamptz
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid occurrence range';
  end if;

  perform public.assert_manage_owned_family_member(p_member_id);

  return query
  select jsonb_build_object(
    'kind', 'deadline',
    'deadline_id', d.id,
    'title', d.title,
    'due_on', o.occurrence_on,
    'occurs_on', o.occurrence_on,
    'all_day', true,
    'is_completed', c.deadline_id is not null,
    'family_member_id', fm.id,
    'family_member_name', nullif(btrim(concat_ws(' ', fm.first_name, fm.last_name)), ''),
    'family_member_type', fm.member_type,
    'calendar_owner_account_id', v_owner_account_id,
    'calendar_is_shared', false
  )
  from public.deadlines d
  join public.family_members fm on fm.id = d.family_member_id
  cross join lateral generate_series(
    d.first_due_on,
    least(coalesce(d.terminated_on, v_to_date), v_to_date),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) o(occurrence_on)
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id
   and c.occurrence_on = o.occurrence_on
  where d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
    and d.status = 'active'
    and o.occurrence_on between p_from::date and v_to_date;
end;
$$;

revoke all on function public.get_my_managed_family_member_calendar(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.get_my_managed_family_member_calendar(uuid, timestamptz, timestamptz) to authenticated;
alter function public.get_my_managed_family_member_calendar(uuid, timestamptz, timestamptz) owner to postgres;

commit;
