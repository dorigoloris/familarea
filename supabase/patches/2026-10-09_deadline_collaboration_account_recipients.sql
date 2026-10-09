-- FamilArea — account-based recipients for view-only deadline collaborations.
-- Prerequisites:
--   2026-10-07_deadline_collaborations_v1.sql
--   2026-10-08_contact_share_organization_senders.sql
--   2026-10-09_shared_deadline_calendar.sql
-- Deadline ownership remains personal. Only the recipient endpoint becomes
-- account-based, and is still limited to the owner's linked Contacts.

begin;

create or replace function public.assert_deadline_collaboration_integrity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from public.deadlines d
    where d.id = new.deadline_id
      and d.owner_account_id = new.owner_account_id
  ) then
    raise exception 'deadline collaboration owner does not match deadline owner';
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.id = new.owner_account_id and a.account_type = 'personal'
  ) or not exists (
    select 1 from public.accounts a
    where a.id = new.recipient_account_id
      and a.account_type in ('personal', 'organization')
  ) then
    raise exception 'deadline collaboration owner must be personal and recipient must be an eligible account';
  end if;

  return new;
end;
$$;

create or replace function public.search_invitable_deadline_accounts(
  p_deadline_id uuid,
  p_query text
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
  v_query text := lower(btrim(coalesce(p_query, '')));
begin
  perform 1
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id;
  if not found then raise exception 'permission denied'; end if;

  if v_query = '' then return; end if;

  return query
  with linked_contact_accounts as (
    select cal.linked_account_id as account_id
    from public.contacts c
    join public.contact_account_links cal
      on cal.contact_id = c.id
     and cal.owner_account_id = v_owner_account_id
    where c.owner_account_id = v_owner_account_id

    union

    select p.account_id
    from public.contacts c
    join public.contact_profile_links cpl
      on cpl.contact_id = c.id
     and cpl.owner_account_id = v_owner_account_id
    join public.profiles p on p.id = cpl.profile_id
    where c.owner_account_id = v_owner_account_id
  )
  select jsonb_build_object(
    'account_id', identity.account_id,
    'display_name', identity.display_name,
    'avatar_path', identity.avatar_path,
    'account_type', identity.account_type
  )
  from linked_contact_accounts linked
  join lateral public.contact_share_sender_identity(linked.account_id) identity on true
  where linked.account_id <> v_owner_account_id
    and (
      lower(identity.display_name) like '%' || v_query || '%'
      or lower(identity.email) like '%' || v_query || '%'
    )
    and not exists (
      select 1
      from public.deadline_collaborations dc
      where dc.deadline_id = p_deadline_id
        and dc.recipient_account_id = linked.account_id
        and dc.status in ('pending', 'accepted')
    )
  order by identity.display_name, identity.account_id
  limit 5;
end;
$$;

create or replace function public.create_deadline_collaboration(
  p_deadline_id uuid,
  p_recipient_account_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
  v_collaboration_id uuid;
begin
  perform 1
  from public.deadlines d
  where d.id = p_deadline_id
    and d.owner_account_id = v_owner_account_id
  for update;
  if not found then raise exception 'permission denied'; end if;

  if p_recipient_account_id = v_owner_account_id then
    raise exception 'cannot invite deadline owner';
  end if;

  if not exists (
    with linked_contact_accounts as (
      select cal.linked_account_id as account_id
      from public.contacts c
      join public.contact_account_links cal
        on cal.contact_id = c.id
       and cal.owner_account_id = v_owner_account_id
      where c.owner_account_id = v_owner_account_id

      union

      select p.account_id
      from public.contacts c
      join public.contact_profile_links cpl
        on cpl.contact_id = c.id
       and cpl.owner_account_id = v_owner_account_id
      join public.profiles p on p.id = cpl.profile_id
      where c.owner_account_id = v_owner_account_id
    )
    select 1
    from linked_contact_accounts linked
    join lateral public.contact_share_sender_identity(linked.account_id) identity on true
    where linked.account_id = p_recipient_account_id
  ) then
    raise exception 'recipient is not an invitable linked contact';
  end if;

  if exists (
    select 1
    from public.deadline_collaborations dc
    where dc.deadline_id = p_deadline_id
      and dc.recipient_account_id = p_recipient_account_id
      and dc.status in ('pending', 'accepted')
  ) then
    raise exception 'active deadline collaboration already exists';
  end if;

  insert into public.deadline_collaborations(
    deadline_id, owner_account_id, recipient_account_id
  ) values (
    p_deadline_id, v_owner_account_id, p_recipient_account_id
  ) returning id into v_collaboration_id;

  return v_collaboration_id;
end;
$$;

create or replace function public.get_deadline_collaboration_management(
  p_deadline_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_personal_account();
begin
  if not exists (
    select 1 from public.deadlines d
    where d.id = p_deadline_id and d.owner_account_id = v_owner_account_id
  ) then
    raise exception 'permission denied';
  end if;

  return jsonb_build_object(
    'deadline_id', p_deadline_id,
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
        'collaboration_id', dc.id,
        'recipient_account_id', dc.recipient_account_id,
        'display_name', recipient.display_name,
        'avatar_path', recipient.avatar_path,
        'account_type', recipient.account_type,
        'created_at', dc.created_at,
        'status', dc.status
      ) order by dc.created_at, dc.id)
      from public.deadline_collaborations dc
      join lateral public.contact_share_sender_identity(dc.recipient_account_id) recipient on true
      where dc.deadline_id = p_deadline_id and dc.status = 'pending'
    ), '[]'::jsonb),
    'collaborators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'collaboration_id', dc.id,
        'account_id', dc.recipient_account_id,
        'display_name', recipient.display_name,
        'avatar_path', recipient.avatar_path,
        'account_type', recipient.account_type,
        'accepted_at', dc.accepted_at,
        'status', dc.status
      ) order by dc.accepted_at, dc.id)
      from public.deadline_collaborations dc
      join lateral public.contact_share_sender_identity(dc.recipient_account_id) recipient on true
      where dc.deadline_id = p_deadline_id and dc.status = 'accepted'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.revoke_deadline_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_current_account();
begin
  update public.deadline_collaborations dc
  set status = 'revoked', revoked_at = now()
  where dc.id = p_collaboration_id
    and dc.status = 'accepted'
    and v_actor_account_id in (dc.owner_account_id, dc.recipient_account_id);
  if not found then raise exception 'collaboration not found or not revocable'; end if;
end;
$$;

create or replace function public.get_my_deadline_collaboration_invites()
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'collaboration_id', dc.id,
    'deadline_id', dc.deadline_id,
    'title', d.title,
    'category', d.category,
    'first_due_on', d.first_due_on,
    'invited_by_account_id', dc.owner_account_id,
    'inviter_display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
    'inviter_avatar_path', p.avatar_path,
    'status', dc.status,
    'created_at', dc.created_at
  )
  from public.deadline_collaborations dc
  join public.deadlines d on d.id = dc.deadline_id
  join public.profiles p on p.account_id = dc.owner_account_id
  where dc.recipient_account_id = public.require_current_account()
    and dc.status = 'pending'
  order by dc.created_at desc, dc.id
$$;

create or replace function public.accept_my_deadline_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_current_account();
begin
  update public.deadline_collaborations dc
  set status = 'accepted', accepted_at = now()
  where dc.id = p_collaboration_id
    and dc.recipient_account_id = v_actor_account_id
    and dc.status = 'pending';
  if not found then raise exception 'collaboration invitation unavailable'; end if;
end;
$$;

create or replace function public.decline_my_deadline_collaboration(
  p_collaboration_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_current_account();
begin
  update public.deadline_collaborations dc
  set status = 'declined', declined_at = now()
  where dc.id = p_collaboration_id
    and dc.recipient_account_id = v_actor_account_id
    and dc.status = 'pending';
  if not found then raise exception 'collaboration invitation unavailable'; end if;
end;
$$;

create or replace function public.get_shared_deadline(
  p_deadline_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_account_id uuid := public.require_current_account();
  v_result jsonb;
begin
  select public.deadline_collaboration_view_projection(dc.deadline_id)
    || jsonb_build_object(
      'collaboration_id', dc.id,
      'owner_display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
      'owner_avatar_path', p.avatar_path,
      'access', 'view'
    )
  into v_result
  from public.deadline_collaborations dc
  join public.profiles p on p.account_id = dc.owner_account_id
  where dc.deadline_id = p_deadline_id
    and dc.recipient_account_id = v_actor_account_id
    and dc.status = 'accepted';

  if v_result is null then raise exception 'shared deadline unavailable'; end if;
  return v_result;
end;
$$;

create or replace function public.get_my_shared_deadlines()
returns setof jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.deadline_collaboration_view_projection(dc.deadline_id)
    || jsonb_build_object(
      'collaboration_id', dc.id,
      'owner_account_id', dc.owner_account_id,
      'owner_display_name', btrim(concat_ws(' ', p.first_name, p.last_name)),
      'owner_avatar_path', p.avatar_path,
      'access', 'view',
      'accepted_at', dc.accepted_at
    )
  from public.deadline_collaborations dc
  join public.profiles p on p.account_id = dc.owner_account_id
  where dc.recipient_account_id = public.require_current_account()
    and dc.status = 'accepted'
  order by dc.accepted_at desc, dc.id
$$;

create or replace function public.get_my_shared_deadline_calendar_occurrences(
  p_from timestamptz,
  p_to timestamptz
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
  v_to_date date := (p_to - interval '1 microsecond')::date;
begin
  if p_to <= p_from then raise exception 'invalid occurrence range'; end if;

  return query
  select jsonb_build_object(
    'kind', 'deadline',
    'deadline_id', d.id,
    'title', d.title,
    'category', d.category,
    'due_on', occurrence.occurrence_on,
    'occurs_on', occurrence.occurrence_on,
    'all_day', d.start_time is null,
    'starts_at', case when d.start_time is null then null else occurrence.occurrence_on::date + d.start_time end,
    'ends_at', case when d.end_time is null then null else occurrence.occurrence_on::date + d.end_time end,
    'status', d.status,
    'is_completed', false,
    'calendar_deadline_access', 'shared',
    'calendar_shared_deadline', true,
    'calendar_owner_account_id', dc.owner_account_id,
    'calendar_is_shared', true,
    'calendar_owner_display_name', nullif(btrim(concat_ws(' ', owner_profile.first_name, owner_profile.last_name)), '')
  )
  from public.deadline_collaborations dc
  join public.deadlines d on d.id = dc.deadline_id
  join public.profiles owner_profile on owner_profile.account_id = dc.owner_account_id
  cross join lateral generate_series(
    d.first_due_on,
    least(coalesce(d.terminated_on, v_to_date), v_to_date),
    make_interval(months => coalesce(d.recurrence_months, 1200))
  ) occurrence(occurrence_on)
  where dc.recipient_account_id = v_recipient_account_id
    and dc.status = 'accepted'
    and d.status = 'active'
    and public.is_resolved_personal_document_deadline(d.id)
    and occurrence.occurrence_on between p_from::date and v_to_date;
end;
$$;

create or replace function public.get_my_pending_invites_count()
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_account_id uuid := public.require_current_account();
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();

  if v_recipient.account_type = 'organization' then
    return (
      (select count(*)
       from public.contact_shares cs
       where cs.recipient_email = v_recipient.email
         and cs.status = 'pending'
         and cs.expires_at > now())
      +
      (select count(*)
       from public.deadline_collaborations dc
       where dc.recipient_account_id = v_account_id
         and dc.status = 'pending')
    )::integer;
  end if;

  return (
    (select count(*)
     from public.area_invites i
     join public.areas a on a.id = i.area_id
     join auth.users u on u.id = auth.uid()
     where lower(i.invitee_email) = lower(coalesce(u.email, ''))
       and i.status = 'pending'
       and (i.expires_at is null or i.expires_at > now()))
    +
    (select count(*)
     from public.family_invites fi
     join public.families f on f.id = fi.family_id
     join public.family_members fm on fm.id = fi.family_member_id
       and fm.family_id = fi.family_id
     where fi.recipient_email = v_recipient.email
       and fi.status = 'pending'
       and (fi.expires_at is null or fi.expires_at > now()))
    +
    (select count(*)
     from public.event_invites ei
     join public.events e on e.id = ei.event_id
     where ei.recipient_email = v_recipient.email
       and ei.status = 'pending'
       and ei.expires_at > now())
    +
    (select count(*)
     from public.contact_suggestions cs
     join public.profiles suggested_profile on suggested_profile.id = cs.suggested_profile_id
     where cs.recipient_email = v_recipient.email
       and cs.status = 'pending'
       and cs.expires_at > now())
    +
    (select count(*)
     from public.contact_shares cs
     where cs.recipient_email = v_recipient.email
       and cs.status = 'pending'
       and cs.expires_at > now())
    +
    (select count(*)
     from public.list_invites li
     join public.lists l on l.id = li.list_id
     where li.recipient_account_id = v_account_id
       and li.status = 'pending'
       and l.owner_account_id is not null
       and l.area_id is null)
    +
    (select count(*)
     from public.deadline_collaborations dc
     where dc.recipient_account_id = v_account_id
       and dc.status = 'pending')
  )::integer;
end;
$$;

alter function public.assert_deadline_collaboration_integrity() owner to postgres;
alter function public.search_invitable_deadline_accounts(uuid, text) owner to postgres;
alter function public.create_deadline_collaboration(uuid, uuid) owner to postgres;
alter function public.get_deadline_collaboration_management(uuid) owner to postgres;
alter function public.revoke_deadline_collaboration(uuid) owner to postgres;
alter function public.get_my_deadline_collaboration_invites() owner to postgres;
alter function public.accept_my_deadline_collaboration(uuid) owner to postgres;
alter function public.decline_my_deadline_collaboration(uuid) owner to postgres;
alter function public.get_shared_deadline(uuid) owner to postgres;
alter function public.get_my_shared_deadlines() owner to postgres;
alter function public.get_my_shared_deadline_calendar_occurrences(timestamptz, timestamptz) owner to postgres;
alter function public.get_my_pending_invites_count() owner to postgres;

revoke all on function public.search_invitable_deadline_accounts(uuid,text), public.create_deadline_collaboration(uuid,uuid), public.get_deadline_collaboration_management(uuid), public.revoke_deadline_collaboration(uuid), public.get_my_deadline_collaboration_invites(), public.accept_my_deadline_collaboration(uuid), public.decline_my_deadline_collaboration(uuid), public.get_shared_deadline(uuid), public.get_my_shared_deadlines(), public.get_my_shared_deadline_calendar_occurrences(timestamptz,timestamptz) from public, anon;
grant execute on function public.search_invitable_deadline_accounts(uuid,text), public.create_deadline_collaboration(uuid,uuid), public.get_deadline_collaboration_management(uuid), public.revoke_deadline_collaboration(uuid), public.get_my_deadline_collaboration_invites(), public.accept_my_deadline_collaboration(uuid), public.decline_my_deadline_collaboration(uuid), public.get_shared_deadline(uuid), public.get_my_shared_deadlines(), public.get_my_shared_deadline_calendar_occurrences(timestamptz,timestamptz) to authenticated;

revoke all on function public.get_my_pending_invites_count() from public, anon;
grant execute on function public.get_my_pending_invites_count() to authenticated;

commit;
