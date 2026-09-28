-- FamilArea — return the managed deadline occurrence as a date-only value.

begin;

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
    'occurrence_on', o.occurrence_on::date,
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
   and c.occurrence_on = o.occurrence_on::date
  where d.id = p_deadline_id
    and d.owner_account_id = public.require_current_account()
    and d.status = 'active'
    and o.occurrence_on::date = p_occurrence_on;
$$;

revoke all on function public.get_deadline_occurrence(uuid, date) from public, anon;
grant execute on function public.get_deadline_occurrence(uuid, date) to authenticated;
alter function public.get_deadline_occurrence(uuid, date) owner to postgres;

commit;
