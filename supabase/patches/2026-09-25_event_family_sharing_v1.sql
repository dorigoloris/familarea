-- FamilArea — Family Event Sharing V1.  Visibility only; no participant or membership side effects.

create table public.event_family_shares (
  event_id uuid not null references public.events(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  shared_by_account_id uuid not null references public.accounts(id) on delete restrict,
  sharing_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (event_id, family_id)
);

create index event_family_shares_active_family_idx
  on public.event_family_shares (family_id, event_id)
  where sharing_enabled;

alter table public.event_family_shares enable row level security;
revoke all on public.event_family_shares from public, anon, authenticated;

create or replace function public.can_access_family(p_family_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists (
    select 1 from public.families f
    where f.id=p_family_id
      and exists (
        select 1 from public.accounts a
        where a.id=public.current_account_id() and a.account_type='personal'
      )
      and (
      f.owner_account_id=public.current_account_id()
      or exists (
        select 1 from public.family_access fa
        join public.profiles p on p.id=fa.profile_id
        where fa.family_id=f.id and p.account_id=public.current_account_id()
      )
    )
  )
$$;

create or replace function public.event_visibility_source(p_event_id uuid)
returns text language sql stable security definer set search_path=public,pg_temp as $$
  select case
    when e.owner_account_id=public.current_account_id() then 'owner'
    when e.area_id is not null and (public.is_area_owner(e.area_id) or public.is_area_member(e.area_id)) then 'area'
    when exists (
      select 1 from public.event_participants ep join public.profiles p on p.id=ep.profile_id
      where ep.event_id=e.id and ep.status='active' and p.account_id=public.current_account_id()
    ) then 'participant'
    when e.owner_account_id is not null and exists (
      select 1 from public.event_family_shares efs
      where efs.event_id=e.id and efs.shared_by_account_id=e.owner_account_id
        and efs.sharing_enabled and public.can_access_family(efs.family_id)
    ) then 'family'
    else null
  end
  from public.events e where e.id=p_event_id
$$;

create or replace function public.event_view_payload(p_event public.events,p_visibility_source text)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select case when p_visibility_source='family' then
    jsonb_build_object(
      'id',p_event.id,'title',p_event.title,'description',p_event.description,
      'starts_at',p_event.starts_at,'ends_at',p_event.ends_at,'is_all_day',p_event.is_all_day,
      'location',p_event.location,'status',p_event.status,
      'recurrence_frequency',p_event.recurrence_frequency,'recurrence_until',p_event.recurrence_until,
      'recurrence_timezone',p_event.recurrence_timezone,
      'visibility_source','family','can_manage',false
    )
  else
    to_jsonb(p_event) || jsonb_build_object(
      'visibility_source',p_visibility_source,
      'can_manage',p_visibility_source='owner' or (p_visibility_source='area' and public.can_manage_area(p_event.area_id))
    )
  end
$$;

create or replace function public.get_event_family_shares(p_event_id uuid)
returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account uuid:=public.require_personal_account();
begin
  if not exists(select 1 from public.events e where e.id=p_event_id and e.owner_account_id=v_account and e.area_id is null) then
    raise exception 'permission denied';
  end if;
  return query
  select jsonb_build_object('event_id',efs.event_id,'family_id',efs.family_id,'family_name',f.name,
    'sharing_enabled',efs.sharing_enabled,'shared_by_account_id',efs.shared_by_account_id,
    'created_at',efs.created_at,'updated_at',efs.updated_at)
  from public.event_family_shares efs join public.families f on f.id=efs.family_id
  where efs.event_id=p_event_id and efs.shared_by_account_id=v_account
  order by f.name;
end $$;

create or replace function public.set_event_family_share(p_event_id uuid,p_family_id uuid,p_sharing_enabled boolean)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account uuid:=public.require_personal_account(); v_result jsonb;
begin
  if not exists(select 1 from public.events e where e.id=p_event_id and e.owner_account_id=v_account and e.area_id is null) then
    raise exception 'only a personal event owner may share this event';
  end if;
  if not public.can_access_family(p_family_id) then raise exception 'family unavailable'; end if;
  insert into public.event_family_shares(event_id,family_id,shared_by_account_id,sharing_enabled)
  values(p_event_id,p_family_id,v_account,coalesce(p_sharing_enabled,false))
  on conflict(event_id,family_id) do update
    set sharing_enabled=excluded.sharing_enabled,shared_by_account_id=excluded.shared_by_account_id,updated_at=now()
  returning jsonb_build_object('event_id',event_id,'family_id',family_id,'sharing_enabled',sharing_enabled,'updated_at',updated_at) into v_result;
  return v_result;
end $$;

create or replace function public.can_view_event(p_event_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select public.event_visibility_source(p_event_id) is not null
$$;

create or replace function public.get_visible_events()
returns setof jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select public.event_view_payload(e,s.visibility_source)
  from public.events e
  cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s
  where s.visibility_source is not null
  order by e.starts_at
$$;

create or replace function public.get_event(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_event public.events%rowtype; v_source text;
begin
  select e.* into v_event from public.events e where e.id=p_event_id;
  if not found then raise exception 'permission denied'; end if;
  v_source:=public.event_visibility_source(p_event_id);
  if v_source is null then raise exception 'permission denied'; end if;
  return public.event_view_payload(v_event,v_source);
end $$;

create or replace function public.get_calendar_occurrences(p_from timestamptz,p_to timestamptz)
returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_account uuid:=public.require_current_account();
begin
  if p_to<=p_from then raise exception 'invalid occurrence range'; end if;
  return query
    select jsonb_build_object('kind','activity','id',a.id,'activity_id',a.id,'title',a.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',a.is_all_day,'area_id',a.area_id,'status',a.status)
    from public.activities a cross join lateral public.expand_recurrence_occurrences(coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone,p_from,p_to) o
    where (a.owner_account_id=v_account or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))) and a.status<>'cancelled'
    union all
    select jsonb_build_object('kind','event','id',e.id,'event_id',e.id,'title',e.title,
      'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',e.is_all_day,
      'area_id',e.area_id,'status',e.status,'visibility_source',s.visibility_source)
    from public.events e
    cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s
    cross join lateral public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,null,null,e.recurrence_until,e.recurrence_timezone,p_from,p_to) o
    where s.visibility_source is not null and e.status<>'cancelled'
    union all
    select jsonb_build_object('kind','deadline','deadline_id',x->>'deadline_id','title',x->>'title','due_on',x->>'occurrence_on','occurs_on',x->>'occurrence_on','all_day',true,'is_completed',coalesce((x->>'completed')::boolean,false))
    from public.get_deadline_occurrences(p_from::date,(p_to-interval '1 microsecond')::date) x;
end $$;

create or replace function public.get_dashboard(p_from timestamptz default now(),p_to timestamptz default (now()+interval '30 days'))
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_account uuid:=public.require_current_account();
begin
  if p_to<=p_from then raise exception 'invalid occurrence range'; end if;
  return jsonb_build_object(
    'activities',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('kind','activity','activity_id',a.id,'occurrence_starts_at',o.occurrence_starts_at,'occurrence_ends_at',o.occurrence_ends_at) order by o.occurrence_starts_at) from public.activities a cross join lateral public.expand_recurrence_occurrences(coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone,p_from,p_to) o where (a.owner_account_id=v_account or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id)))) and a.status<>'cancelled'),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(public.event_view_payload(e,s.visibility_source)||jsonb_build_object('kind','event','event_id',e.id,'occurrence_starts_at',o.occurrence_starts_at,'occurrence_ends_at',o.occurrence_ends_at) order by o.occurrence_starts_at) from public.events e cross join lateral (select public.event_visibility_source(e.id) as visibility_source) s cross join lateral public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,null,null,e.recurrence_until,e.recurrence_timezone,p_from,p_to) o where s.visibility_source is not null and e.status<>'cancelled'),'[]'::jsonb),
    'deadlines',coalesce((select jsonb_agg(x) from public.get_deadline_occurrences(p_from::date,(p_to-interval '1 microsecond')::date) x),'[]'::jsonb),
    'todos',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('kind','activity','activity_id',a.id) order by a.created_at) from public.activities a where (a.owner_account_id=v_account or (a.area_id is not null and (public.is_area_owner(a.area_id) or public.is_area_member(a.area_id))) ) and a.status='open' and a.starts_at is null and a.due_at is null),'[]'::jsonb)
  );
end $$;

alter function public.can_access_family(uuid) owner to postgres;
alter function public.event_visibility_source(uuid) owner to postgres;
alter function public.event_view_payload(public.events,text) owner to postgres;
alter function public.get_event_family_shares(uuid) owner to postgres;
alter function public.set_event_family_share(uuid,uuid,boolean) owner to postgres;
alter function public.can_view_event(uuid) owner to postgres;
alter function public.get_visible_events() owner to postgres;
alter function public.get_event(uuid) owner to postgres;
alter function public.get_calendar_occurrences(timestamptz,timestamptz) owner to postgres;
alter function public.get_dashboard(timestamptz,timestamptz) owner to postgres;
revoke all on function public.can_access_family(uuid),public.event_visibility_source(uuid),public.event_view_payload(public.events,text) from public,anon,authenticated;
revoke all on function public.get_event_family_shares(uuid),public.set_event_family_share(uuid,uuid,boolean) from public,anon;
grant execute on function public.get_event_family_shares(uuid),public.set_event_family_share(uuid,uuid,boolean) to authenticated;
