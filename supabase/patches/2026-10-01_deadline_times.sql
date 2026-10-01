-- FamilArea — orari opzionali per le scadenze.
-- Una scadenza senza start_time resta un elemento tutto il giorno.

begin;

alter table public.deadlines
  add column start_time time without time zone null,
  add column end_time time without time zone null;

alter table public.deadlines
  add constraint deadlines_time_range_check check (
    (start_time is null and end_time is null)
    or (start_time is not null and (end_time is null or end_time > start_time))
  );

-- L'identità PostgreSQL include tutti gli argomenti: rimuoviamo le signature
-- precedenti per evitare overload RPC ambigui quando i parametri opzionali sono aggiunti in coda.
drop function if exists public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid);
drop function if exists public.update_my_managed_deadline(uuid,uuid,text,text,date,smallint,smallint,text);
drop function if exists public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text);
drop function if exists public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text);
drop function if exists public.create_deadline(text,text,date,smallint,smallint,text,uuid);

create or replace function public.create_deadline(
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_family_member_id uuid default null,
  p_start_time time default null,
  p_end_time time default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_current_account();
  v_owner_account_id uuid := v_actor_account_id;
  v_id uuid;
begin
  if p_family_member_id is not null then
    perform public.assert_manage_owned_family_member(p_family_member_id);
    select f.owner_account_id into v_owner_account_id
    from public.family_members fm join public.families f on f.id = fm.family_id
    where fm.id = p_family_member_id;
  end if;

  insert into public.deadlines(
    owner_account_id, title, category, first_due_on, recurrence_months,
    reminder_days, notes, family_member_id, start_time, end_time
  ) values (
    v_owner_account_id, nullif(btrim(p_title), ''), nullif(btrim(p_category), ''),
    p_first_due_on, p_recurrence_months, coalesce(p_reminder_days, 30),
    nullif(btrim(p_notes), ''), p_family_member_id, p_start_time, p_end_time
  ) returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.update_deadline(
  p_deadline_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_family_member_id uuid default null,
  p_status text default 'active',
  p_start_time time default null,
  p_end_time time default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v public.deadlines%rowtype;
begin
  if p_family_member_id is not null and not exists(
    select 1
    from public.family_members fm
    join public.families f on f.id = fm.family_id
    where fm.id = p_family_member_id
      and f.owner_account_id = public.require_current_account()
  ) then
    raise exception 'invalid family member';
  end if;

  update public.deadlines
  set title = nullif(btrim(p_title), ''),
      category = nullif(btrim(p_category), ''),
      first_due_on = p_first_due_on,
      recurrence_months = p_recurrence_months,
      reminder_days = coalesce(p_reminder_days, 30),
      notes = nullif(btrim(p_notes), ''),
      family_member_id = p_family_member_id,
      status = p_status,
      start_time = p_start_time,
      end_time = p_end_time
  where id = p_deadline_id
    and owner_account_id = public.require_current_account()
  returning * into v;

  if not found then raise exception 'permission denied'; end if;
  return to_jsonb(v);
end;
$$;

create or replace function public.create_deadline_for_item(
  p_item_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_deadline_kind text default null,
  p_start_time time default null,
  p_end_time time default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_current_account();
  v_deadline_id uuid;
begin
  perform public.assert_my_deadline_item(p_item_id);
  if p_deadline_kind is not null and p_deadline_kind not in (
    'vehicle_insurance', 'vehicle_tax', 'vehicle_inspection', 'vehicle_service',
    'home_heating', 'home_insurance', 'home_taxes', 'home_waste'
  ) then
    raise exception 'deadline kind unavailable';
  end if;
  if p_deadline_kind is not null and not exists (
    select 1 from public.deadline_items di
    where di.id = p_item_id
      and di.owner_account_id = v_account_id
      and ((p_deadline_kind like 'vehicle_%' and di.category = 'vehicle') or (p_deadline_kind like 'home_%' and di.category = 'home'))
  ) then
    raise exception 'deadline kind requires an owned item of the matching category';
  end if;

  insert into public.deadlines(
    owner_account_id, deadline_item_id, deadline_kind, title, category,
    first_due_on, recurrence_months, reminder_days, notes, start_time, end_time
  ) values (
    v_account_id, p_item_id, p_deadline_kind, nullif(btrim(p_title), ''),
    nullif(btrim(p_category), ''), p_first_due_on, p_recurrence_months,
    coalesce(p_reminder_days, 30), nullif(btrim(p_notes), ''), p_start_time, p_end_time
  ) returning id into v_deadline_id;

  return v_deadline_id;
end;
$$;

create or replace function public.update_my_deadline_with_item(
  p_deadline_id uuid,
  p_title text,
  p_category text,
  p_first_due_on date,
  p_recurrence_months smallint default null,
  p_reminder_days smallint default 30,
  p_notes text default null,
  p_deadline_item_id uuid default null,
  p_start_time time default null,
  p_end_time time default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_current_account();
  v_deadline public.deadlines%rowtype;
begin
  select d.* into v_deadline
  from public.deadlines d
  where d.id = p_deadline_id and d.owner_account_id = v_account_id;
  if not found then raise exception 'deadline unavailable'; end if;

  perform public.update_deadline(
    p_deadline_id, p_title, p_category, p_first_due_on, p_recurrence_months,
    p_reminder_days, p_notes, v_deadline.family_member_id, v_deadline.status,
    p_start_time, p_end_time
  );
  return public.set_my_deadline_item(p_deadline_id, p_deadline_item_id);
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
  p_notes text default null,
  p_start_time time default null,
  p_end_time time default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
  v_deadline public.deadlines%rowtype;
begin
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;

  update public.deadlines d
  set title = nullif(btrim(p_title), ''),
      category = nullif(btrim(p_category), ''),
      first_due_on = p_first_due_on,
      recurrence_months = p_recurrence_months,
      reminder_days = coalesce(p_reminder_days, 30),
      notes = nullif(btrim(p_notes), ''),
      start_time = p_start_time,
      end_time = p_end_time
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
  returning d.* into v_deadline;

  if not found then raise exception 'deadline unavailable'; end if;
  return to_jsonb(v_deadline);
end;
$$;

create or replace function public.get_calendar_occurrences(
  p_from timestamptz,
  p_to timestamptz
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
      'due_on',o.occurrence_on,'occurs_on',o.occurrence_on,
      'all_day',d.start_time is null,
      'starts_at',case when d.start_time is null then null else o.occurrence_on::date + d.start_time end,
      'ends_at',case when d.end_time is null then null else o.occurrence_on::date + d.end_time end,
      'is_completed',c.deadline_id is not null,
      'family_member_id',fm.id,
      'family_member_name',nullif(btrim(concat_ws(' ',fm.first_name,fm.last_name)),''),
      'family_member_type',fm.member_type,
      'family_member_avatar_path',fm.avatar_path,
      'deadline_item_id',di.id,
      'deadline_item_name',di.name,
      'deadline_item_category',di.category,
      'deadline_item_type',di.item_type,
      'deadline_item_image_path',di.image_path,
      'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,
      'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),'')
    )
    from calendar_accounts s
    left join public.profiles p on p.account_id = s.account_id
    join public.deadlines d on d.owner_account_id = s.account_id and d.status = 'active'
    left join public.family_members fm on fm.id = d.family_member_id
    left join public.deadline_items di on di.id = d.deadline_item_id and di.owner_account_id = d.owner_account_id
    cross join lateral generate_series(
      d.first_due_on, least(coalesce(d.terminated_on,v_to_date),v_to_date),
      make_interval(months => coalesce(d.recurrence_months,1200))
    ) o(occurrence_on)
    left join public.deadline_occurrence_completions c
      on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on
    where o.occurrence_on between p_from::date and v_to_date;
end;
$$;

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
  v_owner_account_id uuid;
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_from is null or p_to is null or p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  perform public.assert_manage_owned_family_member(p_member_id);
  select f.owner_account_id into v_owner_account_id
  from public.family_members fm join public.families f on f.id = fm.family_id
  where fm.id = p_member_id;

  return query
  select jsonb_build_object(
    'kind', 'deadline', 'deadline_id', d.id, 'title', d.title,
    'due_on', o.occurrence_on, 'occurs_on', o.occurrence_on,
    'all_day', d.start_time is null,
    'starts_at', case when d.start_time is null then null else o.occurrence_on::date + d.start_time end,
    'ends_at', case when d.end_time is null then null else o.occurrence_on::date + d.end_time end,
    'is_completed', c.deadline_id is not null, 'family_member_id', fm.id,
    'family_member_name', nullif(btrim(concat_ws(' ', fm.first_name, fm.last_name)), ''),
    'family_member_type', fm.member_type, 'family_member_avatar_path', fm.avatar_path,
    'calendar_owner_account_id', v_owner_account_id, 'calendar_is_shared', false
  )
  from public.deadlines d
  join public.family_members fm on fm.id = d.family_member_id
  cross join lateral generate_series(
    d.first_due_on, least(coalesce(d.terminated_on, v_to_date), v_to_date),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) o(occurrence_on)
  left join public.deadline_occurrence_completions c
    on c.deadline_id = d.id and c.occurrence_on = o.occurrence_on
  where d.owner_account_id = v_owner_account_id
    and d.family_member_id = p_member_id
    and d.status = 'active'
    and o.occurrence_on between p_from::date and v_to_date;
end;
$$;

alter function public.create_deadline(text,text,date,smallint,smallint,text,uuid,time,time) owner to postgres;
alter function public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text,time,time) owner to postgres;
alter function public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text,time,time) owner to postgres;
alter function public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid,time,time) owner to postgres;
alter function public.update_my_managed_deadline(uuid,uuid,text,text,date,smallint,smallint,text,time,time) owner to postgres;
alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;
alter function public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz) owner to postgres;

revoke all on function public.create_deadline(text,text,date,smallint,smallint,text,uuid,time,time), public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text,time,time), public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text,time,time), public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid,time,time), public.update_my_managed_deadline(uuid,uuid,text,text,date,smallint,smallint,text,time,time), public.get_calendar_occurrences(timestamptz,timestamptz), public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz) from public, anon;
grant execute on function public.create_deadline(text,text,date,smallint,smallint,text,uuid,time,time), public.update_deadline(uuid,text,text,date,smallint,smallint,text,uuid,text,time,time), public.create_deadline_for_item(uuid,text,text,date,smallint,smallint,text,text,time,time), public.update_my_deadline_with_item(uuid,text,text,date,smallint,smallint,text,uuid,time,time), public.update_my_managed_deadline(uuid,uuid,text,text,date,smallint,smallint,text,time,time), public.get_calendar_occurrences(timestamptz,timestamptz), public.get_my_managed_family_member_calendar(uuid,timestamptz,timestamptz) to authenticated;

commit;
