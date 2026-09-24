-- FamilArea — View an Area event as an active, Contact-first participant.
-- Event participation grants view access to that event only.  It does not grant
-- AreaMembership or any of the separate event-management permissions.

create or replace function public.can_view_event(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public,pg_temp
as $$
  select exists (
    select 1
    from public.events e
    where e.id = p_event_id
      and (
        e.owner_account_id = public.current_account_id()
        or (
          e.area_id is not null
          and (public.is_area_owner(e.area_id) or public.is_area_member(e.area_id))
        )
        or exists (
          select 1
          from public.event_participants ep
          join public.profiles p on p.id = ep.profile_id
          where ep.event_id = e.id
            and ep.status = 'active'
            and p.account_id = public.current_account_id()
        )
      )
  );
$$;

create or replace function public.can_read_event(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public,pg_temp
as $$
  select public.can_view_event(p_id);
$$;

create or replace function public.get_visible_events()
returns setof jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $$
  select to_jsonb(e)
  from public.events e
  where public.can_view_event(e.id)
  order by e.starts_at;
$$;

create or replace function public.get_calendar_occurrences(
  p_from timestamp with time zone,
  p_to timestamp with time zone
)
returns setof jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_account uuid := public.require_current_account();
begin
  if p_to <= p_from then
    raise exception 'invalid occurrence range';
  end if;

  return query
    select jsonb_build_object(
      'kind', 'activity', 'id', a.id, 'activity_id', a.id,
      'title', a.title, 'starts_at', o.occurrence_starts_at,
      'ends_at', o.occurrence_ends_at, 'all_day', a.is_all_day,
      'area_id', a.area_id, 'status', a.status
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

    union all

    select jsonb_build_object(
      'kind', 'event', 'id', e.id, 'event_id', e.id,
      'title', e.title, 'starts_at', o.occurrence_starts_at,
      'ends_at', o.occurrence_ends_at, 'all_day', e.is_all_day,
      'area_id', e.area_id, 'status', e.status
    )
    from public.events e
    cross join lateral public.expand_recurrence_occurrences(
      e.starts_at, e.ends_at, e.recurrence_frequency, null, null,
      e.recurrence_until, e.recurrence_timezone, p_from, p_to
    ) o
    where public.can_view_event(e.id)
      and e.status <> 'cancelled'

    union all

    select jsonb_build_object(
      'kind', 'deadline', 'deadline_id', x ->> 'deadline_id',
      'title', x ->> 'title', 'due_on', x ->> 'occurrence_on',
      'occurs_on', x ->> 'occurrence_on', 'all_day', true,
      'is_completed', coalesce((x ->> 'completed')::boolean, false)
    )
    from public.get_deadline_occurrences(
      p_from::date,
      (p_to - interval '1 microsecond')::date
    ) x;
end;
$$;

revoke all on function public.can_view_event(uuid) from public, anon;
revoke all on function public.can_read_event(uuid) from public, anon;
revoke all on function public.get_visible_events() from public, anon;
revoke all on function public.get_calendar_occurrences(timestamp with time zone, timestamp with time zone) from public, anon;
grant execute on function public.can_view_event(uuid) to authenticated;
grant execute on function public.can_read_event(uuid) to authenticated;
grant execute on function public.get_visible_events() to authenticated;
grant execute on function public.get_calendar_occurrences(timestamp with time zone, timestamp with time zone) to authenticated;
alter function public.can_view_event(uuid) owner to postgres;
alter function public.can_read_event(uuid) owner to postgres;
alter function public.get_visible_events() owner to postgres;
alter function public.get_calendar_occurrences(timestamp with time zone, timestamp with time zone) owner to postgres;
