-- FamilArea — account-owned operational RPCs for Area retirement.
-- Apply after phase A and before phase B/C. Public signatures containing
-- p_area_id are retained temporarily for deployed callers, but non-null values
-- are rejected explicitly. No Area table, membership or role is consulted.

begin;

create or replace function public.can_read_activity(p_id uuid) returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select exists (select 1 from public.activities a
    where a.id = p_id and a.owner_account_id = public.current_account_id())
$$;

create or replace function public.get_visible_activities() returns setof jsonb
language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select to_jsonb(a) from public.activities a
  where a.owner_account_id = public.current_account_id()
  order by coalesce(a.due_at, a.starts_at), a.created_at
$$;

create or replace function public.create_activity(
  p_title text, p_description text default null, p_area_id uuid default null,
  p_starts_at timestamptz default null, p_due_at timestamptz default null,
  p_is_all_day boolean default false, p_priority public.priority_level default 'normal',
  p_recurrence jsonb default '{}'::jsonb, p_activity_type text default 'task'
) returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_owner uuid := public.require_current_account(); v_id uuid;
begin
  if p_area_id is not null then raise exception 'Area activities are retired'; end if;
  insert into public.activities (
    owner_account_id, title, description, activity_type, starts_at, due_at, is_all_day, priority,
    recurrence_frequency, recurrence_interval, recurrence_weekdays, recurrence_until,
    recurrence_timezone, created_by_account_id
  ) values (
    v_owner, nullif(btrim(p_title), ''), nullif(btrim(p_description), ''),
    coalesce(nullif(btrim(p_activity_type), ''), 'task'), p_starts_at, p_due_at,
    coalesce(p_is_all_day, false), coalesce(p_priority, 'normal'),
    nullif(p_recurrence->>'frequency', ''), nullif(p_recurrence->>'interval', '')::smallint,
    array(select jsonb_array_elements_text(coalesce(p_recurrence->'weekdays','[]'))::smallint),
    nullif(p_recurrence->>'until', '')::date, nullif(p_recurrence->>'timezone', ''), v_owner
  ) returning id into v_id;
  return v_id;
end $$;

create or replace function public.update_activity(
  p_activity_id uuid, p_title text, p_description text default null,
  p_starts_at timestamptz default null, p_due_at timestamptz default null,
  p_is_all_day boolean default false, p_priority public.priority_level default 'normal',
  p_recurrence jsonb default '{}'::jsonb, p_activity_type text default 'task'
) returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v public.activities%rowtype;
begin
  select * into v from public.activities where id = p_activity_id for update;
  if not found or v.owner_account_id <> public.require_current_account() then raise exception 'permission denied'; end if;
  update public.activities set
    title = nullif(btrim(p_title), ''), description = nullif(btrim(p_description), ''),
    activity_type = coalesce(nullif(btrim(p_activity_type), ''), 'task'), starts_at = p_starts_at,
    due_at = p_due_at, is_all_day = coalesce(p_is_all_day, false), priority = coalesce(p_priority, 'normal'),
    recurrence_frequency = nullif(p_recurrence->>'frequency', ''),
    recurrence_interval = nullif(p_recurrence->>'interval', '')::smallint,
    recurrence_weekdays = array(select jsonb_array_elements_text(coalesce(p_recurrence->'weekdays','[]'))::smallint),
    recurrence_until = nullif(p_recurrence->>'until', '')::date,
    recurrence_timezone = nullif(p_recurrence->>'timezone', '')
  where id = p_activity_id returning * into v;
  return to_jsonb(v);
end $$;

create or replace function public.delete_activity(p_activity_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  delete from public.activities where id = p_activity_id and owner_account_id = public.require_current_account();
  if not found then raise exception 'permission denied'; end if;
end $$;

create or replace function public.set_activity_status(p_activity_id uuid, p_status public.activity_status) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_actor uuid := public.require_current_account();
begin
  update public.activities set status = p_status,
    completed_by_account_id = case when p_status = 'completed' then v_actor else null end,
    completed_at = case when p_status = 'completed' then now() else null end
  where id = p_activity_id and owner_account_id = v_actor;
  if not found then raise exception 'permission denied'; end if;
end $$;

create or replace function public.can_read_list(p_list_id uuid) returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select exists (select 1 from public.lists l where l.id = p_list_id and
    (l.owner_account_id = public.current_account_id() or exists (
      select 1 from public.list_participants lp where lp.list_id = l.id and lp.account_id = public.current_account_id())))
$$;
create or replace function public.can_edit_list_items(p_list_id uuid) returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp' as $$ select public.can_read_list(p_list_id) $$;
create or replace function public.can_manage_list(p_list_id uuid) returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select exists (select 1 from public.lists l where l.id = p_list_id and l.owner_account_id = public.current_account_id())
$$;

create or replace function public.create_list(p_title text, p_description text default null, p_area_id uuid default null)
returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_owner uuid := public.require_current_account(); v_id uuid;
begin
  if p_area_id is not null then raise exception 'Area lists are retired'; end if;
  insert into public.lists(owner_account_id, title, description, created_by_account_id)
  values(v_owner, nullif(btrim(p_title), ''), nullif(btrim(p_description), ''), v_owner) returning id into v_id;
  return v_id;
end $$;

create or replace function public.get_visible_lists() returns setof jsonb
language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select to_jsonb(l) || jsonb_build_object(
    'can_edit_items', public.can_edit_list_items(l.id),
    'can_manage_list', public.can_manage_list(l.id),
    'is_shared', exists(select 1 from public.list_participants lp where lp.list_id = l.id)
  ) from public.lists l where public.can_read_list(l.id) order by l.updated_at desc
$$;

create or replace function public.event_visibility_source(p_event_id uuid) returns text
language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select coalesce(public.event_personal_source(p_event_id, public.current_account_id()),
    case when public.event_is_suggested(p_event_id, public.current_account_id()) then 'suggestion' end)
$$;
create or replace function public.require_event_manage_scope(p_event_id uuid) returns table(owner_account_id uuid)
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_event public.events%rowtype;
begin
  select * into v_event from public.events where id = p_event_id;
  if not found or v_event.event_kind = 'commitment' or v_event.owner_account_id is null
     or v_event.owner_account_id <> public.require_current_account() then raise exception 'permission denied'; end if;
  return query select v_event.owner_account_id;
end $$;
create or replace function public.assert_event_participant_contact_scope() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_owner uuid; v_kind text;
begin
  select owner_account_id, event_kind into v_owner, v_kind from public.events where id = new.event_id;
  if not found or v_kind = 'commitment' then raise exception 'event participants are unavailable for commitments'; end if;
  if new.contact_id is not null and not exists (select 1 from public.contacts c where c.id = new.contact_id and c.owner_account_id = v_owner) then
    raise exception 'event participant contact is outside event owner address book';
  end if;
  if new.profile_id is not null and not exists (select 1 from public.contact_profile_links l where l.contact_id = new.contact_id and l.profile_id = new.profile_id) then
    raise exception 'participant profile is not linked to contact';
  end if;
  return new;
end $$;

create or replace function public.get_my_pending_invites_count() returns integer
language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_recipient record; v_account_id uuid := public.require_current_account();
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();
  return ((select count(*) from public.family_invites fi where fi.recipient_email = v_recipient.email and fi.status = 'pending' and (fi.expires_at is null or fi.expires_at > now())) +
    (select count(*) from public.event_invites ei where ei.recipient_email = v_recipient.email and ei.status = 'pending' and ei.expires_at > now()) +
    (select count(*) from public.contact_suggestions cs where cs.recipient_email = v_recipient.email and cs.status = 'pending' and cs.expires_at > now()) +
    (select count(*) from public.contact_shares cs where cs.recipient_email = v_recipient.email and cs.status = 'pending' and cs.expires_at > now()) +
    (select count(*) from public.list_invites li join public.lists l on l.id = li.list_id where li.recipient_account_id = v_account_id and li.status = 'pending' and l.owner_account_id is not null) +
    (select count(*) from public.deadline_collaborations dc where dc.recipient_account_id = v_account_id and dc.status = 'pending'))::integer;
end $$;

-- Replacing a function preserves its ACL and owner. Verify them again before
-- execution; the remote definitions are SECURITY DEFINER, postgres-owned and
-- executable by authenticated only.
commit;
