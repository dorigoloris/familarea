-- FamilArea — Event interests, private suggestions and explicit Contact-first join.
-- Suggestions are computed from profile_interests; they never create participation.

begin;

create table public.event_interests (
  event_id uuid not null references public.events(id) on delete cascade,
  interest_id uuid not null references public.interests(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (event_id, interest_id)
);

create index event_interests_interest_event_idx
  on public.event_interests(interest_id, event_id);

alter table public.event_interests enable row level security;
alter table public.event_interests no force row level security;
revoke all on public.event_interests from public, anon, authenticated;

create or replace function public.event_personal_source(p_event_id uuid, p_account_id uuid)
returns text
language sql stable security definer set search_path=public,pg_temp as $$
  select case
    when p_account_id is null then null
    when e.owner_account_id = p_account_id then 'owner'
    when e.area_id is null and e.created_by_account_id = p_account_id then 'creator'
    when exists (
      select 1 from public.event_participants ep
      where ep.event_id = e.id and ep.status = 'active'
        and (
          exists (select 1 from public.profiles p
            where p.id = ep.profile_id and p.account_id = p_account_id)
          or exists (select 1 from public.contact_profile_links l
            join public.profiles p on p.id = l.profile_id
            where l.contact_id = ep.contact_id and p.account_id = p_account_id)
        )
    ) then 'participant'
    else null
  end
  from public.events e where e.id = p_event_id
$$;

create or replace function public.event_is_suggested(p_event_id uuid, p_account_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select exists (
    select 1
    from public.events e
    join public.profiles profile on profile.account_id = p_account_id
    join public.profile_interests pi on pi.profile_id = profile.id
    join public.event_interests ei on ei.event_id = e.id and ei.interest_id = pi.interest_id
    join public.interests i on i.id = ei.interest_id
    join public.interest_categories c on c.id = i.category_id
    where e.id = p_event_id
      and e.status = 'active'
      and coalesce(e.ends_at, e.starts_at) >= now()
      and i.origin = 'catalog'
      and i.publication_status = 'published'
      and i.status = 'active'
      and c.status = 'active'
      and e.owner_account_id is distinct from p_account_id
      and not (e.area_id is null and e.created_by_account_id = p_account_id)
      and not public.event_personal_source(e.id, p_account_id) is not null
      and not exists (
        select 1 from public.event_participants ep
        where ep.event_id = e.id
          and ep.status in ('active', 'removed')
          and (
            ep.profile_id = profile.id
            or exists (
              select 1 from public.contact_profile_links l
              where l.profile_id = profile.id and l.contact_id = ep.contact_id
            )
          )
      )
      and not exists (
        select 1 from public.event_invites ei_pending
        join public.accounts account on account.id = p_account_id
        join auth.users auth_user on auth_user.id = account.auth_user_id
        where ei_pending.event_id = e.id
          and ei_pending.status = 'pending'
          and ei_pending.expires_at > now()
          and lower(ei_pending.recipient_email) = lower(auth_user.email)
      )
  )
$$;

create or replace function public.set_event_interests(p_event_id uuid, p_interest_ids uuid[])
returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_event public.events%rowtype;
  v_interest_ids uuid[] := coalesce(p_interest_ids, '{}');
  v_account uuid := public.require_current_account();
begin
  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'event not found'; end if;
  if v_event.area_id is not null then
    if not public.can_manage_area(v_event.area_id) then raise exception 'permission denied'; end if;
  elsif v_event.owner_account_id is distinct from v_account then
    raise exception 'permission denied';
  end if;
  if array_position(v_interest_ids, null) is not null then raise exception 'invalid Event interests'; end if;
  if exists (
    select 1 from (select distinct unnest(v_interest_ids) as interest_id) selected
    where not exists (
      select 1 from public.interests i
      join public.interest_categories c on c.id = i.category_id
      where i.id = selected.interest_id
        and i.origin = 'catalog' and i.publication_status = 'published' and i.status = 'active'
        and c.status = 'active'
    )
  ) then raise exception 'only active published catalog interests can tag Events'; end if;

  delete from public.event_interests WHERE event_id = p_event_id;
  insert into public.event_interests(event_id, interest_id)
  select p_event_id, selected.interest_id
  from (select distinct unnest(v_interest_ids) as interest_id) selected;
end $$;

create or replace function public.get_event_interests(p_event_id uuid)
returns setof jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not public.can_view_event(p_event_id) then raise exception 'permission denied'; end if;
  return query
    select jsonb_build_object(
      'interest_id', i.id,
      'category_id', c.id,
      'category_name', c.name,
      'display_name', i.display_name
    )
    from public.event_interests ei
    join public.interests i on i.id = ei.interest_id
    join public.interest_categories c on c.id = i.category_id
    where ei.event_id = p_event_id
      and i.origin = 'catalog'
      and i.publication_status = 'published'
      and i.status = 'active'
      and c.status = 'active'
    order by c.name, i.display_name;
end $$;

create or replace function public.get_my_event_suggestions()
returns setof jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  v_profile uuid := public.require_personal_profile();
  v_account uuid := public.require_personal_account();
begin
  return query
    select jsonb_build_object(
      'event_id', e.id,
      'title', e.title,
      'description', e.description,
      'starts_at', e.starts_at,
      'ends_at', e.ends_at,
      'is_all_day', e.is_all_day,
      'location', e.location,
      'area_id', e.area_id,
      'area_name', a.name,
      'organizer_name', coalesce(o.name, nullif(btrim(concat_ws(' ', organizer_profile.first_name, organizer_profile.last_name)), ''), 'Organizzatore'),
      'matching_interests', matches.items
    )
    from public.events e
    left join public.areas a on a.id = e.area_id
    left join public.accounts organizer on organizer.id = coalesce(e.owner_account_id, a.owner_account_id)
    left join public.organizations o on o.account_id = organizer.id
    left join public.profiles organizer_profile on organizer_profile.account_id = organizer.id
    cross join lateral (
      select jsonb_agg(jsonb_build_object(
        'interest_id', i.id, 'display_name', i.display_name, 'category_name', c.name
      ) order by c.name, i.display_name) as items
      from public.profile_interests pi
      join public.interests i on i.id = pi.interest_id
      join public.interest_categories c on c.id = i.category_id
      join public.event_interests ei on ei.interest_id = i.id and ei.event_id = e.id
      where pi.profile_id = v_profile
        and i.origin = 'catalog' and i.publication_status = 'published' and i.status = 'active'
        and c.status = 'active'
    ) matches
    where public.event_is_suggested(e.id, v_account)
    order by e.starts_at, e.created_at, e.id;
end $$;

create or replace function public.join_suggested_event(p_event_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_profile uuid := public.require_personal_profile();
  v_account uuid := public.require_personal_account();
  v_event public.events%rowtype;
  v_organizer_account uuid;
  v_contact_id uuid;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'event not found'; end if;

  if exists (
    select 1 from public.event_participants ep
    where ep.event_id = p_event_id and ep.status = 'active'
      and (
        ep.profile_id = v_profile
        or exists (
          select 1 from public.contact_profile_links l
          where l.contact_id = ep.contact_id and l.profile_id = v_profile
        )
      )
  ) then
    return jsonb_build_object('event_id', p_event_id, 'status', 'already_participating');
  end if;
  if not public.event_is_suggested(p_event_id, v_account) then
    raise exception 'event is not currently suggested to this profile';
  end if;

  select coalesce(v_event.owner_account_id, a.owner_account_id)
    into v_organizer_account
  from (select v_event.area_id as area_id) event_area
  left join public.areas a on a.id = event_area.area_id;
  if v_organizer_account is null then raise exception 'event organizer is unavailable'; end if;

  select l.contact_id into v_contact_id
  from public.contact_profile_links l
  join public.contacts c on c.id = l.contact_id and c.owner_account_id = l.owner_account_id
  where l.owner_account_id = v_organizer_account and l.profile_id = v_profile;
  if v_contact_id is null then
    raise exception 'event organizer has no linked Contact for this profile; use an organizer Event invitation';
  end if;

  insert into public.event_participants(
    event_id, contact_id, profile_id, status, accepted_at, added_via, added_by_account_id
  ) values (
    p_event_id, v_contact_id, v_profile, 'active', now(), 'direct', v_account
  ) on conflict (event_id, contact_id) do update
    set profile_id = excluded.profile_id,
        status = 'active',
        accepted_at = coalesce(event_participants.accepted_at, excluded.accepted_at),
        added_via = 'direct',
        added_by_account_id = excluded.added_by_account_id,
        updated_at = now();

  return jsonb_build_object('event_id', p_event_id, 'contact_id', v_contact_id, 'status', 'active');
end $$;

create or replace function public.event_visibility_source(p_event_id uuid)
returns text
language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce(
    public.event_personal_source(p_event_id, public.current_account_id()),
    case when public.event_is_suggested(p_event_id, public.current_account_id()) then 'suggestion' end,
    case when e.area_id is not null
      and (public.is_area_owner(e.area_id) or public.is_area_member(e.area_id))
      then 'area' end
  )
  from public.events e where e.id = p_event_id
$$;

create or replace function public.event_view_payload(p_event public.events, p_visibility_source text)
returns jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select to_jsonb(p_event) || jsonb_build_object(
    'visibility_source', p_visibility_source,
    'can_manage', p_visibility_source in ('owner', 'creator')
      or (p_visibility_source = 'area' and public.can_manage_area(p_event.area_id)),
    'organizer_name', coalesce(
      (select o.name from public.organizations o where o.account_id = coalesce(p_event.owner_account_id, a.owner_account_id)),
      nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), ''),
      'Organizzatore'
    ),
    'area_name', a.name,
    'is_suggested', public.event_is_suggested(p_event.id, public.current_account_id())
  )
  from public.areas a
  left join public.profiles p on p.account_id = coalesce(p_event.owner_account_id, a.owner_account_id)
  where a.id = p_event.area_id
  union all
  select to_jsonb(p_event) || jsonb_build_object(
    'visibility_source', p_visibility_source,
    'can_manage', p_visibility_source in ('owner', 'creator'),
    'organizer_name', coalesce(
      (select o.name from public.organizations o where o.account_id = p_event.owner_account_id),
      nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), ''),
      'Organizzatore'
    ),
    'area_name', null,
    'is_suggested', public.event_is_suggested(p_event.id, public.current_account_id())
  )
  from public.profiles p
  where p_event.area_id is null
    and p.account_id = p_event.owner_account_id
  union all
  select to_jsonb(p_event) || jsonb_build_object(
    'visibility_source', p_visibility_source,
    'can_manage', p_visibility_source in ('owner', 'creator'),
    'organizer_name', coalesce(
      (select o.name from public.organizations o where o.account_id = p_event.owner_account_id),
      'Organizzatore'
    ),
    'area_name', null,
    'is_suggested', public.event_is_suggested(p_event.id, public.current_account_id())
  )
  where p_event.area_id is null and p_event.owner_account_id is null
$$;

create or replace function public.get_event_interests(p_event_id uuid)
returns setof jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not public.can_view_event(p_event_id) then raise exception 'permission denied'; end if;
  return query
    select jsonb_build_object('interest_id', i.id, 'category_id', c.id,
      'category_name', c.name, 'display_name', i.display_name)
    from public.event_interests ei
    join public.interests i on i.id = ei.interest_id
    join public.interest_categories c on c.id = i.category_id
    where ei.event_id = p_event_id and i.origin = 'catalog'
      and i.publication_status = 'published' and i.status = 'active' and c.status = 'active'
    order by c.name, i.display_name;
end $$;

create or replace function public.create_event_with_interests(
  p_title text, p_starts_at timestamptz, p_ends_at timestamptz default null,
  p_description text default null, p_area_id uuid default null,
  p_is_all_day boolean default false, p_location text default null,
  p_recurrence jsonb default '{}'::jsonb, p_calendar_private boolean default false,
  p_interest_ids uuid[] default '{}'
)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_event_id uuid;
begin
  v_event_id := public.create_event(p_title, p_starts_at, p_ends_at, p_description,
    p_area_id, p_is_all_day, p_location, p_recurrence, p_calendar_private);
  perform public.set_event_interests(v_event_id, p_interest_ids);
  return v_event_id;
end $$;

create or replace function public.update_event_with_interests(
  p_event_id uuid, p_title text, p_starts_at timestamptz,
  p_ends_at timestamptz default null, p_description text default null,
  p_is_all_day boolean default false, p_location text default null,
  p_recurrence jsonb default '{}'::jsonb, p_calendar_private boolean default false,
  p_interest_ids uuid[] default '{}'
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_event jsonb;
begin
  v_event := public.update_event(p_event_id, p_title, p_starts_at, p_ends_at,
    p_description, p_is_all_day, p_location, p_recurrence, p_calendar_private);
  perform public.set_event_interests(p_event_id, p_interest_ids);
  return v_event;
end $$;

alter function public.event_is_suggested(uuid,uuid) owner to postgres;
alter function public.event_personal_source(uuid,uuid) owner to postgres;
alter function public.set_event_interests(uuid,uuid[]) owner to postgres;
alter function public.get_event_interests(uuid) owner to postgres;
alter function public.get_my_event_suggestions() owner to postgres;
alter function public.join_suggested_event(uuid) owner to postgres;
alter function public.event_visibility_source(uuid) owner to postgres;
alter function public.event_view_payload(public.events,text) owner to postgres;
alter function public.create_event_with_interests(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,boolean,uuid[]) owner to postgres;
alter function public.update_event_with_interests(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,boolean,uuid[]) owner to postgres;

revoke all on public.event_interests from public,anon,authenticated;
revoke all on function public.event_is_suggested(uuid,uuid),
  public.set_event_interests(uuid,uuid[]), public.get_event_interests(uuid),
  public.get_my_event_suggestions(), public.join_suggested_event(uuid),
  public.create_event_with_interests(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,boolean,uuid[]),
  public.update_event_with_interests(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,boolean,uuid[])
  from public,anon;
grant execute on function public.get_event_interests(uuid), public.get_my_event_suggestions(),
  public.join_suggested_event(uuid),
  public.create_event_with_interests(text,timestamptz,timestamptz,text,uuid,boolean,text,jsonb,boolean,uuid[]),
  public.update_event_with_interests(uuid,text,timestamptz,timestamptz,text,boolean,text,jsonb,boolean,uuid[])
  to authenticated;

commit;