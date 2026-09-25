-- FamilArea — Family Calendar Sharing V2.
-- Replaces the V1 event-by-event model. This patch intentionally converts
-- only the known Loris test account's legacy personal events; it is not a
-- general legacy-event opt-in rule.

begin;

do $$
begin
  if exists (
    select 1
    from public.event_family_shares efs
    join public.events e on e.id = efs.event_id
    group by e.owner_account_id, efs.family_id
    having count(distinct efs.sharing_enabled) > 1
  ) then
    raise exception 'cannot migrate event_family_shares: conflicting enabled states for an owner/family pair';
  end if;

  if exists (
    select 1
    from public.event_family_shares efs
    join public.events e on e.id = efs.event_id
    left join public.accounts a on a.id = e.owner_account_id
    where efs.shared_by_account_id <> e.owner_account_id
       or e.area_id is not null
       or e.owner_account_id is null
       or a.account_type <> 'personal'
       or not exists (
         select 1
         from public.families f
         where f.id = efs.family_id
           and (
             f.owner_account_id = e.owner_account_id
             or exists (
               select 1
               from public.family_access fa
               join public.profiles p on p.id = fa.profile_id
               where fa.family_id = f.id and p.account_id = e.owner_account_id
             )
           )
       )
  ) then
    raise exception 'cannot migrate invalid event_family_shares row';
  end if;
end $$;

create table public.family_calendar_shares (
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  sharing_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (owner_account_id, family_id)
);

create index family_calendar_shares_active_family_idx
  on public.family_calendar_shares (family_id, owner_account_id)
  where sharing_enabled;

alter table public.family_calendar_shares enable row level security;
revoke all on public.family_calendar_shares from public, anon, authenticated;

alter table public.events add column family_visibility text;
alter table public.events add constraint events_family_visibility_personal_check check (
  family_visibility is null
  or (family_visibility in ('family', 'private') and owner_account_id is not null and area_id is null)
);

-- Generic V1 conversion: only valid, conflict-free configurations are migrated.
insert into public.family_calendar_shares (owner_account_id, family_id, sharing_enabled, created_at, updated_at)
select e.owner_account_id, efs.family_id, bool_and(efs.sharing_enabled), min(efs.created_at), max(efs.updated_at)
from public.event_family_shares efs
join public.events e on e.id = efs.event_id
group by e.owner_account_id, efs.family_id
on conflict (owner_account_id, family_id) do update
set sharing_enabled = excluded.sharing_enabled,
    updated_at = greatest(public.family_calendar_shares.updated_at, excluded.updated_at);

update public.events e
set family_visibility = 'family'
from public.event_family_shares efs
where e.id = efs.event_id;

-- Explicit test-environment choice. It does not establish a general legacy default.
update public.events
set family_visibility = 'family'
where owner_account_id = 'e8c5359a-a687-4a67-b56b-2c5ec9e2b607'
  and area_id is null;

create or replace function public.get_my_family_calendar_shares()
returns table(
  family_id uuid,
  family_name text,
  sharing_configured boolean,
  sharing_enabled boolean
)
language sql stable security definer set search_path=public,pg_temp as $$
  with caller as (
    select public.require_personal_account() as account_id
  )
  select f.id, f.name, (fcs.owner_account_id is not null), coalesce(fcs.sharing_enabled, false)
  from public.families f
  cross join caller c
  left join public.family_calendar_shares fcs
    on fcs.family_id = f.id and fcs.owner_account_id = c.account_id
  where f.owner_account_id = c.account_id
     or exists (
       select 1
       from public.family_access fa
       join public.profiles p on p.id = fa.profile_id
       where fa.family_id = f.id and p.account_id = c.account_id
     )
  order by f.name, f.id
$$;

create or replace function public.set_my_family_calendar_share(
  p_family_id uuid,
  p_sharing_enabled boolean
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_account uuid := public.require_personal_account();
  v_result jsonb;
begin
  if not public.can_access_family(p_family_id) then
    raise exception 'family unavailable';
  end if;

  insert into public.family_calendar_shares (owner_account_id, family_id, sharing_enabled)
  values (v_account, p_family_id, coalesce(p_sharing_enabled, false))
  on conflict (owner_account_id, family_id) do update
  set sharing_enabled = excluded.sharing_enabled,
      updated_at = now()
  returning jsonb_build_object(
    'owner_account_id', owner_account_id,
    'family_id', family_id,
    'sharing_enabled', sharing_enabled,
    'updated_at', updated_at
  ) into v_result;

  return v_result;
end $$;

create or replace function public.event_shared_by_display_name(p_event public.events)
returns text
language sql stable security definer set search_path=public,pg_temp as $$
  select nullif(btrim(p.first_name), '')
  from public.profiles p
  where p.account_id = p_event.owner_account_id
  limit 1
$$;

create or replace function public.event_visibility_source(p_event_id uuid)
returns text
language sql stable security definer set search_path=public,pg_temp as $$
  select case
    when e.owner_account_id = public.current_account_id() then 'owner'
    when e.area_id is not null and (public.is_area_owner(e.area_id) or public.is_area_member(e.area_id)) then 'area'
    when exists (
      select 1
      from public.event_participants ep
      join public.profiles p on p.id = ep.profile_id
      where ep.event_id = e.id
        and ep.status = 'active'
        and p.account_id = public.current_account_id()
    ) then 'participant'
    when e.owner_account_id is not null
      and e.area_id is null
      and e.family_visibility = 'family'
      and exists (
        select 1
        from public.family_calendar_shares fcs
        join public.accounts owner_account on owner_account.id = fcs.owner_account_id
        where fcs.owner_account_id = e.owner_account_id
          and fcs.sharing_enabled
          and owner_account.account_type = 'personal'
          and public.can_access_family(fcs.family_id)
      ) then 'family'
    else null
  end
  from public.events e
  where e.id = p_event_id
$$;

create or replace function public.event_view_payload(p_event public.events, p_visibility_source text)
returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select case when p_visibility_source = 'family' then
    jsonb_strip_nulls(jsonb_build_object(
      'id', p_event.id,
      'title', p_event.title,
      'starts_at', p_event.starts_at,
      'ends_at', p_event.ends_at,
      'is_all_day', p_event.is_all_day,
      'location', p_event.location,
      'status', p_event.status,
      'recurrence_frequency', p_event.recurrence_frequency,
      'recurrence_until', p_event.recurrence_until,
      'recurrence_timezone', p_event.recurrence_timezone,
      'visibility_source', 'family',
      'can_manage', false,
      'shared_by_display_name', public.event_shared_by_display_name(p_event)
    ))
  else
    to_jsonb(p_event) || jsonb_build_object(
      'visibility_source', p_visibility_source,
      'can_manage', p_visibility_source = 'owner'
        or (p_visibility_source = 'area' and public.can_manage_area(p_event.area_id))
    )
  end
$$;

drop function public.create_event(text, timestamptz, timestamptz, text, uuid, boolean, text, jsonb);
create function public.create_event(
  p_title text,
  p_starts_at timestamptz,
  p_ends_at timestamptz default null,
  p_description text default null,
  p_area_id uuid default null,
  p_is_all_day boolean default false,
  p_location text default null,
  p_recurrence jsonb default '{}'::jsonb,
  p_family_visibility text default null
)
returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_owner uuid;
  v_id uuid;
  v_timezone text := nullif(btrim(coalesce(p_recurrence->>'timezone', '')), '');
  v_visibility text;
begin
  if p_area_id is null then
    v_owner := public.require_current_account();
    if p_family_visibility is not null and p_family_visibility not in ('family', 'private') then
      raise exception 'invalid family visibility';
    end if;
    if p_family_visibility = 'family' and not exists (
      select 1 from public.accounts a where a.id = v_owner and a.account_type = 'personal'
    ) then
      raise exception 'only personal events may use family visibility';
    end if;
    v_visibility := p_family_visibility;
  else
    perform public.require_area_manage(p_area_id);
    if p_family_visibility = 'family' then
      raise exception 'area events cannot use family visibility';
    end if;
    if p_family_visibility is not null and p_family_visibility <> 'private' then
      raise exception 'invalid family visibility';
    end if;
    v_visibility := null;
  end if;
  if nullif(p_recurrence->>'frequency', '') is not null then
    perform 1 from pg_timezone_names where name = v_timezone;
    if v_timezone is null or not found then raise exception 'invalid recurrence timezone'; end if;
  end if;
  insert into public.events (
    owner_account_id, area_id, title, description, starts_at, ends_at, is_all_day, location,
    recurrence_frequency, recurrence_until, recurrence_timezone, created_by_account_id, family_visibility
  ) values (
    v_owner, p_area_id, nullif(btrim(p_title), ''), nullif(btrim(p_description), ''), p_starts_at, p_ends_at,
    coalesce(p_is_all_day, false), nullif(btrim(p_location), ''), nullif(p_recurrence->>'frequency', ''),
    nullif(p_recurrence->>'until', '')::date, v_timezone, public.require_current_account(), v_visibility
  ) returning id into v_id;
  return v_id;
end $$;

drop function public.update_event(uuid, text, timestamptz, timestamptz, text, boolean, text, jsonb);
create function public.update_event(
  p_event_id uuid,
  p_title text,
  p_starts_at timestamptz,
  p_ends_at timestamptz default null,
  p_description text default null,
  p_is_all_day boolean default false,
  p_location text default null,
  p_recurrence jsonb default '{}'::jsonb,
  p_family_visibility text default null
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v public.events%rowtype;
  v_timezone text := nullif(btrim(coalesce(p_recurrence->>'timezone', '')), '');
  v_visibility text;
begin
  select * into v from public.events where id = p_event_id;
  if not found
    or (v.owner_account_id is not null and v.owner_account_id <> public.require_current_account())
    or (v.area_id is not null and not public.can_manage_area(v.area_id)) then
    raise exception 'permission denied';
  end if;
  if p_family_visibility is not null and p_family_visibility not in ('family', 'private') then
    raise exception 'invalid family visibility';
  end if;
  if v.area_id is not null then
    if p_family_visibility = 'family' then raise exception 'area events cannot use family visibility'; end if;
    v_visibility := null;
  else
    v_visibility := coalesce(p_family_visibility, v.family_visibility);
    if v_visibility = 'family' and not exists (
      select 1 from public.accounts a where a.id = v.owner_account_id and a.account_type = 'personal'
    ) then
      raise exception 'only personal events may use family visibility';
    end if;
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
      family_visibility = v_visibility
  where id = p_event_id
  returning * into v;
  return to_jsonb(v);
end $$;

create or replace function public.can_view_event(p_event_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select public.event_visibility_source(p_event_id) is not null
$$;

create or replace function public.get_visible_events()
returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select public.event_view_payload(e, s.visibility_source)
  from public.events e
  cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s
  where s.visibility_source is not null
  order by e.starts_at
$$;

create or replace function public.get_event(p_event_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_event public.events%rowtype;
  v_source text;
begin
  select e.* into v_event from public.events e where e.id = p_event_id;
  if not found then raise exception 'permission denied'; end if;
  v_source := public.event_visibility_source(p_event_id);
  if v_source is null then raise exception 'permission denied'; end if;
  return public.event_view_payload(v_event, v_source);
end $$;

create or replace function public.get_calendar_occurrences(p_from timestamptz, p_to timestamptz)
returns setof jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_account uuid := public.require_current_account();
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  return query
    select jsonb_build_object('kind','activity','id',a.id,'activity_id',a.id,'title',a.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',a.is_all_day,'area_id',a.area_id,'status',a.status)
    from public.activities a
    cross join lateral public.expand_recurrence_occurrences(coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone,p_from,p_to) o
    where (a.owner_account_id=v_account or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))) and a.status<>'cancelled'
    union all
    select jsonb_strip_nulls(jsonb_build_object('kind','event','id',e.id,'event_id',e.id,'title',e.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',e.is_all_day,
      'area_id',e.area_id,'status',e.status,'visibility_source',s.visibility_source,
      'shared_by_display_name',case when s.visibility_source='family' then public.event_shared_by_display_name(e) end))
    from public.events e
    cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s
    cross join lateral public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,null,null,e.recurrence_until,e.recurrence_timezone,p_from,p_to) o
    where s.visibility_source is not null and e.status<>'cancelled'
    union all
    select jsonb_build_object('kind','deadline','deadline_id',x->>'deadline_id','title',x->>'title','due_on',x->>'occurrence_on','occurs_on',x->>'occurrence_on','all_day',true,'is_completed',coalesce((x->>'completed')::boolean,false))
    from public.get_deadline_occurrences(p_from::date,(p_to-interval '1 microsecond')::date) x;
end $$;

create or replace function public.get_dashboard(p_from timestamptz default now(), p_to timestamptz default (now()+interval '30 days'))
returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  v_account uuid := public.require_current_account();
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  return jsonb_build_object(
    'activities',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('kind','activity','activity_id',a.id,'occurrence_starts_at',o.occurrence_starts_at,'occurrence_ends_at',o.occurrence_ends_at) order by o.occurrence_starts_at) from public.activities a cross join lateral public.expand_recurrence_occurrences(coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone,p_from,p_to) o where (a.owner_account_id=v_account or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))) and a.status<>'cancelled'),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(public.event_view_payload(e,s.visibility_source)||jsonb_build_object('kind','event','event_id',e.id,'occurrence_starts_at',o.occurrence_starts_at,'occurrence_ends_at',o.occurrence_ends_at) order by o.occurrence_starts_at) from public.events e cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s cross join lateral public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,null,null,e.recurrence_until,e.recurrence_timezone,p_from,p_to) o where s.visibility_source is not null and e.status<>'cancelled'),'[]'::jsonb),
    'deadlines',coalesce((select jsonb_agg(x) from public.get_deadline_occurrences(p_from::date,(p_to-interval '1 microsecond')::date) x),'[]'::jsonb),
    'todos',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('kind','activity','activity_id',a.id) order by a.created_at) from public.activities a where (a.owner_account_id=v_account or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))) and a.status='open' and a.starts_at is null and a.due_at is null),'[]'::jsonb)
  );
end $$;

drop function public.get_event_family_shares(uuid);
drop function public.set_event_family_share(uuid, uuid, boolean);
drop table public.event_family_shares;

alter function public.get_my_family_calendar_shares() owner to postgres;
alter function public.set_my_family_calendar_share(uuid, boolean) owner to postgres;
alter function public.event_shared_by_display_name(public.events) owner to postgres;
alter function public.event_visibility_source(uuid) owner to postgres;
alter function public.event_view_payload(public.events, text) owner to postgres;
alter function public.create_event(text, timestamptz, timestamptz, text, uuid, boolean, text, jsonb, text) owner to postgres;
alter function public.update_event(uuid, text, timestamptz, timestamptz, text, boolean, text, jsonb, text) owner to postgres;
alter function public.can_view_event(uuid) owner to postgres;
alter function public.get_visible_events() owner to postgres;
alter function public.get_event(uuid) owner to postgres;
alter function public.get_calendar_occurrences(timestamptz, timestamptz) owner to postgres;
alter function public.get_dashboard(timestamptz, timestamptz) owner to postgres;

revoke all on function public.get_my_family_calendar_shares(), public.set_my_family_calendar_share(uuid, boolean) from public, anon;
grant execute on function public.get_my_family_calendar_shares(), public.set_my_family_calendar_share(uuid, boolean) to authenticated;
revoke all on function public.event_shared_by_display_name(public.events), public.event_visibility_source(uuid), public.event_view_payload(public.events, text) from public, anon, authenticated;
revoke all on function public.create_event(text, timestamptz, timestamptz, text, uuid, boolean, text, jsonb, text), public.update_event(uuid, text, timestamptz, timestamptz, text, boolean, text, jsonb, text) from public, anon;
grant execute on function public.create_event(text, timestamptz, timestamptz, text, uuid, boolean, text, jsonb, text), public.update_event(uuid, text, timestamptz, timestamptz, text, boolean, text, jsonb, text) to authenticated;

commit;
