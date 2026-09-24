-- FamilArea — Dashboard event visibility follows the central event view scope.
-- Activities, deadlines and todos deliberately retain their existing semantics.

create or replace function public.get_dashboard(
  p_from timestamptz default now(),
  p_to timestamptz default now() + interval '30 days'
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare
  v_account uuid := public.require_current_account();
begin
  if p_to <= p_from then
    raise exception 'invalid occurrence range';
  end if;

  return jsonb_build_object(
    'activities', coalesce((
      select jsonb_agg(
        to_jsonb(a) || jsonb_build_object(
          'kind', 'activity',
          'activity_id', a.id,
          'occurrence_starts_at', o.occurrence_starts_at,
          'occurrence_ends_at', o.occurrence_ends_at
        )
        order by o.occurrence_starts_at
      )
      from public.activities a
      cross join lateral public.expand_recurrence_occurrences(
        coalesce(a.starts_at, a.due_at), a.due_at, a.recurrence_frequency,
        a.recurrence_interval, a.recurrence_weekdays, a.recurrence_until,
        a.recurrence_timezone, p_from, p_to
      ) o
      where (
        a.owner_account_id = v_account
        or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))
      )
        and a.status <> 'cancelled'
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(
        to_jsonb(e) || jsonb_build_object(
          'kind', 'event',
          'event_id', e.id,
          'occurrence_starts_at', o.occurrence_starts_at,
          'occurrence_ends_at', o.occurrence_ends_at
        )
        order by o.occurrence_starts_at
      )
      from public.events e
      cross join lateral public.expand_recurrence_occurrences(
        e.starts_at, e.ends_at, e.recurrence_frequency, null, null,
        e.recurrence_until, e.recurrence_timezone, p_from, p_to
      ) o
      where public.can_view_event(e.id)
        and e.status <> 'cancelled'
    ), '[]'::jsonb),
    'deadlines', coalesce((
      select jsonb_agg(x)
      from public.get_deadline_occurrences(
        p_from::date,
        (p_to - interval '1 microsecond')::date
      ) x
    ), '[]'::jsonb),
    'todos', coalesce((
      select jsonb_agg(
        to_jsonb(a) || jsonb_build_object('kind', 'activity', 'activity_id', a.id)
        order by a.created_at
      )
      from public.activities a
      where (
        a.owner_account_id = v_account
        or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))
      )
        and a.status = 'open'
        and a.starts_at is null
        and a.due_at is null
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_dashboard(timestamptz, timestamptz) from public, anon;
grant execute on function public.get_dashboard(timestamptz, timestamptz) to authenticated;
alter function public.get_dashboard(timestamptz, timestamptz) owner to postgres;
