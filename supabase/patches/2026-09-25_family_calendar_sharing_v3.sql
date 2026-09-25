-- FamilArea — Family Calendar Sharing V3.
-- ATTIVA is a directional permission; VISUALIZZA is a persisted viewer-only filter.

begin;

create table public.family_calendar_share_permissions (
  owner_account_id uuid not null references public.accounts(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  recipient_account_id uuid not null references public.accounts(id) on delete cascade,
  sharing_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (owner_account_id, family_id, recipient_account_id),
  check (owner_account_id <> recipient_account_id)
);

create index family_calendar_share_permissions_recipient_idx
  on public.family_calendar_share_permissions (recipient_account_id, family_id, owner_account_id)
  where sharing_enabled;

create table public.calendar_view_preferences (
  id uuid primary key default gen_random_uuid(),
  viewer_account_id uuid not null references public.accounts(id) on delete cascade,
  source_account_id uuid not null references public.accounts(id) on delete cascade,
  family_id uuid references public.families(id) on delete cascade,
  visible boolean not null default true,
  updated_at timestamptz not null default now(),
  check (
    (viewer_account_id = source_account_id and family_id is null)
    or (viewer_account_id <> source_account_id and family_id is not null)
  )
);

-- PostgreSQL UNIQUE treats NULLs as distinct: partial unique indexes make the self row unique.
create unique index calendar_view_preferences_self_unique
  on public.calendar_view_preferences (viewer_account_id, source_account_id)
  where family_id is null;
create unique index calendar_view_preferences_family_source_unique
  on public.calendar_view_preferences (viewer_account_id, family_id, source_account_id)
  where family_id is not null;

alter table public.family_calendar_share_permissions enable row level security;
alter table public.calendar_view_preferences enable row level security;
revoke all on public.family_calendar_share_permissions, public.calendar_view_preferences from public, anon, authenticated;

create or replace function public.is_confirmed_family_account_member(p_family_id uuid, p_account_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select exists (
    select 1 from public.families f
    where f.id = p_family_id and (
      f.owner_account_id = p_account_id
      or exists (
        select 1 from public.family_access fa
        join public.profiles p on p.id = fa.profile_id
        where fa.family_id = f.id and p.account_id = p_account_id
      )
    )
  )
$$;

create or replace function public.has_family_calendar_share_permission(
  p_owner_account_id uuid,
  p_recipient_account_id uuid,
  p_family_id uuid default null
)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select p_owner_account_id <> p_recipient_account_id
    and exists (
      select 1
      from public.family_calendar_share_permissions p
      join public.accounts owner_account on owner_account.id = p.owner_account_id and owner_account.account_type = 'personal'
      join public.accounts recipient_account on recipient_account.id = p.recipient_account_id and recipient_account.account_type = 'personal'
      where p.owner_account_id = p_owner_account_id
        and p.recipient_account_id = p_recipient_account_id
        and p.sharing_enabled
        and (p_family_id is null or p.family_id = p_family_id)
        and public.is_confirmed_family_account_member(p.family_id, p.owner_account_id)
        and public.is_confirmed_family_account_member(p.family_id, p.recipient_account_id)
    )
$$;

-- V2 meant "everyone currently confirmed in this Family". Future members receive no row.
insert into public.family_calendar_share_permissions (
  owner_account_id, family_id, recipient_account_id, sharing_enabled, created_at, updated_at
)
select fcs.owner_account_id, fcs.family_id, roster.account_id, true, fcs.created_at, fcs.updated_at
from public.family_calendar_shares fcs
join public.accounts owner_account on owner_account.id = fcs.owner_account_id and owner_account.account_type = 'personal'
cross join lateral (
  select f.owner_account_id as account_id
  from public.families f where f.id = fcs.family_id
  union
  select p.account_id
  from public.family_access fa
  join public.profiles p on p.id = fa.profile_id
  join public.accounts a on a.id = p.account_id and a.account_type = 'personal'
  where fa.family_id = fcs.family_id
) roster
where fcs.sharing_enabled
  and roster.account_id <> fcs.owner_account_id
  and public.is_confirmed_family_account_member(fcs.family_id, fcs.owner_account_id)
  and public.is_confirmed_family_account_member(fcs.family_id, roster.account_id)
on conflict (owner_account_id, family_id, recipient_account_id) do update
set sharing_enabled = excluded.sharing_enabled,
    updated_at = greatest(public.family_calendar_share_permissions.updated_at, excluded.updated_at);

create or replace function public.get_my_family_calendar_controls()
returns table(
  family_id uuid,
  family_name text,
  member_account_id uuid,
  display_name text,
  avatar_path text,
  relationship text,
  is_self boolean,
  can_view_source boolean,
  view_enabled boolean,
  share_enabled boolean
)
language sql stable security definer set search_path=public,pg_temp as $$
  with caller as (select public.require_personal_account() as account_id),
  accessible_families as (
    select f.id, f.name
    from public.families f cross join caller c
    where public.is_confirmed_family_account_member(f.id, c.account_id)
  ), roster as (
    select af.id as family_id, af.name as family_name, f.owner_account_id as account_id
    from accessible_families af join public.families f on f.id = af.id
    union
    select af.id, af.name, p.account_id
    from accessible_families af
    join public.family_access fa on fa.family_id = af.id
    join public.profiles p on p.id = fa.profile_id
    join public.accounts a on a.id = p.account_id and a.account_type = 'personal'
  ), rows as (
    select r.*, p.id as profile_id, p.first_name, p.last_name, p.avatar_path,
      (r.account_id = c.account_id) as is_self,
      public.has_family_calendar_share_permission(r.account_id, c.account_id, r.family_id) as can_view_source,
      public.has_family_calendar_share_permission(c.account_id, r.account_id, r.family_id) as share_enabled,
      (
        select fm.relationship from public.family_members fm
        where fm.family_id = r.family_id and fm.linked_profile_id = p.id
        limit 1
      ) as relationship
    from roster r
    cross join caller c
    join public.profiles p on p.account_id = r.account_id
  )
  select r.family_id, r.family_name, r.account_id,
    nullif(btrim(concat_ws(' ', r.first_name, r.last_name)), '') as display_name,
    r.avatar_path, r.relationship, r.is_self,
    case when r.is_self then true else r.can_view_source end,
    case when r.is_self then coalesce((
      select vp.visible from public.calendar_view_preferences vp cross join caller c
      where vp.viewer_account_id = c.account_id and vp.source_account_id = c.account_id and vp.family_id is null
    ), true) when r.can_view_source then coalesce((
      select vp.visible from public.calendar_view_preferences vp cross join caller c
      where vp.viewer_account_id = c.account_id and vp.source_account_id = r.account_id and vp.family_id = r.family_id
    ), true) else false end,
    case when r.is_self then false else r.share_enabled end
  from rows r
  order by r.family_name, r.is_self desc, lower(coalesce(r.first_name, '')), lower(coalesce(r.last_name, '')), r.account_id
$$;

create or replace function public.set_my_family_calendar_share_permission(
  p_family_id uuid,
  p_recipient_account_id uuid,
  p_sharing_enabled boolean
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_owner uuid := public.require_personal_account(); v_result jsonb;
begin
  if p_recipient_account_id is null or p_recipient_account_id = v_owner
    or not public.is_confirmed_family_account_member(p_family_id, v_owner)
    or not public.is_confirmed_family_account_member(p_family_id, p_recipient_account_id)
    or not exists (select 1 from public.accounts where id = p_recipient_account_id and account_type = 'personal') then
    raise exception 'family member unavailable';
  end if;
  insert into public.family_calendar_share_permissions(owner_account_id, family_id, recipient_account_id, sharing_enabled)
  values(v_owner, p_family_id, p_recipient_account_id, coalesce(p_sharing_enabled, false))
  on conflict (owner_account_id, family_id, recipient_account_id) do update
  set sharing_enabled = excluded.sharing_enabled, updated_at = now()
  returning jsonb_build_object('owner_account_id', owner_account_id, 'family_id', family_id,
    'recipient_account_id', recipient_account_id, 'sharing_enabled', sharing_enabled, 'updated_at', updated_at) into v_result;
  return v_result;
end $$;

create or replace function public.set_my_calendar_view_preference(
  p_source_account_id uuid,
  p_family_id uuid,
  p_visible boolean
)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_viewer uuid := public.require_personal_account(); v_result jsonb;
begin
  if p_source_account_id = v_viewer then
    if p_family_id is not null then raise exception 'self preference cannot have a family'; end if;
    update public.calendar_view_preferences set visible = coalesce(p_visible, true), updated_at = now()
    where viewer_account_id = v_viewer and source_account_id = v_viewer and family_id is null
    returning jsonb_build_object('source_account_id', source_account_id, 'family_id', family_id, 'visible', visible, 'updated_at', updated_at) into v_result;
    if v_result is null then
      insert into public.calendar_view_preferences(viewer_account_id, source_account_id, family_id, visible)
      values(v_viewer, v_viewer, null, coalesce(p_visible, true))
      returning jsonb_build_object('source_account_id', source_account_id, 'family_id', family_id, 'visible', visible, 'updated_at', updated_at) into v_result;
    end if;
  else
    if p_family_id is null or not public.has_family_calendar_share_permission(p_source_account_id, v_viewer, p_family_id) then
      raise exception 'calendar source unavailable';
    end if;
    update public.calendar_view_preferences set visible = coalesce(p_visible, true), updated_at = now()
    where viewer_account_id = v_viewer and source_account_id = p_source_account_id and family_id = p_family_id
    returning jsonb_build_object('source_account_id', source_account_id, 'family_id', family_id, 'visible', visible, 'updated_at', updated_at) into v_result;
    if v_result is null then
      insert into public.calendar_view_preferences(viewer_account_id, source_account_id, family_id, visible)
      values(v_viewer, p_source_account_id, p_family_id, coalesce(p_visible, true))
      returning jsonb_build_object('source_account_id', source_account_id, 'family_id', family_id, 'visible', visible, 'updated_at', updated_at) into v_result;
    end if;
  end if;
  return v_result;
end $$;

create or replace function public.event_visibility_source(p_event_id uuid)
returns text language sql stable security definer set search_path=public,pg_temp as $$
  select case
    when e.owner_account_id = public.current_account_id() then 'owner'
    when e.area_id is not null and (public.is_area_owner(e.area_id) or public.is_area_member(e.area_id)) then 'area'
    when exists (select 1 from public.event_participants ep join public.profiles p on p.id = ep.profile_id
      where ep.event_id = e.id and ep.status = 'active' and p.account_id = public.current_account_id()) then 'participant'
    when e.owner_account_id is not null and e.area_id is null and e.family_visibility = 'family'
      and public.has_family_calendar_share_permission(e.owner_account_id, public.current_account_id()) then 'family'
    else null end
  from public.events e where e.id = p_event_id
$$;

create or replace function public.calendar_event_source_visible(p_event public.events, p_visibility_source text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select case
    when p_visibility_source = 'owner' and p_event.area_id is null and p_event.owner_account_id = public.current_account_id()
      then coalesce((select vp.visible from public.calendar_view_preferences vp
        where vp.viewer_account_id = public.current_account_id() and vp.source_account_id = public.current_account_id() and vp.family_id is null), true)
    when p_visibility_source = 'family' then exists (
      select 1 from public.family_calendar_share_permissions p
      where p.owner_account_id = p_event.owner_account_id and p.recipient_account_id = public.current_account_id()
        and p.sharing_enabled and public.is_confirmed_family_account_member(p.family_id, p.owner_account_id)
        and public.is_confirmed_family_account_member(p.family_id, p.recipient_account_id)
        and coalesce((select vp.visible from public.calendar_view_preferences vp
          where vp.viewer_account_id = public.current_account_id() and vp.source_account_id = p.owner_account_id and vp.family_id = p.family_id), true)
    )
    else true end
$$;

create or replace function public.can_view_event(p_event_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select public.event_visibility_source(p_event_id) is not null
$$;

create or replace function public.get_visible_events()
returns setof jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select public.event_view_payload(e, s.visibility_source)
  from public.events e cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s
  where s.visibility_source is not null and public.calendar_event_source_visible(e, s.visibility_source)
  order by e.starts_at
$$;

create or replace function public.get_calendar_occurrences(p_from timestamptz, p_to timestamptz)
returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account uuid := public.require_current_account();
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  return query
    select jsonb_build_object('kind','activity','id',a.id,'activity_id',a.id,'title',a.title,'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',a.is_all_day,'area_id',a.area_id,'status',a.status)
    from public.activities a cross join lateral public.expand_recurrence_occurrences(coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone,p_from,p_to) o
    where (a.owner_account_id=v_account or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))) and a.status<>'cancelled'
    union all
    select jsonb_strip_nulls(jsonb_build_object('kind','event','id',e.id,'event_id',e.id,'title',e.title,'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',e.is_all_day,'area_id',e.area_id,'status',e.status,'visibility_source',s.visibility_source,'shared_by_display_name',case when s.visibility_source='family' then public.event_shared_by_display_name(e) end))
    from public.events e cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s
    cross join lateral public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,null,null,e.recurrence_until,e.recurrence_timezone,p_from,p_to) o
    where s.visibility_source is not null and public.calendar_event_source_visible(e, s.visibility_source) and e.status<>'cancelled'
    union all
    select jsonb_build_object('kind','deadline','deadline_id',x->>'deadline_id','title',x->>'title','due_on',x->>'occurrence_on','occurs_on',x->>'occurrence_on','all_day',true,'is_completed',coalesce((x->>'completed')::boolean,false))
    from public.get_deadline_occurrences(p_from::date,(p_to-interval '1 microsecond')::date) x;
end $$;

create or replace function public.get_dashboard(p_from timestamptz default now(), p_to timestamptz default (now()+interval '30 days'))
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_account uuid := public.require_current_account();
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;
  return jsonb_build_object(
    'activities',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('kind','activity','activity_id',a.id,'occurrence_starts_at',o.occurrence_starts_at,'occurrence_ends_at',o.occurrence_ends_at) order by o.occurrence_starts_at) from public.activities a cross join lateral public.expand_recurrence_occurrences(coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone,p_from,p_to) o where (a.owner_account_id=v_account or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))) and a.status<>'cancelled'),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(public.event_view_payload(e,s.visibility_source)||jsonb_build_object('kind','event','event_id',e.id,'occurrence_starts_at',o.occurrence_starts_at,'occurrence_ends_at',o.occurrence_ends_at) order by o.occurrence_starts_at) from public.events e cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s cross join lateral public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,null,null,e.recurrence_until,e.recurrence_timezone,p_from,p_to) o where s.visibility_source is not null and public.calendar_event_source_visible(e,s.visibility_source) and e.status<>'cancelled'),'[]'::jsonb),
    'deadlines',coalesce((select jsonb_agg(x) from public.get_deadline_occurrences(p_from::date,(p_to-interval '1 microsecond')::date) x),'[]'::jsonb),
    'todos',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('kind','activity','activity_id',a.id) order by a.created_at) from public.activities a where (a.owner_account_id=v_account or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))) and a.status='open' and a.starts_at is null and a.due_at is null),'[]'::jsonb)
  );
end $$;

alter function public.is_confirmed_family_account_member(uuid,uuid) owner to postgres;
alter function public.has_family_calendar_share_permission(uuid,uuid,uuid) owner to postgres;
alter function public.get_my_family_calendar_controls() owner to postgres;
alter function public.set_my_family_calendar_share_permission(uuid,uuid,boolean) owner to postgres;
alter function public.set_my_calendar_view_preference(uuid,uuid,boolean) owner to postgres;
alter function public.calendar_event_source_visible(public.events,text) owner to postgres;
alter function public.event_visibility_source(uuid) owner to postgres;
alter function public.can_view_event(uuid) owner to postgres;
alter function public.get_visible_events() owner to postgres;
alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;
alter function public.get_dashboard(timestamptz,timestamptz) owner to postgres;

revoke all on function public.is_confirmed_family_account_member(uuid,uuid), public.has_family_calendar_share_permission(uuid,uuid,uuid), public.calendar_event_source_visible(public.events,text), public.event_visibility_source(uuid), public.can_view_event(uuid) from public, anon, authenticated;
revoke all on function public.get_my_family_calendar_controls(), public.set_my_family_calendar_share_permission(uuid,uuid,boolean), public.set_my_calendar_view_preference(uuid,uuid,boolean) from public, anon;
grant execute on function public.get_my_family_calendar_controls(), public.set_my_family_calendar_share_permission(uuid,uuid,boolean), public.set_my_calendar_view_preference(uuid,uuid,boolean) to authenticated;

drop function public.get_my_family_calendar_shares();
drop function public.set_my_family_calendar_share(uuid,boolean);
drop table public.family_calendar_shares;

commit;
