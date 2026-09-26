-- FamilArea — Family Calendar V4.
-- Share direct person calendars only; received calendars never cascade.

begin;

do $$
begin
  if exists (
    select 1 from public.family_calendar_share_permissions
    group by owner_account_id, recipient_account_id
    having count(distinct sharing_enabled) > 1
  ) then
    raise exception 'V4 migration blocked: conflicting ATTIVA values for an account pair';
  end if;
  if exists (
    select 1 from public.calendar_view_preferences
    group by source_account_id, viewer_account_id
    having count(distinct visible) > 1
  ) then
    raise exception 'V4 migration blocked: conflicting VISUALIZZA values for an account pair';
  end if;
end $$;

create table public.person_calendar_links (
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  viewer_account_id uuid not null references public.accounts(id) on delete cascade,
  sharing_enabled boolean not null default false,
  visible boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (owner_account_id, viewer_account_id),
  check (owner_account_id <> viewer_account_id or sharing_enabled = false)
);
create index person_calendar_links_viewer_shared_idx
  on public.person_calendar_links (viewer_account_id, owner_account_id)
  where sharing_enabled;
alter table public.person_calendar_links enable row level security;
revoke all on public.person_calendar_links from public, anon, authenticated;

with share_values as (
  select owner_account_id, recipient_account_id as viewer_account_id,
    bool_or(sharing_enabled) as sharing_enabled
  from public.family_calendar_share_permissions
  group by owner_account_id, recipient_account_id
), view_values as (
  select source_account_id as owner_account_id, viewer_account_id,
    bool_or(visible) as visible
  from public.calendar_view_preferences
  group by source_account_id, viewer_account_id
), pairs as (
  select owner_account_id, viewer_account_id from share_values
  union
  select owner_account_id, viewer_account_id from view_values
)
insert into public.person_calendar_links(owner_account_id, viewer_account_id, sharing_enabled, visible)
select p.owner_account_id, p.viewer_account_id,
  coalesce(s.sharing_enabled, false), coalesce(v.visible, true)
from pairs p
left join share_values s using (owner_account_id, viewer_account_id)
left join view_values v using (owner_account_id, viewer_account_id);

alter table public.events add column calendar_private boolean not null default false;
update public.events set calendar_private = true where family_visibility = 'private';
alter table public.events add constraint events_calendar_private_personal_check
  check (not calendar_private or (owner_account_id is not null and area_id is null));

create or replace function public.are_confirmed_family_accounts(
  p_owner_account_id uuid,
  p_viewer_account_id uuid
)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select exists (
    select 1 from public.accounts owner_account
    join public.accounts viewer_account on viewer_account.id = p_viewer_account_id
    where owner_account.id = p_owner_account_id
      and owner_account.account_type = 'personal'
      and viewer_account.account_type = 'personal'
  ) and exists (
    select 1 from public.families f
    where public.is_confirmed_family_account_member(f.id, p_owner_account_id)
      and public.is_confirmed_family_account_member(f.id, p_viewer_account_id)
  )
$$;

create or replace function public.can_view_person_calendar(
  p_owner_account_id uuid,
  p_viewer_account_id uuid
)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select p_owner_account_id <> p_viewer_account_id
    and public.are_confirmed_family_accounts(p_owner_account_id, p_viewer_account_id)
    and exists (
      select 1 from public.person_calendar_links l
      where l.owner_account_id = p_owner_account_id
        and l.viewer_account_id = p_viewer_account_id
        and l.sharing_enabled
    )
$$;

create or replace function public.get_my_family_calendar_controls()
returns table(
  family_id uuid, family_name text, member_account_id uuid, display_name text,
  avatar_path text, relationship text, is_self boolean, can_view_source boolean,
  view_enabled boolean, share_enabled boolean, calendar_capable boolean, member_type text
)
language sql stable security definer set search_path=public,pg_temp as $$
  with caller as (select public.require_personal_account() as account_id),
  accessible_families as (
    select f.id, f.name from public.families f cross join caller c
    where public.is_confirmed_family_account_member(f.id, c.account_id)
  ), confirmed_accounts as (
    select af.id as family_id, af.name as family_name, f.owner_account_id as account_id
    from accessible_families af join public.families f on f.id = af.id
    union
    select af.id, af.name, p.account_id
    from accessible_families af
    join public.family_access fa on fa.family_id = af.id
    join public.profiles p on p.id = fa.profile_id
    join public.accounts a on a.id = p.account_id and a.account_type = 'personal'
  ), account_rows as (
    select ca.family_id, ca.family_name, ca.account_id, p.id as profile_id,
      nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), '') as display_name,
      p.avatar_path, fm.relationship, (ca.account_id = c.account_id) as is_self,
      true as calendar_capable, 'person'::text as member_type,
      case when ca.account_id = c.account_id then 0 else 1 end as sort_group,
      coalesce(fm.first_name, p.first_name, '') as sort_first,
      coalesce(fm.last_name, p.last_name, '') as sort_last, fm.id as sort_member_id
    from confirmed_accounts ca cross join caller c
    join public.profiles p on p.account_id = ca.account_id
    left join lateral (
      select fm.* from public.family_members fm
      where fm.family_id = ca.family_id and fm.linked_profile_id = p.id limit 1
    ) fm on true
  ), informational_rows as (
    select af.id as family_id, af.name as family_name, null::uuid as account_id,
      null::uuid as profile_id,
      nullif(btrim(concat_ws(' ', fm.first_name, fm.last_name)), '') as display_name,
      null::text as avatar_path, fm.relationship, false as is_self,
      false as calendar_capable, fm.member_type::text as member_type,
      1 as sort_group, coalesce(fm.first_name, '') as sort_first,
      coalesce(fm.last_name, '') as sort_last, fm.id as sort_member_id
    from accessible_families af join public.family_members fm on fm.family_id = af.id
    where not exists (
      select 1 from public.family_access fa
      where fa.family_id = fm.family_id and fa.profile_id = fm.linked_profile_id
    )
  ), rows as (
    select * from account_rows union all select * from informational_rows
  )
  select r.family_id, r.family_name, r.account_id, r.display_name, r.avatar_path,
    r.relationship, r.is_self,
    case when r.calendar_capable and r.is_self then true
      when r.calendar_capable then public.can_view_person_calendar(r.account_id, c.account_id)
      else false end,
    case when r.calendar_capable and (r.is_self or public.can_view_person_calendar(r.account_id, c.account_id))
      then coalesce((
        select l.visible from public.person_calendar_links l
        where l.owner_account_id = r.account_id and l.viewer_account_id = c.account_id
      ), true)
      else false end,
    case when r.calendar_capable and not r.is_self
      then public.can_view_person_calendar(c.account_id, r.account_id)
      else false end,
    r.calendar_capable, r.member_type
  from rows r cross join caller c
  order by r.family_name, r.sort_group, lower(r.sort_first), lower(r.sort_last),
    r.sort_member_id nulls first, r.account_id nulls last
$$;

create or replace function public.set_my_calendar_share(
  p_viewer_account_id uuid,
  p_sharing_enabled boolean
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_owner uuid := public.require_personal_account(); v_result jsonb;
begin
  if p_viewer_account_id is null or p_viewer_account_id = v_owner
    or not exists (
      select 1 from public.accounts a
      where a.id = p_viewer_account_id and a.account_type = 'personal'
    ) then
    raise exception 'family member unavailable';
  end if;
  if coalesce(p_sharing_enabled, false)
    and not public.are_confirmed_family_accounts(v_owner, p_viewer_account_id) then
    raise exception 'family member unavailable';
  end if;
  insert into public.person_calendar_links(owner_account_id, viewer_account_id, sharing_enabled)
  values(v_owner, p_viewer_account_id, coalesce(p_sharing_enabled, false))
  on conflict (owner_account_id, viewer_account_id) do update
  set sharing_enabled = excluded.sharing_enabled, updated_at = now()
  returning jsonb_build_object('owner_account_id', owner_account_id,
    'viewer_account_id', viewer_account_id, 'sharing_enabled', sharing_enabled,
    'visible', visible, 'updated_at', updated_at) into v_result;
  return v_result;
end $$;

create or replace function public.set_my_calendar_view(
  p_source_account_id uuid,
  p_visible boolean
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_viewer uuid := public.require_personal_account(); v_result jsonb;
begin
  if p_source_account_id is null then raise exception 'calendar source unavailable'; end if;
  if p_source_account_id <> v_viewer
    and not public.can_view_person_calendar(p_source_account_id, v_viewer) then
    raise exception 'calendar source unavailable';
  end if;
  insert into public.person_calendar_links(owner_account_id, viewer_account_id, sharing_enabled, visible)
  values(p_source_account_id, v_viewer, false, coalesce(p_visible, true))
  on conflict (owner_account_id, viewer_account_id) do update
  set visible = excluded.visible, updated_at = now()
  returning jsonb_build_object('owner_account_id', owner_account_id,
    'viewer_account_id', viewer_account_id, 'sharing_enabled', sharing_enabled,
    'visible', visible, 'updated_at', updated_at) into v_result;
  return v_result;
end $$;

create or replace function public.event_visibility_source(p_event_id uuid)
returns text
language sql stable security definer set search_path=public,pg_temp as $$
  select case
    when e.owner_account_id = public.current_account_id() then 'owner'
    when e.area_id is not null and (public.is_area_owner(e.area_id) or public.is_area_member(e.area_id)) then 'area'
    when exists (
      select 1 from public.event_participants ep
      join public.profiles p on p.id = ep.profile_id
      where ep.event_id = e.id and ep.status = 'active'
        and p.account_id = public.current_account_id()
    ) then 'participant'
    else null
  end
  from public.events e where e.id = p_event_id
$$;

create or replace function public.event_view_payload(p_event public.events, p_visibility_source text)
returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select to_jsonb(p_event) || jsonb_build_object(
    'visibility_source', p_visibility_source,
    'can_manage', p_visibility_source = 'owner'
      or (p_visibility_source = 'area' and public.can_manage_area(p_event.area_id))
  )
$$;

create or replace function public.get_visible_events()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select public.event_view_payload(e, s.visibility_source)
  from public.events e
  cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s
  where s.visibility_source is not null and e.status <> 'cancelled'
  order by e.starts_at
$$;

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
      where (
        a.owner_account_id = v_account
        or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))
      )
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
        e.starts_at, e.ends_at, e.recurrence_frequency, null, null,
        e.recurrence_until, e.recurrence_timezone, p_from, p_to) o
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

drop function public.create_event(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,text);
drop function public.update_event(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,text);

create function public.create_event(
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
  v_timezone text := nullif(btrim(coalesce(p_recurrence->>'timezone', '')), '');
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
  if nullif(p_recurrence->>'frequency', '') is not null then
    perform 1 from pg_timezone_names where name = v_timezone;
    if v_timezone is null or not found then raise exception 'invalid recurrence timezone'; end if;
  end if;
  insert into public.events (
    owner_account_id, area_id, title, description, starts_at, ends_at, is_all_day,
    location, recurrence_frequency, recurrence_until, recurrence_timezone,
    created_by_account_id, calendar_private
  ) values (
    v_owner, p_area_id, nullif(btrim(p_title), ''), nullif(btrim(p_description), ''),
    p_starts_at, p_ends_at, coalesce(p_is_all_day, false), nullif(btrim(p_location), ''),
    nullif(p_recurrence->>'frequency', ''), nullif(p_recurrence->>'until', '')::date,
    v_timezone, public.require_current_account(), v_private
  ) returning id into v_id;
  return v_id;
end $$;

create function public.update_event(
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
  v_timezone text := nullif(btrim(coalesce(p_recurrence->>'timezone', '')), '');
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
  if nullif(p_recurrence->>'frequency', '') is not null then
    perform 1 from pg_timezone_names where name = v_timezone;
    if v_timezone is null or not found then raise exception 'invalid recurrence timezone'; end if;
  end if;
  update public.events
  set title = nullif(btrim(p_title), ''),
      description = nullif(btrim(p_description), ''),
      starts_at = p_starts_at,
      ends_at = p_ends_at,
      is_all_day = coalesce(p_is_all_day, false),
      location = nullif(btrim(p_location), ''),
      recurrence_frequency = nullif(p_recurrence->>'frequency', ''),
      recurrence_until = nullif(p_recurrence->>'until', '')::date,
      recurrence_timezone = v_timezone,
      calendar_private = v_private
  where id = p_event_id returning * into v;
  return to_jsonb(v);
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
      where coalesce((
        select l.visible from public.person_calendar_links l
        where l.owner_account_id = v_account and l.viewer_account_id = v_account
      ), true)
      union all
      select l.owner_account_id, true
      from public.person_calendar_links l
      where l.viewer_account_id = v_account
        and l.owner_account_id <> v_account
        and l.visible
        and public.can_view_person_calendar(l.owner_account_id, v_account)
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
        select 1 from public.areas ar
        where ar.id = a.area_id and (
          ar.owner_account_id = s.account_id
          or exists (
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
      and (
        e.owner_account_id = s.account_id
        or (e.area_id is not null and exists (
          select 1 from public.areas ar
          where ar.id = e.area_id and (
            ar.owner_account_id = s.account_id
            or exists (
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
        )
      )
    cross join lateral public.expand_recurrence_occurrences(
      e.starts_at,e.ends_at,e.recurrence_frequency,null,null,
      e.recurrence_until,e.recurrence_timezone,p_from,p_to
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

drop function public.set_my_family_calendar_share_permission(uuid,uuid,boolean);
drop function public.set_my_calendar_view_preference(uuid,uuid,boolean);
drop function public.calendar_event_source_visible(public.events,text);
drop function public.has_family_calendar_share_permission(uuid,uuid,uuid);
drop function public.event_shared_by_display_name(public.events);
drop function public.can_access_family(uuid);

alter table public.events drop constraint events_family_visibility_personal_check;
alter table public.events drop column family_visibility;
drop table public.calendar_view_preferences;
drop table public.family_calendar_share_permissions;

alter table public.person_calendar_links owner to postgres;
alter function public.are_confirmed_family_accounts(uuid,uuid) owner to postgres;
alter function public.can_view_person_calendar(uuid,uuid) owner to postgres;
alter function public.get_my_family_calendar_controls() owner to postgres;
alter function public.set_my_calendar_share(uuid,boolean) owner to postgres;
alter function public.set_my_calendar_view(uuid,boolean) owner to postgres;
alter function public.event_visibility_source(uuid) owner to postgres;
alter function public.event_view_payload(public.events,text) owner to postgres;
alter function public.get_visible_events() owner to postgres;
alter function public.get_dashboard(timestamptz,timestamptz) owner to postgres;
alter function public.create_event(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,boolean) owner to postgres;
alter function public.update_event(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,boolean) owner to postgres;
alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;

revoke all on function public.are_confirmed_family_accounts(uuid,uuid),
  public.can_view_person_calendar(uuid,uuid),public.event_visibility_source(uuid),
  public.event_view_payload(public.events,text),public.can_view_event(uuid) from public,anon,authenticated;
revoke all on function public.get_my_family_calendar_controls(),
  public.set_my_calendar_share(uuid,boolean),public.set_my_calendar_view(uuid,boolean),
  public.get_calendar_occurrences(timestamptz,timestamptz),
  public.get_visible_events(),public.get_dashboard(timestamptz,timestamptz),
  public.create_event(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,boolean),
  public.update_event(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,boolean)
  from public,anon;
grant execute on function public.get_my_family_calendar_controls(),
  public.set_my_calendar_share(uuid,boolean),public.set_my_calendar_view(uuid,boolean),
  public.get_calendar_occurrences(timestamptz,timestamptz),public.get_visible_events(),
  public.get_dashboard(timestamptz,timestamptz),
  public.create_event(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,boolean),
  public.update_event(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,boolean)
  to authenticated;

commit;