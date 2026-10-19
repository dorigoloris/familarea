-- FamilArea — retire Area operational branches from Events, Calendar and Dashboard.
-- Apply strictly after Phase A and 2026-10-12_retire_areas_account_rpcs.sql,
-- and before Phase B.  This file is intentionally atomic.
--
-- The definitions below are derived from the remote pg_get_functiondef output.
-- Only Area branches, Area membership checks, and Area payload lookups are removed.

begin;

create or replace function public.create_event(
  p_title text, p_starts_at timestamptz, p_ends_at timestamptz default null,
  p_description text default null, p_area_id uuid default null,
  p_is_all_day boolean default false, p_location text default null,
  p_recurrence jsonb default '{}'::jsonb, p_calendar_private boolean default false,
  p_event_kind text default null
) returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_owner uuid; v_id uuid;
  v_frequency text := nullif(lower(btrim(coalesce(p_recurrence->>'frequency',''))), '');
  v_interval smallint; v_weekdays smallint[];
  v_until date := nullif(p_recurrence->>'until','')::date;
  v_timezone text := nullif(btrim(coalesce(p_recurrence->>'timezone','')), '');
  v_private boolean := coalesce(p_calendar_private, false);
begin
  if p_area_id is not null then raise exception 'Area events are retired'; end if;
  v_owner := public.require_current_account();
  if v_private and not exists (
    select 1 from public.accounts a where a.id = v_owner and a.account_type = 'personal'
  ) then raise exception 'only personal events can be private in a shared calendar'; end if;

  if v_frequency is null then
    v_interval := null; v_weekdays := null; v_until := null; v_timezone := null;
  else
    if v_frequency <> 'weekly' then raise exception 'unsupported recurrence frequency'; end if;
    v_interval := coalesce(nullif(p_recurrence->>'interval','')::smallint, 1);
    if v_interval < 1 then raise exception 'invalid recurrence interval'; end if;
    if p_recurrence ? 'weekdays' then
      if jsonb_typeof(p_recurrence->'weekdays') <> 'array' then raise exception 'invalid recurrence weekdays'; end if;
      select array_agg(distinct value::smallint order by value::smallint) into v_weekdays
      from jsonb_array_elements_text(p_recurrence->'weekdays') as weekdays(value);
    else
      v_weekdays := array[extract(isodow from (p_starts_at at time zone v_timezone))::smallint];
    end if;
    if v_weekdays is null or cardinality(v_weekdays) = 0
      or array_position(v_weekdays, null) is not null
      or not (v_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]) then raise exception 'invalid recurrence weekdays'; end if;
    perform 1 from pg_timezone_names where name = v_timezone;
    if v_timezone is null or not found then raise exception 'invalid recurrence timezone'; end if;
    if v_until is not null and v_until < (p_starts_at at time zone v_timezone)::date then
      raise exception 'recurrence end date precedes event start';
    end if;
  end if;

  insert into public.events (
    owner_account_id, title, description, starts_at, ends_at, is_all_day, location,
    recurrence_frequency, recurrence_interval, recurrence_weekdays, recurrence_until,
    recurrence_timezone, created_by_account_id, calendar_private, event_kind
  ) values (
    v_owner, nullif(btrim(p_title), ''), nullif(btrim(p_description), ''),
    p_starts_at, p_ends_at, coalesce(p_is_all_day, false), nullif(btrim(p_location), ''),
    v_frequency, v_interval, v_weekdays, v_until, v_timezone,
    public.require_current_account(), v_private, p_event_kind
  ) returning id into v_id;
  return v_id;
end $$;

create or replace function public.update_event(
  p_event_id uuid, p_title text, p_starts_at timestamptz, p_ends_at timestamptz default null,
  p_description text default null, p_is_all_day boolean default false, p_location text default null,
  p_recurrence jsonb default '{}'::jsonb, p_calendar_private boolean default false,
  p_event_kind text default null
) returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v public.events%rowtype;
  v_frequency text := nullif(lower(btrim(coalesce(p_recurrence->>'frequency',''))), '');
  v_interval smallint; v_weekdays smallint[];
  v_until date := nullif(p_recurrence->>'until','')::date;
  v_timezone text := nullif(btrim(coalesce(p_recurrence->>'timezone','')), '');
  v_private boolean := coalesce(p_calendar_private, false);
begin
  select * into v from public.events where id = p_event_id;
  if not found or v.owner_account_id is null or v.owner_account_id <> public.require_current_account() then
    raise exception 'permission denied';
  end if;
  if v_private and not exists (
    select 1 from public.accounts a where a.id = v.owner_account_id and a.account_type = 'personal'
  ) then raise exception 'only personal events can be private in a shared calendar'; end if;

  if v_frequency is null then
    v_interval := null; v_weekdays := null; v_until := null; v_timezone := null;
  else
    if v_frequency <> 'weekly' then raise exception 'unsupported recurrence frequency'; end if;
    v_interval := coalesce(nullif(p_recurrence->>'interval','')::smallint, 1);
    if v_interval < 1 then raise exception 'invalid recurrence interval'; end if;
    if p_recurrence ? 'weekdays' then
      if jsonb_typeof(p_recurrence->'weekdays') <> 'array' then raise exception 'invalid recurrence weekdays'; end if;
      select array_agg(distinct value::smallint order by value::smallint) into v_weekdays
      from jsonb_array_elements_text(p_recurrence->'weekdays') as weekdays(value);
    else
      v_weekdays := array[extract(isodow from (p_starts_at at time zone v_timezone))::smallint];
    end if;
    if v_weekdays is null or cardinality(v_weekdays) = 0
      or array_position(v_weekdays, null) is not null
      or not (v_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]) then raise exception 'invalid recurrence weekdays'; end if;
    perform 1 from pg_timezone_names where name = v_timezone;
    if v_timezone is null or not found then raise exception 'invalid recurrence timezone'; end if;
    if v_until is not null and v_until < (p_starts_at at time zone v_timezone)::date then
      raise exception 'recurrence end date precedes event start';
    end if;
  end if;
  update public.events set
    title = nullif(btrim(p_title), ''), description = nullif(btrim(p_description), ''),
    starts_at = p_starts_at, ends_at = p_ends_at, is_all_day = coalesce(p_is_all_day, false),
    location = nullif(btrim(p_location), ''), recurrence_frequency = v_frequency,
    recurrence_interval = v_interval, recurrence_weekdays = v_weekdays, recurrence_until = v_until,
    recurrence_timezone = v_timezone, calendar_private = v_private,
    event_kind = coalesce(p_event_kind, v.event_kind)
  where id = p_event_id returning * into v;
  return to_jsonb(v);
end $$;

-- Public wrappers retain their deployed signatures and delegate to the guarded CRUD above.
create or replace function public.create_event_with_interests(
  p_title text, p_starts_at timestamptz, p_ends_at timestamptz default null,
  p_description text default null, p_area_id uuid default null, p_is_all_day boolean default false,
  p_location text default null, p_recurrence jsonb default '{}'::jsonb,
  p_calendar_private boolean default false, p_interest_ids uuid[] default '{}'::uuid[],
  p_event_kind text default null
) returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_event_id uuid;
begin
  v_event_id := public.create_event(p_title,p_starts_at,p_ends_at,p_description,p_area_id,p_is_all_day,p_location,p_recurrence,p_calendar_private,p_event_kind);
  perform public.set_event_interests(v_event_id, p_interest_ids);
  return v_event_id;
end $$;

create or replace function public.update_event_with_interests(
  p_event_id uuid, p_title text, p_starts_at timestamptz, p_ends_at timestamptz default null,
  p_description text default null, p_is_all_day boolean default false, p_location text default null,
  p_recurrence jsonb default '{}'::jsonb, p_calendar_private boolean default false,
  p_interest_ids uuid[] default '{}'::uuid[], p_event_kind text default null
) returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_event jsonb;
begin
  v_event := public.update_event(p_event_id,p_title,p_starts_at,p_ends_at,p_description,p_is_all_day,p_location,p_recurrence,p_calendar_private,p_event_kind);
  perform public.set_event_interests(p_event_id, p_interest_ids);
  return v_event;
end $$;

create or replace function public.event_personal_source(p_event_id uuid, p_account_id uuid)
returns text language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select case
    when p_account_id is null then null
    when e.owner_account_id = p_account_id then 'owner'
    when e.created_by_account_id = p_account_id then 'creator'
    when e.event_kind is distinct from 'commitment' and exists (
      select 1 from public.event_participants ep where ep.event_id = e.id and ep.status = 'active' and (
        exists (select 1 from public.profiles p where p.id = ep.profile_id and p.account_id = p_account_id)
        or exists (select 1 from public.contact_profile_links l join public.profiles p on p.id = l.profile_id where l.contact_id = ep.contact_id and p.account_id = p_account_id)
        or exists (select 1 from public.contact_account_links l where l.contact_id = ep.contact_id and l.linked_account_id = p_account_id)
      )
    ) then 'participant'
    else null end
  from public.events e where e.id = p_event_id
$$;

create or replace function public.event_visibility_source(p_event_id uuid) returns text
language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select coalesce(public.event_personal_source(p_event_id, public.current_account_id()),
    case when public.event_is_suggested(p_event_id, public.current_account_id()) then 'suggestion' end)
$$;

create or replace function public.event_is_suggested(p_event_id uuid, p_account_id uuid) returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select exists (
    select 1 from public.events e
    join public.profiles profile on profile.account_id = p_account_id
    join public.profile_interests pi on pi.profile_id = profile.id
    join public.event_interests ei on ei.event_id = e.id and ei.interest_id = pi.interest_id
    join public.interests i on i.id = ei.interest_id
    join public.interest_categories c on c.id = i.category_id
    where e.id = p_event_id and e.status = 'active' and i.origin = 'catalog'
      and i.publication_status = 'published' and i.status = 'active' and c.status = 'active'
      and e.owner_account_id is distinct from p_account_id
      and e.created_by_account_id is distinct from p_account_id
      and public.event_personal_source(e.id, p_account_id) is null
      and exists (select 1 from public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,e.recurrence_interval,e.recurrence_weekdays,e.recurrence_until,e.recurrence_timezone,now(),now()+interval '400 days'))
      and not exists (
        select 1 from public.event_participants ep where ep.event_id=e.id and ep.status in ('active','removed') and (
          ep.profile_id=profile.id or exists (select 1 from public.contact_profile_links l where l.profile_id=profile.id and l.contact_id=ep.contact_id)
        )
      )
      and not exists (
        select 1 from public.event_invites ei_pending
        join public.accounts account on account.id=p_account_id
        join auth.users auth_user on auth_user.id=account.auth_user_id
        where ei_pending.event_id=e.id and ei_pending.status='pending' and ei_pending.expires_at>now()
          and lower(ei_pending.recipient_email)=lower(auth_user.email)
      )
  )
$$;

create or replace function public.event_view_payload(p_event public.events, p_visibility_source text)
returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select to_jsonb(p_event) || jsonb_build_object(
    'visibility_source', p_visibility_source,
    'can_manage', p_visibility_source in ('owner','creator'),
    'organizer_name', coalesce((select o.name from public.organizations o where o.account_id=p_event.owner_account_id),nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),''),'Organizzatore'),
    'area_name', null,
    'is_suggested', public.event_is_suggested(p_event.id, public.current_account_id())
  ) from public.profiles p where p.account_id=p_event.owner_account_id
  union all
  select to_jsonb(p_event) || jsonb_build_object(
    'visibility_source', p_visibility_source,
    'can_manage', p_visibility_source in ('owner','creator'),
    'organizer_name', coalesce((select o.name from public.organizations o where o.account_id=p_event.owner_account_id),'Organizzatore'),
    'area_name', null,
    'is_suggested', public.event_is_suggested(p_event.id, public.current_account_id())
  ) where p_event.owner_account_id is not null
    and not exists (select 1 from public.profiles p where p.account_id=p_event.owner_account_id)
$$;

-- These RPCs retain their public contracts; their authorization now flows exclusively
-- through event_personal_source / require_event_manage_scope.
create or replace function public.get_visible_events() returns setof jsonb
language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select public.event_view_payload(e,s.personal_source) from public.events e
  cross join lateral (select public.event_personal_source(e.id,public.current_account_id()) as personal_source) s
  where s.personal_source is not null and e.status <> 'cancelled'
  order by e.starts_at,e.created_at,e.id
$$;

create or replace function public.get_event(p_event_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_event public.events%rowtype; v_source text;
begin
  select e.* into v_event from public.events e where e.id=p_event_id;
  if not found then raise exception 'permission denied'; end if;
  v_source:=public.event_visibility_source(p_event_id);
  if v_source is null then raise exception 'permission denied'; end if;
  return public.event_view_payload(v_event,v_source);
end $$;

create or replace function public.get_my_contacts_for_event(p_event_id uuid) returns setof jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_scope record;
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);
  return query with linked_contacts as (
    select c.id contact_id,c.first_name,c.last_name,count(recipient.recipient_account_id) recipient_count,
      min(recipient.recipient_account_id::text)::uuid recipient_account_id,min(recipient.recipient_account_type) recipient_account_type
    from public.contacts c cross join lateral public.event_invite_verified_recipient_for_contact(v_scope.owner_account_id,c.id) recipient
    where c.owner_account_id=v_scope.owner_account_id and recipient.recipient_account_id <> v_scope.owner_account_id
    group by c.id,c.first_name,c.last_name
  ) select jsonb_build_object('contact_id',lc.contact_id,'first_name',lc.first_name,'last_name',lc.last_name,
    'recipient_account_id',lc.recipient_account_id,'recipient_account_type',lc.recipient_account_type,
    'is_active_participant',exists(select 1 from public.event_participants ep where ep.event_id=p_event_id and ep.contact_id=lc.contact_id and ep.status='active'))
  from linked_contacts lc where lc.recipient_count=1 and not exists(
    select 1 from public.event_invites ei where ei.event_id=p_event_id and ei.contact_id=lc.contact_id and ei.status='pending' and ei.expires_at>now()
  ) order by lower(lc.first_name),lower(coalesce(lc.last_name,''));
end $$;

create or replace function public.get_my_event_invites()
returns table(invite_id uuid,status text,created_at timestamptz,expires_at timestamptz,event_id uuid,event_title text,starts_at timestamptz,ends_at timestamptz,is_all_day boolean,event_status text,area_name text,organizer_name text)
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_recipient record;
begin
  select * into v_recipient from public.contact_share_recipient_identity();
  update public.event_invites ei set status='expired' where ei.recipient_email=v_recipient.email and ei.status='pending' and ei.expires_at<=now();
  return query select ei.id,ei.status,ei.created_at,ei.expires_at,e.id,e.title,e.starts_at,e.ends_at,e.is_all_day,e.status,
    null::text,coalesce(o.name,nullif(btrim(concat_ws(' ',inviter.first_name,inviter.last_name)),''),'Organizzatore FamilArea')
  from public.event_invites ei join public.events e on e.id=ei.event_id
  left join public.organizations o on o.account_id=ei.owner_account_id
  left join public.profiles inviter on inviter.account_id=ei.invited_by_account_id
  where ei.recipient_email=v_recipient.email and ei.status='pending' and ei.expires_at>now()
  order by ei.created_at desc,ei.id;
end $$;

-- Kept for token-link compatibility, but it now uses the same verified-contact
-- recipient guard as the direct in-app invitation flow.  It never opens an Area path.
create or replace function public.create_event_invite(
  p_event_id uuid, p_recipient_email text, p_first_name text, p_last_name text default null
) returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  v_scope record; v_email text; v_contact uuid; v_existing_contacts integer; v_invite_id uuid;
  v_contact_first_name text; v_contact_last_name text; v_recipient_count integer;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);
  v_email := public.normalize_contact_email(p_recipient_email);
  update public.event_invites set status='expired'
  where event_id=p_event_id and recipient_email=v_email and status='pending' and expires_at<=now();
  select contact_id into v_contact from public.contact_email_identities
  where owner_account_id=v_scope.owner_account_id and normalized_email=v_email;
  if v_contact is null then
    select count(distinct c.id),min(c.id::text)::uuid into v_existing_contacts,v_contact
    from public.contacts c join public.contact_methods cm on cm.contact_id=c.id
    where c.owner_account_id=v_scope.owner_account_id and cm.method_type='email' and lower(btrim(cm.value))=v_email;
    if v_existing_contacts>1 then raise exception 'ambiguous contact email'; end if;
  end if;
  if v_contact is null then
    if nullif(btrim(coalesce(p_first_name,'')),'') is null then raise exception 'first name is required'; end if;
    insert into public.contacts(owner_account_id,first_name,last_name)
    values(v_scope.owner_account_id,btrim(p_first_name),nullif(btrim(coalesce(p_last_name,'')),'')) returning id into v_contact;
  end if;
  select first_name,last_name into v_contact_first_name,v_contact_last_name from public.contacts where id=v_contact;
  insert into public.contact_email_identities(owner_account_id,normalized_email,contact_id)
  values(v_scope.owner_account_id,v_email,v_contact) on conflict(owner_account_id,normalized_email) do nothing;
  select count(*) into v_recipient_count from public.event_invite_verified_recipient_for_contact(v_scope.owner_account_id,v_contact) recipient
  where recipient.recipient_account_id<>v_scope.owner_account_id and recipient.recipient_email=v_email;
  if v_recipient_count<>1 then raise exception 'event invite contact is not linked to exactly one verified recipient account'; end if;
  perform pg_advisory_xact_lock(hashtext(p_event_id::text || ':' || v_contact::text));
  if exists(select 1 from public.event_invites ei where ei.event_id=p_event_id and ei.contact_id=v_contact and ei.status='pending' and ei.expires_at>now()) then
    raise exception 'pending event invite already exists';
  end if;
  if exists(select 1 from public.event_participants where event_id=p_event_id and contact_id=v_contact and status='active') then
    raise exception 'contact already participates in this event';
  end if;
  if exists(select 1 from public.event_invites where event_id=p_event_id and recipient_email=v_email and status='pending') then
    raise exception 'pending event invite already exists';
  end if;
  insert into public.event_invites(event_id,owner_account_id,contact_id,recipient_email,recipient_first_name,recipient_last_name,token_hash,expires_at,invited_by_account_id)
  values(p_event_id,v_scope.owner_account_id,v_contact,v_email,v_contact_first_name,v_contact_last_name,public.hash_event_invite_token(v_token),now()+interval '14 days',public.require_current_account()) returning id into v_invite_id;
  return jsonb_build_object('token',v_token,'contact_id',v_contact,'invite_id',v_invite_id);
end $$;

create or replace function public.create_event_invite_for_contact(p_event_id uuid,p_contact_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_scope record; v_first_name text; v_last_name text; v_email text; v_result jsonb;
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);
  select c.first_name,c.last_name into v_first_name,v_last_name from public.contacts c where c.id=p_contact_id and c.owner_account_id=v_scope.owner_account_id;
  if not found then raise exception 'contact unavailable'; end if;
  select cm.value into v_email from public.contact_methods cm where cm.contact_id=p_contact_id and cm.method_type='email' order by cm.is_primary desc,cm.id limit 1;
  if v_email is null then raise exception 'contact has no usable email'; end if;
  v_email:=public.normalize_contact_email(v_email);
  v_result:=public.create_event_invite(p_event_id,v_email,v_first_name,v_last_name);
  if (v_result->>'contact_id')::uuid<>p_contact_id then raise exception 'contact email identity conflict'; end if;
  return v_result;
end $$;

create or replace function public.get_calendar_occurrences(p_from timestamptz,p_to timestamptz) returns setof jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_account uuid:=public.require_current_account(); v_to_date date:=(p_to-interval '1 microsecond')::date;
begin
 if p_to<=p_from then raise exception 'invalid occurrence range'; end if;
 return query with calendar_accounts as (
  select v_account account_id,false is_shared where coalesce((select l.visible from public.person_calendar_links l where l.owner_account_id=v_account and l.viewer_account_id=v_account),true)
  union all select l.owner_account_id,true from public.person_calendar_links l where l.viewer_account_id=v_account and l.owner_account_id<>v_account and l.visible and public.can_view_person_calendar(l.owner_account_id,v_account)
 )
 select jsonb_build_object('kind','activity','id',a.id,'activity_id',a.id,'title',a.title,'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',a.is_all_day,'area_id',null::uuid,'status',a.status,'area_name',null::text,'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),''))
 from calendar_accounts s left join public.profiles p on p.account_id=s.account_id
 join public.activities a on a.status<>'cancelled' and a.owner_account_id=s.account_id
 cross join lateral public.expand_recurrence_occurrences(coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone,p_from,p_to) o
 union all
 select jsonb_build_object('kind','event','event_kind',e.event_kind,'id',e.id,'event_id',e.id,'title',e.title,'starts_at',o.occurrence_starts_at,'ends_at',o.occurrence_ends_at,'all_day',e.is_all_day,'area_id',null::uuid,'status',e.status,'area_name',null::text,'calendar_private',e.calendar_private,'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),''))
 from calendar_accounts s left join public.profiles p on p.account_id=s.account_id
 join public.events e on e.status<>'cancelled' and (s.account_id=v_account or not e.calendar_private) and public.event_personal_source(e.id,s.account_id) is not null
 cross join lateral public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,e.recurrence_interval,e.recurrence_weekdays,e.recurrence_until,e.recurrence_timezone,p_from,p_to) o
 union all
 select jsonb_build_object('kind','deadline','deadline_id',d.id,'title',d.title,'due_on',o.occurrence_on,'occurs_on',o.occurrence_on,'all_day',d.start_time is null,'starts_at',case when d.start_time is null then null else o.occurrence_on::date+d.start_time end,'ends_at',case when d.end_time is null then null else o.occurrence_on::date+d.end_time end,'is_completed',c.deadline_id is not null,'family_member_id',fm.id,'family_member_name',nullif(btrim(concat_ws(' ',fm.first_name,fm.last_name)),''),'family_member_type',fm.member_type,'family_member_avatar_path',fm.avatar_path,'deadline_item_id',di.id,'deadline_item_name',di.name,'deadline_item_category',di.category,'deadline_item_type',di.item_type,'deadline_item_image_path',di.image_path,'calendar_owner_account_id',s.account_id,'calendar_is_shared',s.is_shared,'calendar_owner_display_name',nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),''))
 from calendar_accounts s left join public.profiles p on p.account_id=s.account_id
 join public.deadlines d on d.owner_account_id=s.account_id and d.status='active' and public.is_resolved_personal_document_deadline(d.id)
 left join public.family_members fm on fm.id=d.family_member_id left join public.deadline_items di on di.id=d.deadline_item_id and di.owner_account_id=d.owner_account_id
 cross join lateral generate_series(d.first_due_on,least(coalesce(d.terminated_on,v_to_date),v_to_date),make_interval(months=>coalesce(d.recurrence_months,1200))) o(occurrence_on)
 left join public.deadline_occurrence_completions c on c.deadline_id=d.id and c.occurrence_on=o.occurrence_on where o.occurrence_on between p_from::date and v_to_date;
end $$;

create or replace function public.get_dashboard(p_from timestamptz default now(),p_to timestamptz default (now()+interval '30 days')) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_account uuid:=public.require_current_account();
begin
 if p_to<=p_from then raise exception 'invalid occurrence range'; end if;
 return jsonb_build_object(
  'activities',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('kind','activity','activity_id',a.id,'occurrence_starts_at',o.occurrence_starts_at,'occurrence_ends_at',o.occurrence_ends_at) order by o.occurrence_starts_at) from public.activities a cross join lateral public.expand_recurrence_occurrences(coalesce(a.starts_at,a.due_at),a.due_at,a.recurrence_frequency,a.recurrence_interval,a.recurrence_weekdays,a.recurrence_until,a.recurrence_timezone,p_from,p_to) o where a.owner_account_id=v_account and a.status<>'cancelled'),'[]'::jsonb),
  'events',coalesce((select jsonb_agg(public.event_view_payload(e,s.personal_source)||jsonb_build_object('kind','event','event_id',e.id,'occurrence_starts_at',o.occurrence_starts_at,'occurrence_ends_at',o.occurrence_ends_at) order by o.occurrence_starts_at) from public.events e cross join lateral(select public.event_personal_source(e.id,v_account) personal_source)s cross join lateral public.expand_recurrence_occurrences(e.starts_at,e.ends_at,e.recurrence_frequency,e.recurrence_interval,e.recurrence_weekdays,e.recurrence_until,e.recurrence_timezone,p_from,p_to)o where s.personal_source is not null and e.status<>'cancelled'),'[]'::jsonb),
  'deadlines',coalesce((select jsonb_agg(x) from public.get_deadline_occurrences(p_from::date,(p_to-interval '1 microsecond')::date)x),'[]'::jsonb),
  'todos',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('kind','activity','activity_id',a.id) order by a.created_at) from public.activities a where a.owner_account_id=v_account and a.status='open' and a.starts_at is null and a.due_at is null),'[]'::jsonb)
 );
end $$;

-- CREATE OR REPLACE preserves function owner and ACL.  Recheck grants/owner before production execution.
commit;
