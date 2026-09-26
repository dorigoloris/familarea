-- FamilArea — separate personal Event feeds from Area program access.
-- AreaMembership remains for current Area consultation and management, but it
-- no longer makes an Area Event personal or part of a personal calendar.

begin;

create or replace function public.event_personal_source(p_event_id uuid, p_account_id uuid)
returns text
language sql stable security definer set search_path=public,pg_temp as $$
  select case
    when p_account_id is null then null
    when e.owner_account_id = p_account_id then 'owner'
    when e.area_id is null and e.created_by_account_id = p_account_id then 'creator'
    when exists (
      select 1 from public.event_participants ep
      join public.profiles p on p.id = ep.profile_id
      where ep.event_id = e.id and ep.status = 'active' and p.account_id = p_account_id
    ) then 'participant'
    else null
  end
  from public.events e where e.id = p_event_id
$$;

create or replace function public.event_visibility_source(p_event_id uuid)
returns text
language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce(
    public.event_personal_source(p_event_id, public.current_account_id()),
    case when e.area_id is not null
      and (public.is_area_owner(e.area_id) or public.is_area_member(e.area_id))
      then 'area' end
  )
  from public.events e where e.id = p_event_id
$$;

create or replace function public.can_view_event(p_event_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select public.event_visibility_source(p_event_id) is not null
$$;

create or replace function public.can_read_event(p_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select public.can_view_event(p_id)
$$;

create or replace function public.event_view_payload(p_event public.events, p_visibility_source text)
returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select to_jsonb(p_event) || jsonb_build_object(
    'visibility_source', p_visibility_source,
    'can_manage', p_visibility_source in ('owner', 'creator')
      or (p_visibility_source = 'area' and public.can_manage_area(p_event.area_id))
  )
$$;

create or replace function public.get_event(p_event_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_event public.events%rowtype; v_source text;
begin
  select e.* into v_event from public.events e where e.id = p_event_id;
  if not found then raise exception 'permission denied'; end if;
  v_source := public.event_visibility_source(p_event_id);
  if v_source is null then raise exception 'permission denied'; end if;
  return public.event_view_payload(v_event, v_source);
end $$;

create or replace function public.get_visible_events()
returns setof jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select public.event_view_payload(e, s.personal_source)
  from public.events e
  cross join lateral (select public.event_personal_source(e.id, public.current_account_id()) as personal_source) s
  where s.personal_source is not null and e.status <> 'cancelled'
  order by e.starts_at, e.created_at, e.id
$$;

create or replace function public.get_area_program(p_area_id uuid)
returns setof jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  perform public.require_area_read(p_area_id);
  return query
    select public.event_view_payload(e, public.event_visibility_source(e.id))
    from public.events e
    where e.area_id = p_area_id and e.status <> 'cancelled'
    order by e.starts_at, e.created_at, e.id;
end $$;

create or replace function public.get_dashboard(
  p_from timestamptz default now(),
  p_to timestamptz default now() + interval '30 days'
)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_account uuid := public.require_current_account();
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  return jsonb_build_object(
    'activities', coalesce((
      select jsonb_agg(to_jsonb(a) || jsonb_build_object(
        'kind', 'activity', 'activity_id', a.id,
        'occurrence_starts_at', o.occurrence_starts_at,
        'occurrence_ends_at', o.occurrence_ends_at) order by o.occurrence_starts_at)
      from public.activities a
      cross join lateral public.expand_recurrence_occurrences(
        coalesce(a.starts_at, a.due_at), a.due_at, a.recurrence_frequency,
        a.recurrence_interval, a.recurrence_weekdays, a.recurrence_until,
        a.recurrence_timezone, p_from, p_to) o
      where (a.owner_account_id = v_account or (a.area_id is not null
        and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id))))
        and a.status <> 'cancelled'
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(public.event_view_payload(e, s.personal_source) || jsonb_build_object(
        'kind', 'event', 'event_id', e.id,
        'occurrence_starts_at', o.occurrence_starts_at,
        'occurrence_ends_at', o.occurrence_ends_at) order by o.occurrence_starts_at)
      from public.events e
      cross join lateral (select public.event_personal_source(e.id, v_account) as personal_source) s
      cross join lateral public.expand_recurrence_occurrences(
        e.starts_at, e.ends_at, e.recurrence_frequency,
        e.recurrence_interval, e.recurrence_weekdays, e.recurrence_until,
        e.recurrence_timezone, p_from, p_to) o
      where s.personal_source is not null and e.status <> 'cancelled'
    ), '[]'::jsonb),
    'deadlines', coalesce((select jsonb_agg(x) from public.get_deadline_occurrences(
      p_from::date, (p_to - interval '1 microsecond')::date) x), '[]'::jsonb),
    'todos', coalesce((
      select jsonb_agg(to_jsonb(a) || jsonb_build_object('kind', 'activity', 'activity_id', a.id)
        order by a.created_at)
      from public.activities a
      where (a.owner_account_id = v_account or (a.area_id is not null
        and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id))))
        and a.status = 'open' and a.starts_at is null and a.due_at is null
    ), '[]'::jsonb)
  );
end $$;

create or replace function public.get_calendar_occurrences(p_from timestamptz, p_to timestamptz)
returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_account uuid := public.require_current_account();
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  return query
    with calendar_accounts as (
      select v_account as account_id, false as is_shared
      where coalesce((select l.visible from public.person_calendar_links l
        where l.owner_account_id = v_account and l.viewer_account_id = v_account), true)
      union all
      select l.owner_account_id, true
      from public.person_calendar_links l
      where l.viewer_account_id = v_account and l.owner_account_id <> v_account
        and l.visible and public.can_view_person_calendar(l.owner_account_id, v_account)
    )
    select jsonb_build_object(
      'kind','activity','id',a.id,'activity_id',a.id,'title',a.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,
      'all_day',a.is_all_day,'area_id',a.area_id,'status',a.status,
      'area_name',(select ar.name from public.areas ar where ar.id = a.area_id),
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.activities a on a.status <> 'cancelled'
      and (a.owner_account_id = s.account_id or (a.area_id is not null and exists (
        select 1 from public.areas ar where ar.id = a.area_id and (
          ar.owner_account_id = s.account_id or exists (
            select 1 from public.area_memberships am
            join public.profiles ap on ap.id = am.profile_id
            where am.area_id = ar.id and ap.account_id = s.account_id
          )
        )
      )))
    cross join lateral public.expand_recurrence_occurrences(
      coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,
      a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,
      a.recurrence_timezone,p_from,p_to
    ) o
    union all
    select jsonb_build_object(
      'kind','event','id',e.id,'event_id',e.id,'title',e.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,
      'all_day',e.is_all_day,'area_id',e.area_id,'status',e.status,
      'area_name',(select ar.name from public.areas ar where ar.id = e.area_id),
      'calendar_private',e.calendar_private,
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.events e on e.status <> 'cancelled'
      and (s.account_id = v_account or not e.calendar_private)
      and public.event_personal_source(e.id, s.account_id) is not null
    cross join lateral public.expand_recurrence_occurrences(
      e.starts_at,e.ends_at,e.recurrence_frequency,e.recurrence_interval,
      e.recurrence_weekdays,e.recurrence_until,e.recurrence_timezone,p_from,p_to
    ) o
    union all
    select jsonb_build_object(
      'kind','deadline','deadline_id',d.id,'title',d.title,
      'due_on',o.occurrence_on,'occurs_on',o.occurrence_on,'all_day',true,
      'is_completed',c.deadline_id is not null,
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.deadlines d on d.owner_account_id = s.account_id and d.status = 'active'
    cross join lateral generate_series(
      d.first_due_on, least(coalesce(d.terminated_on,v_to_date),v_to_date),
      make_interval(months => coalesce(d.recurrence_months,1200))
    ) o(occurrence_on)
    left join public.deadline_occurrence_completions c
      on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on
    where o.occurrence_on between p_from::date and v_to_date;
end $$;

create or replace function public.set_event_participants(p_event_id uuid, p_profile_ids uuid[])
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_scope record;
  v_profile_ids uuid[] := coalesce(p_profile_ids, '{}');
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);
  if array_position(v_profile_ids, null) is not null then raise exception 'invalid participant'; end if;
  if exists (
    select 1 from (select distinct unnest(v_profile_ids) as profile_id) selected
    where not exists (
      select 1 from public.contact_profile_links l
      join public.contacts c on c.id = l.contact_id
      where l.owner_account_id = v_scope.owner_account_id
        and l.profile_id = selected.profile_id
        and c.owner_account_id = v_scope.owner_account_id
    )
  ) then raise exception 'participant must be linked to an Event owner Contact'; end if;

  update public.event_participants ep
  set status = 'removed', updated_at = now()
  where ep.event_id = p_event_id and ep.status = 'active' and ep.added_via = 'direct'
    and ep.profile_id is not null
    and exists (select 1 from public.contact_profile_links l
      where l.owner_account_id = v_scope.owner_account_id and l.profile_id = ep.profile_id)
    and not (ep.profile_id = any(v_profile_ids));

  insert into public.event_participants (
    event_id, contact_id, profile_id, status, added_via, added_by_account_id
  )
  select p_event_id, l.contact_id, l.profile_id, 'active', 'direct', public.require_current_account()
  from (select distinct unnest(v_profile_ids) as profile_id) selected
  join public.contact_profile_links l
    on l.profile_id = selected.profile_id and l.owner_account_id = v_scope.owner_account_id
  join public.contacts c
    on c.id = l.contact_id and c.owner_account_id = v_scope.owner_account_id
  on conflict (event_id, contact_id) do update
    set profile_id = excluded.profile_id, status = 'active', added_via = 'direct',
        added_by_account_id = excluded.added_by_account_id, updated_at = now();
end $$;

alter function public.event_personal_source(uuid,uuid) owner to postgres;
alter function public.get_area_program(uuid) owner to postgres;
alter function public.event_visibility_source(uuid) owner to postgres;
alter function public.can_view_event(uuid) owner to postgres;
alter function public.can_read_event(uuid) owner to postgres;
alter function public.event_view_payload(public.events,text) owner to postgres;
alter function public.get_event(uuid) owner to postgres;
alter function public.get_visible_events() owner to postgres;
alter function public.get_dashboard(timestamptz,timestamptz) owner to postgres;
alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;
alter function public.set_event_participants(uuid,uuid[]) owner to postgres;

revoke all on function public.event_personal_source(uuid,uuid) from public,anon,authenticated;
revoke all on function public.get_area_program(uuid) from public,anon;
grant execute on function public.get_area_program(uuid) to authenticated;

commit;