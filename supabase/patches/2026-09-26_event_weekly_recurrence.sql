-- FamilArea — Event weekly recurrence interval and weekdays.
-- Legacy weekly rows keep NULL interval/weekdays; the occurrence helper supplies
-- their original interval=1 and start-weekday behavior without rewriting data.

begin;

alter table public.events
  add column recurrence_interval smallint,
  add column recurrence_weekdays smallint[];

alter table public.events
  add constraint events_recurrence_frequency_check
    check (recurrence_frequency is null or recurrence_frequency = 'weekly'),
  add constraint events_recurrence_interval_check
    check (recurrence_interval is null or recurrence_interval >= 1),
  add constraint events_recurrence_weekdays_check
    check (
      recurrence_weekdays is null
      or (
        cardinality(recurrence_weekdays) > 0
        and array_position(recurrence_weekdays, null) is null
        and recurrence_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]
      )
    ),
  add constraint events_recurrence_fields_check
    check (recurrence_frequency is not null or (recurrence_interval is null and recurrence_weekdays is null));

create or replace function public.expand_recurrence_occurrences(
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_frequency text,
  p_interval smallint,
  p_weekdays smallint[],
  p_until date,
  p_timezone text,
  p_from timestamptz,
  p_to timestamptz
)
returns table(occurrence_starts_at timestamptz, occurrence_ends_at timestamptz)
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  v_start timestamptz := p_starts_at;
  v_end timestamptz := coalesce(p_ends_at, p_starts_at);
  v_frequency text := nullif(lower(btrim(coalesce(p_frequency,''))), '');
  v_interval integer := greatest(coalesce(p_interval,1),1);
  v_timezone text := coalesce(nullif(btrim(coalesce(p_timezone,'')),''),'UTC');
  v_local_start timestamp;
  v_local_end timestamp;
  v_local_duration interval;
  v_weekdays smallint[];
  v_candidate_date date;
  v_candidate_local timestamp;
  v_candidate_start timestamptz;
  v_candidate_end timestamptz;
begin
  if v_start is null then return; end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid occurrence range';
  end if;
  if p_to > p_from + interval '400 days' then
    raise exception 'occurrence range too large';
  end if;

  if v_frequency is null then
    if v_start < p_to and (v_end > p_from or (v_end = v_start and v_start >= p_from)) then
      occurrence_starts_at := v_start;
      occurrence_ends_at := v_end;
      return next;
    end if;
    return;
  end if;
  if v_frequency not in ('daily','weekly') then
    raise exception 'unsupported recurrence frequency';
  end if;
  perform 1 from pg_timezone_names where name = v_timezone;
  if not found then raise exception 'invalid recurrence timezone'; end if;

  v_local_start := v_start at time zone v_timezone;
  v_local_end := v_end at time zone v_timezone;
  v_local_duration := greatest(v_local_end - v_local_start, interval '0');
  v_weekdays := coalesce(nullif(p_weekdays,'{}'::smallint[]),
    array[extract(isodow from v_local_start)::smallint]);

  for v_candidate_date in
    select d::date
    from generate_series(
      (p_from at time zone v_timezone)::date - 1,
      (p_to at time zone v_timezone)::date + 1,
      interval '1 day'
    ) d
  loop
    if v_candidate_date < v_local_start::date
      or (p_until is not null and v_candidate_date > p_until) then continue; end if;
    if v_frequency = 'daily'
      and mod(v_candidate_date - v_local_start::date, v_interval) <> 0 then continue; end if;
    if v_frequency = 'weekly' and (
      extract(isodow from v_candidate_date)::smallint <> all(v_weekdays)
      or mod((v_candidate_date - date_trunc('week',v_local_start)::date) / 7,v_interval) <> 0
    ) then continue; end if;

    v_candidate_local := v_candidate_date + v_local_start::time;
    v_candidate_start := v_candidate_local at time zone v_timezone;
    v_candidate_end := (v_candidate_local + v_local_duration) at time zone v_timezone;
    if v_candidate_start < p_to and (
      v_candidate_end > p_from
      or (v_candidate_end = v_candidate_start and v_candidate_start >= p_from)
    ) then
      occurrence_starts_at := v_candidate_start;
      occurrence_ends_at := v_candidate_end;
      return next;
    end if;
  end loop;
end $$;

create or replace function public.create_event(
  p_title text,
  p_starts_at timestamptz,
  p_ends_at timestamptz default null,
  p_description text default null,
  p_area_id uuid default null,
  p_is_all_day boolean default false,
  p_location text default null,
  p_recurrence jsonb default '{}'::jsonb,
  p_calendar_private boolean default false
)
returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_owner uuid;
  v_id uuid;
  v_frequency text := nullif(lower(btrim(coalesce(p_recurrence->>'frequency',''))), '');
  v_interval smallint;
  v_weekdays smallint[];
  v_until date := nullif(p_recurrence->>'until','')::date;
  v_timezone text := nullif(btrim(coalesce(p_recurrence->>'timezone','')), '');
  v_private boolean := coalesce(p_calendar_private, false);
begin
  if p_area_id is null then
    v_owner := public.require_current_account();
    if v_private and not exists (
      select 1 from public.accounts a where a.id = v_owner and a.account_type = 'personal'
    ) then raise exception 'only personal events can be private in a shared calendar'; end if;
  else
    perform public.require_area_manage(p_area_id);
    if v_private then raise exception 'Area events cannot be marked private in a person calendar'; end if;
    v_private := false;
  end if;

  if v_frequency is null then
    v_interval := null;
    v_weekdays := null;
    v_until := null;
    v_timezone := null;
  else
    if v_frequency <> 'weekly' then raise exception 'unsupported recurrence frequency'; end if;
    v_interval := coalesce(nullif(p_recurrence->>'interval','')::smallint, 1);
    if v_interval < 1 then raise exception 'invalid recurrence interval'; end if;
    if p_recurrence ? 'weekdays' then
      if jsonb_typeof(p_recurrence->'weekdays') <> 'array' then
        raise exception 'invalid recurrence weekdays';
      end if;
      select array_agg(distinct value::smallint order by value::smallint)
        into v_weekdays
      from jsonb_array_elements_text(p_recurrence->'weekdays') as weekdays(value);
    else
      v_weekdays := array[extract(isodow from (p_starts_at at time zone v_timezone))::smallint];
    end if;
    if v_weekdays is null or cardinality(v_weekdays) = 0
      or array_position(v_weekdays, null) is not null
      or not (v_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]) then
      raise exception 'invalid recurrence weekdays';
    end if;
    perform 1 from pg_timezone_names where name = v_timezone;
    if v_timezone is null or not found then raise exception 'invalid recurrence timezone'; end if;
    if v_until is not null and v_until < (p_starts_at at time zone v_timezone)::date then
      raise exception 'recurrence end date precedes event start';
    end if;
  end if;

  insert into public.events (
    owner_account_id, area_id, title, description, starts_at, ends_at, is_all_day,
    location, recurrence_frequency, recurrence_interval, recurrence_weekdays,
    recurrence_until, recurrence_timezone, created_by_account_id, calendar_private
  ) values (
    v_owner, p_area_id, nullif(btrim(p_title), ''), nullif(btrim(p_description), ''),
    p_starts_at, p_ends_at, coalesce(p_is_all_day, false), nullif(btrim(p_location), ''),
    v_frequency, v_interval, v_weekdays, v_until, v_timezone,
    public.require_current_account(), v_private
  ) returning id into v_id;
  return v_id;
end $$;

create or replace function public.update_event(
  p_event_id uuid,
  p_title text,
  p_starts_at timestamptz,
  p_ends_at timestamptz default null,
  p_description text default null,
  p_is_all_day boolean default false,
  p_location text default null,
  p_recurrence jsonb default '{}'::jsonb,
  p_calendar_private boolean default false
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v public.events%rowtype;
  v_frequency text := nullif(lower(btrim(coalesce(p_recurrence->>'frequency',''))), '');
  v_interval smallint;
  v_weekdays smallint[];
  v_until date := nullif(p_recurrence->>'until','')::date;
  v_timezone text := nullif(btrim(coalesce(p_recurrence->>'timezone','')), '');
  v_private boolean := coalesce(p_calendar_private, false);
begin
  select * into v from public.events where id = p_event_id;
  if not found
    or (v.owner_account_id is not null and v.owner_account_id <> public.require_current_account())
    or (v.area_id is not null and not public.can_manage_area(v.area_id)) then
    raise exception 'permission denied';
  end if;
  if v.area_id is not null then
    if v_private then raise exception 'Area events cannot be marked private in a person calendar'; end if;
    v_private := false;
  elsif v_private and not exists (
    select 1 from public.accounts a where a.id = v.owner_account_id and a.account_type = 'personal'
  ) then raise exception 'only personal events can be private in a shared calendar';
  end if;

  if v_frequency is null then
    v_interval := null;
    v_weekdays := null;
    v_until := null;
    v_timezone := null;
  else
    if v_frequency <> 'weekly' then raise exception 'unsupported recurrence frequency'; end if;
    v_interval := coalesce(nullif(p_recurrence->>'interval','')::smallint, 1);
    if v_interval < 1 then raise exception 'invalid recurrence interval'; end if;
    if p_recurrence ? 'weekdays' then
      if jsonb_typeof(p_recurrence->'weekdays') <> 'array' then
        raise exception 'invalid recurrence weekdays';
      end if;
      select array_agg(distinct value::smallint order by value::smallint)
        into v_weekdays
      from jsonb_array_elements_text(p_recurrence->'weekdays') as weekdays(value);
    else
      v_weekdays := array[extract(isodow from (p_starts_at at time zone v_timezone))::smallint];
    end if;
    if v_weekdays is null or cardinality(v_weekdays) = 0
      or array_position(v_weekdays, null) is not null
      or not (v_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]) then
      raise exception 'invalid recurrence weekdays';
    end if;
    perform 1 from pg_timezone_names where name = v_timezone;
    if v_timezone is null or not found then raise exception 'invalid recurrence timezone'; end if;
    if v_until is not null and v_until < (p_starts_at at time zone v_timezone)::date then
      raise exception 'recurrence end date precedes event start';
    end if;
  end if;

  update public.events
  set title = nullif(btrim(p_title), ''),
      description = nullif(btrim(p_description), ''),
      starts_at = p_starts_at,
      ends_at = p_ends_at,
      is_all_day = coalesce(p_is_all_day, false),
      location = nullif(btrim(p_location), ''),
      recurrence_frequency = v_frequency,
      recurrence_interval = v_interval,
      recurrence_weekdays = v_weekdays,
      recurrence_until = v_until,
      recurrence_timezone = v_timezone,
      calendar_private = v_private
  where id = p_event_id returning * into v;
  return to_jsonb(v);
end $$;

create or replace function public.get_dashboard(
  p_from timestamptz default now(),
  p_to timestamptz default now() + interval '30 days'
)
returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
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
      select jsonb_agg(public.event_view_payload(e, s.visibility_source) || jsonb_build_object(
        'kind', 'event', 'event_id', e.id,
        'occurrence_starts_at', o.occurrence_starts_at,
        'occurrence_ends_at', o.occurrence_ends_at) order by o.occurrence_starts_at)
      from public.events e
      cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s
      cross join lateral public.expand_recurrence_occurrences(
        e.starts_at, e.ends_at, e.recurrence_frequency,
        e.recurrence_interval, e.recurrence_weekdays, e.recurrence_until,
        e.recurrence_timezone, p_from, p_to) o
      where s.visibility_source is not null and e.status <> 'cancelled'
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
returns setof jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
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
      and (e.owner_account_id = s.account_id
        or (e.area_id is not null and exists (
          select 1 from public.areas ar where ar.id = e.area_id and (
            ar.owner_account_id = s.account_id or exists (
              select 1 from public.area_memberships am
              join public.profiles ap on ap.id = am.profile_id
              where am.area_id = ar.id and ap.account_id = s.account_id
            )
          )
        ))
        or exists (
          select 1 from public.event_participants ep
          join public.profiles pp on pp.id = ep.profile_id
          where ep.event_id = e.id and ep.status = 'active' and pp.account_id = s.account_id
        ))
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

alter function public.create_event(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,boolean) owner to postgres;
alter function public.update_event(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,boolean) owner to postgres;
alter function public.expand_recurrence_occurrences(timestamptz,timestamptz,text,smallint,smallint[],date,text,timestamptz,timestamptz) owner to postgres;
alter function public.get_dashboard(timestamptz,timestamptz) owner to postgres;
alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;

revoke all on function public.create_event(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,boolean),
  public.update_event(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,boolean),
  public.get_dashboard(timestamptz,timestamptz),
  public.get_calendar_occurrences(timestamptz,timestamptz)
  from public, anon;
grant execute on function public.create_event(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,boolean),
  public.update_event(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,boolean),
  public.get_dashboard(timestamptz,timestamptz),
  public.get_calendar_occurrences(timestamptz,timestamptz)
  to authenticated;

commit;