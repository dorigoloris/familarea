-- FamilArea — Attività ricorrenti settimanali (MVP).
-- Le occorrenze restano virtuali: non vengono mai persistite.

begin;

alter table public.area_activities
  add column recurrence_frequency text null,
  add column recurrence_interval smallint null,
  add column recurrence_weekdays smallint[] null,
  add column recurrence_until date null,
  add column recurrence_timezone text null;

alter table public.area_activities
  add constraint area_activities_recurrence_frequency_check
    check (recurrence_frequency is null or recurrence_frequency = 'weekly'),
  add constraint area_activities_recurrence_configuration_check
    check (
      (
        recurrence_frequency is null
        and recurrence_interval is null
        and recurrence_weekdays is null
        and recurrence_until is null
        and recurrence_timezone is null
      )
      or (
        recurrence_frequency = 'weekly'
        and starts_at is not null
        and recurrence_interval is not null
        and recurrence_interval > 0
        and recurrence_weekdays is not null
        and cardinality(recurrence_weekdays) > 0
        and array_position(recurrence_weekdays, null) is null
        and recurrence_weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]
        and recurrence_until is not null
        and recurrence_timezone is not null
        and btrim(recurrence_timezone) <> ''
        and extract(isodow from (starts_at at time zone recurrence_timezone))::smallint = any(recurrence_weekdays)
        and recurrence_until >= (starts_at at time zone recurrence_timezone)::date
      )
    );

create index area_activities_weekly_recurrence_idx
  on public.area_activities (area_id, recurrence_until)
  where recurrence_frequency = 'weekly' and status = 'open';

-- I RETURNS TABLE cambiano: rimuoviamo le vecchie firme e ricreiamo
-- immediatamente le versioni finali nella stessa transazione.
drop function if exists public.get_area_activities(uuid, text, text, boolean, timestamptz, timestamptz);
drop function if exists public.get_area_activity(uuid, uuid);
drop function if exists public.get_my_visible_activities();
drop function if exists public.create_area_activity(uuid, text, text, text, text, timestamptz, timestamptz, boolean, uuid[], text);
drop function if exists public.update_area_activity(uuid, uuid, text, text, text, text, timestamptz, timestamptz, boolean, text);

create function public.get_area_activities(
  p_area_id uuid,
  p_status text default null,
  p_activity_type text default null,
  p_assigned_to_me boolean default false,
  p_due_from timestamptz default null,
  p_due_to timestamptz default null
)
returns table(
  id uuid, title text, notes text, activity_type text, status text, priority text,
  starts_at timestamptz, due_at timestamptz, is_all_day boolean,
  created_by_profile_id uuid, completed_by_profile_id uuid, completed_at timestamptz,
  created_at timestamptz, updated_at timestamptz,
  recurrence_frequency text, recurrence_interval smallint, recurrence_weekdays smallint[],
  recurrence_until date, recurrence_timezone text
)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile uuid;
begin
  select profile_id into v_profile from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;

  return query
  select
    a.id, a.title, a.notes, a.activity_type, a.status, a.priority,
    a.starts_at, a.due_at, a.is_all_day,
    a.created_by_profile_id, a.completed_by_profile_id, a.completed_at,
    a.created_at, a.updated_at,
    a.recurrence_frequency, a.recurrence_interval, a.recurrence_weekdays,
    a.recurrence_until, a.recurrence_timezone
  from public.area_activities a
  where a.area_id = p_area_id
    and (p_status is null or a.status = p_status)
    and (p_activity_type is null or a.activity_type = p_activity_type)
    and (p_due_from is null or a.due_at >= p_due_from)
    and (p_due_to is null or a.due_at <= p_due_to)
    and (
      a.visibility = 'area'
      or a.created_by_profile_id = v_profile
      or (
        a.visibility = 'creator_assignees'
        and exists (
          select 1 from public.activity_assignees aa
          where aa.activity_id = a.id and aa.profile_id = v_profile
        )
      )
    )
    and (
      not p_assigned_to_me
      or exists (
        select 1 from public.activity_assignees aa
        where aa.activity_id = a.id and aa.profile_id = v_profile
      )
      or not exists (
        select 1 from public.activity_assignees aa where aa.activity_id = a.id
      )
    )
  order by a.due_at nulls last, a.created_at desc;
end;
$$;

create function public.get_area_activity(p_area_id uuid, p_activity_id uuid)
returns table(
  id uuid, title text, notes text, activity_type text, status text, priority text,
  visibility text, assignee_profile_ids uuid[], starts_at timestamptz, due_at timestamptz,
  is_all_day boolean, created_by_profile_id uuid, completed_by_profile_id uuid,
  completed_at timestamptz, created_at timestamptz, updated_at timestamptz,
  recurrence_frequency text, recurrence_interval smallint, recurrence_weekdays smallint[],
  recurrence_until date, recurrence_timezone text
)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile uuid;
begin
  select profile_id into v_profile from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;

  return query
  select
    a.id, a.title, a.notes, a.activity_type, a.status, a.priority, a.visibility,
    array(
      select aa.profile_id from public.activity_assignees aa
      where aa.activity_id = a.id order by aa.assigned_at, aa.profile_id
    ),
    a.starts_at, a.due_at, a.is_all_day,
    a.created_by_profile_id, a.completed_by_profile_id, a.completed_at,
    a.created_at, a.updated_at,
    a.recurrence_frequency, a.recurrence_interval, a.recurrence_weekdays,
    a.recurrence_until, a.recurrence_timezone
  from public.area_activities a
  where a.id = p_activity_id
    and a.area_id = p_area_id
    and (
      a.visibility = 'area'
      or a.created_by_profile_id = v_profile
      or (
        a.visibility = 'creator_assignees'
        and exists (
          select 1 from public.activity_assignees aa
          where aa.activity_id = a.id and aa.profile_id = v_profile
        )
      )
    );

  if not found then raise exception 'Attivita non trovata o non accessibile'; end if;
end;
$$;

create function public.get_my_visible_activities()
returns table(
  activity_id uuid, area_id uuid, area_name text, area_type text, title text,
  notes text, activity_type text, status text, priority text, starts_at timestamptz,
  due_at timestamptz, is_all_day boolean, visibility text, created_by_profile_id uuid,
  created_at timestamptz, updated_at timestamptz, recurrence_frequency text,
  recurrence_interval smallint, recurrence_weekdays smallint[], recurrence_until date,
  recurrence_timezone text
)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'permission denied'; end if;

  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'permission denied'; end if;

  return query
  select
    a.id, ar.id, ar.name, ar.area_type, a.title, a.notes, a.activity_type,
    a.status, a.priority, a.starts_at, a.due_at, a.is_all_day, a.visibility,
    a.created_by_profile_id, a.created_at, a.updated_at,
    a.recurrence_frequency, a.recurrence_interval, a.recurrence_weekdays,
    a.recurrence_until, a.recurrence_timezone
  from public.area_memberships am
  join public.areas ar on ar.id = am.area_id
  join public.area_activities a on a.area_id = am.area_id
  where am.profile_id = v_profile_id
    and am.role in ('admin', 'member')
    and (
      a.visibility = 'area'
      or a.created_by_profile_id = v_profile_id
      or (
        a.visibility = 'creator_assignees'
        and exists (
          select 1 from public.activity_assignees aa
          where aa.activity_id = a.id and aa.profile_id = v_profile_id
        )
      )
    )
  order by coalesce(a.due_at, a.starts_at) asc nulls last, a.created_at asc, a.id asc;
end;
$$;

create function public.create_area_activity(
  p_area_id uuid,
  p_title text,
  p_notes text,
  p_activity_type text,
  p_priority text,
  p_starts_at timestamptz,
  p_due_at timestamptz,
  p_is_all_day boolean,
  p_assignee_profile_ids uuid[],
  p_visibility text,
  p_recurrence_frequency text default null,
  p_recurrence_interval smallint default null,
  p_recurrence_weekdays smallint[] default null,
  p_recurrence_until date default null,
  p_recurrence_timezone text default null
)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_profile uuid;
  v_role text;
  v_ids uuid[] := coalesce(p_assignee_profile_ids, '{}');
  v_id uuid;
  v_frequency text := nullif(lower(btrim(coalesce(p_recurrence_frequency, ''))), '');
  v_interval smallint := p_recurrence_interval;
  v_weekdays smallint[];
  v_until date := p_recurrence_until;
  v_timezone text := nullif(btrim(coalesce(p_recurrence_timezone, '')), '');
begin
  select profile_id, role into v_profile, v_role
  from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;

  if p_recurrence_weekdays is not null then
    select array_agg(distinct weekday order by weekday)
      into v_weekdays
    from unnest(p_recurrence_weekdays) as days(weekday);
  end if;

  if btrim(coalesce(p_title, '')) = ''
     or p_activity_type not in ('task', 'reminder', 'deadline', 'appointment')
     or p_priority not in ('low', 'normal', 'high')
     or p_visibility not in ('private', 'creator_assignees', 'area')
     or (p_starts_at is not null and p_due_at is not null and p_due_at < p_starts_at) then
    raise exception 'Dati attivita non validi';
  end if;

  if v_frequency is null then
    if v_interval is not null or v_weekdays is not null or v_until is not null or v_timezone is not null then
      raise exception 'Configurazione ricorrenza non valida';
    end if;
  elsif v_frequency <> 'weekly'
     or p_starts_at is null
     or v_interval is null or v_interval <= 0
     or v_weekdays is null or cardinality(v_weekdays) = 0
     or array_position(v_weekdays, null) is not null
     or not (v_weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[])
     or v_until is null
     or v_timezone is null then
    raise exception 'Configurazione ricorrenza non valida';
  else
    perform 1 from pg_timezone_names where name = v_timezone;
    if not found then raise exception 'Timezone ricorrenza non valida'; end if;
    if v_until < (p_starts_at at time zone v_timezone)::date then
      raise exception 'La fine della ricorrenza non puo precedere la prima occorrenza';
    end if;
    if extract(isodow from (p_starts_at at time zone v_timezone))::smallint <> all(v_weekdays) then
      raise exception 'Il giorno della prima occorrenza deve appartenere alla ricorrenza';
    end if;
  end if;

  if (p_visibility = 'private' and cardinality(v_ids) > 0)
     or (p_visibility = 'creator_assignees' and cardinality(v_ids) = 0) then
    raise exception 'Visibilita e assegnatari non coerenti';
  end if;
  if v_role = 'member' and exists (select 1 from unnest(v_ids) x where x is distinct from v_profile) then
    raise exception 'permission denied';
  end if;
  if exists (
    select 1 from unnest(v_ids) x
    left join public.area_memberships am on am.area_id = p_area_id and am.profile_id = x
    where am.profile_id is null
  ) then raise exception 'Assegnatario non appartenente all''Area'; end if;

  insert into public.area_activities (
    area_id, title, notes, activity_type, priority, visibility, starts_at, due_at,
    is_all_day, created_by_profile_id, recurrence_frequency, recurrence_interval,
    recurrence_weekdays, recurrence_until, recurrence_timezone
  ) values (
    p_area_id, btrim(p_title), p_notes, p_activity_type, p_priority, p_visibility,
    p_starts_at, p_due_at, coalesce(p_is_all_day, false), v_profile, v_frequency,
    v_interval, v_weekdays, v_until, v_timezone
  ) returning id into v_id;

  insert into public.activity_assignees(activity_id, area_id, profile_id, assigned_by_profile_id)
  select v_id, p_area_id, x, v_profile
  from (select distinct unnest(v_ids) x) selected;
  return v_id;
end;
$$;

create function public.update_area_activity(
  p_area_id uuid,
  p_activity_id uuid,
  p_title text,
  p_notes text,
  p_activity_type text,
  p_priority text,
  p_starts_at timestamptz,
  p_due_at timestamptz,
  p_is_all_day boolean,
  p_visibility text,
  p_recurrence_frequency text default null,
  p_recurrence_interval smallint default null,
  p_recurrence_weekdays smallint[] default null,
  p_recurrence_until date default null,
  p_recurrence_timezone text default null,
  p_update_recurrence boolean default false
)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_profile uuid;
  v_role text;
  v_creator uuid;
  v_current_visibility text;
  v_frequency text := nullif(lower(btrim(coalesce(p_recurrence_frequency, ''))), '');
  v_interval smallint := p_recurrence_interval;
  v_weekdays smallint[];
  v_until date := p_recurrence_until;
  v_timezone text := nullif(btrim(coalesce(p_recurrence_timezone, '')), '');
begin
  select profile_id, role into v_profile, v_role
  from public.current_area_activity_role(p_area_id);
  if v_profile is null then raise exception 'permission denied'; end if;

  select created_by_profile_id, visibility into v_creator, v_current_visibility
  from public.area_activities
  where id = p_activity_id and area_id = p_area_id
  for update;
  if not found then raise exception 'Attivita non trovata'; end if;
  if v_creator is distinct from v_profile
     and not (v_current_visibility = 'area' and p_visibility = 'area' and v_role = 'admin') then
    raise exception 'permission denied';
  end if;

  if btrim(coalesce(p_title, '')) = ''
     or p_activity_type not in ('task', 'reminder', 'deadline', 'appointment')
     or p_priority not in ('low', 'normal', 'high')
     or p_visibility not in ('private', 'creator_assignees', 'area')
     or (p_starts_at is not null and p_due_at is not null and p_due_at < p_starts_at) then
    raise exception 'Dati attivita non validi';
  end if;

  if p_update_recurrence then
    if p_recurrence_weekdays is not null then
      select array_agg(distinct weekday order by weekday)
        into v_weekdays
      from unnest(p_recurrence_weekdays) as days(weekday);
    end if;

    if v_frequency is null then
      -- La disattivazione è esplicita: i valori accessori vengono sempre azzerati.
      v_interval := null;
      v_weekdays := null;
      v_until := null;
      v_timezone := null;
    elsif v_frequency <> 'weekly'
       or p_starts_at is null
       or v_interval is null or v_interval <= 0
       or v_weekdays is null or cardinality(v_weekdays) = 0
       or array_position(v_weekdays, null) is not null
       or not (v_weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[])
       or v_until is null
       or v_timezone is null then
      raise exception 'Configurazione ricorrenza non valida';
    else
      perform 1 from pg_timezone_names where name = v_timezone;
      if not found then raise exception 'Timezone ricorrenza non valida'; end if;
      if v_until < (p_starts_at at time zone v_timezone)::date then
        raise exception 'La fine della ricorrenza non puo precedere la prima occorrenza';
      end if;
      if extract(isodow from (p_starts_at at time zone v_timezone))::smallint <> all(v_weekdays) then
        raise exception 'Il giorno della prima occorrenza deve appartenere alla ricorrenza';
      end if;
    end if;
  end if;

  if (p_visibility = 'private' and exists (
        select 1 from public.activity_assignees where activity_id = p_activity_id
      ))
     or (p_visibility = 'creator_assignees' and not exists (
        select 1 from public.activity_assignees where activity_id = p_activity_id
      )) then
    raise exception 'Visibilita e assegnatari non coerenti';
  end if;

  update public.area_activities
  set title = btrim(p_title), notes = p_notes, activity_type = p_activity_type,
      priority = p_priority, visibility = p_visibility, starts_at = p_starts_at,
      due_at = p_due_at, is_all_day = coalesce(p_is_all_day, false),
      recurrence_frequency = case when p_update_recurrence then v_frequency else recurrence_frequency end,
      recurrence_interval = case when p_update_recurrence then v_interval else recurrence_interval end,
      recurrence_weekdays = case when p_update_recurrence then v_weekdays else recurrence_weekdays end,
      recurrence_until = case when p_update_recurrence then v_until else recurrence_until end,
      recurrence_timezone = case when p_update_recurrence then v_timezone else recurrence_timezone end
  where id = p_activity_id and area_id = p_area_id;
end;
$$;

create function public.get_my_visible_activity_occurrences(
  p_from timestamptz,
  p_to timestamptz
)
returns table(
  activity_id uuid, area_id uuid, area_name text, area_type text, title text,
  notes text, activity_type text, status text, priority text, visibility text,
  is_all_day boolean, created_by_profile_id uuid, created_at timestamptz,
  updated_at timestamptz, occurrence_starts_at timestamptz,
  occurrence_ends_at timestamptz, recurrence_frequency text
)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_profile_id uuid;
begin
  if auth.uid() is null then raise exception 'permission denied'; end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'Intervallo occorrenze non valido';
  end if;
  if p_to > p_from + interval '400 days' then
    raise exception 'Intervallo occorrenze troppo ampio';
  end if;

  select p.id into v_profile_id
  from public.profiles p
  where p.user_id = auth.uid();
  if v_profile_id is null then raise exception 'permission denied'; end if;

  return query
  with visible_activities as (
    select a.*, ar.name as visible_area_name, ar.area_type as visible_area_type
    from public.area_memberships am
    join public.areas ar on ar.id = am.area_id
    join public.area_activities a on a.area_id = am.area_id
    where am.profile_id = v_profile_id
      and am.role in ('admin', 'member')
      and (
        a.visibility = 'area'
        or a.created_by_profile_id = v_profile_id
        or (
          a.visibility = 'creator_assignees'
          and exists (
            select 1 from public.activity_assignees aa
            where aa.activity_id = a.id and aa.profile_id = v_profile_id
          )
        )
      )
  ),
  single_occurrences as (
    select
      a.id as activity_id, a.area_id, a.visible_area_name as area_name,
      a.visible_area_type as area_type, a.title, a.notes, a.activity_type,
      a.status, a.priority, a.visibility, a.is_all_day, a.created_by_profile_id,
      a.created_at, a.updated_at,
      coalesce(a.starts_at, a.due_at) as occurrence_starts_at,
      coalesce(a.due_at, a.starts_at) as occurrence_ends_at,
      a.recurrence_frequency
    from visible_activities a
    where a.recurrence_frequency is null
      and a.status <> 'cancelled'
      and coalesce(a.starts_at, a.due_at) >= p_from
      and coalesce(a.starts_at, a.due_at) < p_to
  ),
  recurring_candidates as (
    select
      a.*, candidate.local_day::date as occurrence_date,
      ((candidate.local_day::date + (a.starts_at at time zone a.recurrence_timezone)::time)
        at time zone a.recurrence_timezone) as occurrence_starts_at,
      (
        (candidate.local_day::date + (a.starts_at at time zone a.recurrence_timezone)::time)
        + ((a.due_at at time zone a.recurrence_timezone)
          - (a.starts_at at time zone a.recurrence_timezone))
      ) at time zone a.recurrence_timezone as occurrence_ends_at
    from visible_activities a
    cross join lateral generate_series(
      greatest(
        (a.starts_at at time zone a.recurrence_timezone)::date,
        ((p_from at time zone a.recurrence_timezone)::date - 1)
      )::timestamp,
      least(
        a.recurrence_until,
        ((p_to at time zone a.recurrence_timezone)::date + 1)
      )::timestamp,
      interval '1 day'
    ) as candidate(local_day)
    where a.recurrence_frequency = 'weekly'
      and a.status = 'open'
      and extract(isodow from candidate.local_day)::smallint = any(a.recurrence_weekdays)
      and (
        ((candidate.local_day::date
          - (extract(isodow from (a.starts_at at time zone a.recurrence_timezone))::integer - 1))
          - ((a.starts_at at time zone a.recurrence_timezone)::date
          - (extract(isodow from (a.starts_at at time zone a.recurrence_timezone))::integer - 1)))
        / 7
      ) % a.recurrence_interval = 0
  ),
  recurring_occurrences as (
    select
      a.id as activity_id, a.area_id, a.visible_area_name as area_name,
      a.visible_area_type as area_type, a.title, a.notes, a.activity_type,
      a.status, a.priority, a.visibility, a.is_all_day, a.created_by_profile_id,
      a.created_at, a.updated_at, a.occurrence_starts_at, a.occurrence_ends_at,
      a.recurrence_frequency
    from recurring_candidates a
    where a.occurrence_starts_at >= p_from
      and a.occurrence_starts_at < p_to
  )
  select * from single_occurrences
  union all
  select * from recurring_occurrences
  order by occurrence_starts_at, created_at, activity_id;
end;
$$;

alter function public.get_area_activities(uuid, text, text, boolean, timestamptz, timestamptz) owner to postgres;
alter function public.get_area_activity(uuid, uuid) owner to postgres;
alter function public.get_my_visible_activities() owner to postgres;
alter function public.create_area_activity(uuid, text, text, text, text, timestamptz, timestamptz, boolean, uuid[], text, text, smallint, smallint[], date, text) owner to postgres;
alter function public.update_area_activity(uuid, uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, text, smallint, smallint[], date, text, boolean) owner to postgres;
alter function public.get_my_visible_activity_occurrences(timestamptz, timestamptz) owner to postgres;

revoke all on function public.get_area_activities(uuid, text, text, boolean, timestamptz, timestamptz) from public;
revoke all on function public.get_area_activity(uuid, uuid) from public;
revoke all on function public.get_my_visible_activities() from public;
revoke all on function public.create_area_activity(uuid, text, text, text, text, timestamptz, timestamptz, boolean, uuid[], text, text, smallint, smallint[], date, text) from public;
revoke all on function public.update_area_activity(uuid, uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, text, smallint, smallint[], date, text, boolean) from public;
revoke all on function public.get_my_visible_activity_occurrences(timestamptz, timestamptz) from public;

grant execute on function public.get_area_activities(uuid, text, text, boolean, timestamptz, timestamptz) to authenticated;
grant execute on function public.get_area_activity(uuid, uuid) to authenticated;
grant execute on function public.get_my_visible_activities() to authenticated;
grant execute on function public.create_area_activity(uuid, text, text, text, text, timestamptz, timestamptz, boolean, uuid[], text, text, smallint, smallint[], date, text) to authenticated;
grant execute on function public.update_area_activity(uuid, uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, text, smallint, smallint[], date, text, boolean) to authenticated;
grant execute on function public.get_my_visible_activity_occurrences(timestamptz, timestamptz) to authenticated;

commit;
