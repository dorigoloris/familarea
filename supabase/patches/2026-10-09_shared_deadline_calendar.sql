-- FamilArea — read-only Calendar projection for accepted deadline collaborations.
-- Prerequisite: 2026-10-07_deadline_collaborations_v1.sql.
-- This never returns notes, attachments, documents, deadline items or family data.

begin;

create or replace function public.get_my_shared_deadline_calendar_occurrences(
  p_from timestamptz,
  p_to timestamptz
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_personal_account();
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;

  return query
  select jsonb_build_object(
    'kind', 'deadline',
    'deadline_id', d.id,
    'title', d.title,
    'category', d.category,
    'due_on', occurrence.occurrence_on,
    'occurs_on', occurrence.occurrence_on,
    'all_day', d.start_time is null,
    'starts_at', case when d.start_time is null then null else occurrence.occurrence_on::date + d.start_time end,
    'ends_at', case when d.end_time is null then null else occurrence.occurrence_on::date + d.end_time end,
    'status', d.status,
    'is_completed', false,
    'calendar_deadline_access', 'shared',
    'calendar_shared_deadline', true,
    'calendar_owner_account_id', dc.owner_account_id,
    'calendar_is_shared', true,
    'calendar_owner_display_name', nullif(btrim(concat_ws(' ', owner_profile.first_name, owner_profile.last_name)), '')
  )
  from public.deadline_collaborations dc
  join public.deadlines d on d.id = dc.deadline_id
  join public.profiles owner_profile on owner_profile.account_id = dc.owner_account_id
  cross join lateral generate_series(
    d.first_due_on,
    least(coalesce(d.terminated_on, v_to_date), v_to_date),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) occurrence(occurrence_on)
  where dc.recipient_account_id = v_recipient_account_id
    and dc.status = 'accepted'
    and d.status = 'active'
    and public.is_resolved_personal_document_deadline(d.id)
    and occurrence.occurrence_on between p_from::date and v_to_date;
end;
$$;

alter function public.get_my_shared_deadline_calendar_occurrences(timestamptz, timestamptz) owner to postgres;
revoke all on function public.get_my_shared_deadline_calendar_occurrences(timestamptz, timestamptz) from public, anon;
grant execute on function public.get_my_shared_deadline_calendar_occurrences(timestamptz, timestamptz) to authenticated;

commit;
