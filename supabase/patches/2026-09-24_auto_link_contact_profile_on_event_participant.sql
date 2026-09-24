-- FamilArea — Contact-first event participants: private verified Profile matching.
--
-- This is deliberately limited to the authorised add_event_participant operation.
-- It does not expose a profile lookup, create invitations, change contacts, or add
-- AreaMemberships. A Contact remains the primary participant identity.

create or replace function public.add_event_participant(
  p_event_id uuid,
  p_contact_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_scope record;
  v_primary_email text;
  v_primary_email_count integer;
  v_profile_id uuid;
  v_matching_profile_count integer;
begin
  -- Authorisation is checked before reading the caller's private Contact.
  select * into v_scope
  from public.require_event_manage_scope(p_event_id);

  if not exists (
    select 1
    from public.contacts c
    where c.id = p_contact_id
      and c.owner_account_id = v_scope.owner_account_id
  ) then
    raise exception 'contact is outside event owner address book';
  end if;

  -- The Contact must belong to the event owner's private address book.  Requiring
  -- exactly one primary email prevents a caller from choosing among ambiguous data.
  select
    count(*) filter (where cm.method_type = 'email' and cm.is_primary),
    min(lower(btrim(cm.value))) filter (where cm.method_type = 'email' and cm.is_primary)
  into v_primary_email_count, v_primary_email
  from public.contacts c
  left join public.contact_methods cm on cm.contact_id = c.id
  where c.id = p_contact_id
    and c.owner_account_id = v_scope.owner_account_id;

  -- Preserve a link created by an existing authorised flow.  No profile discovery
  -- is performed once a Contact already has a link.
  select l.profile_id into v_profile_id
  from public.contact_profile_links l
  where l.contact_id = p_contact_id;

  if v_profile_id is null
     and v_primary_email_count = 1
     and nullif(v_primary_email, '') is not null then
    -- Only a verified, personal FamilArea account with exactly one matching Profile
    -- is eligible.  This is an internal side effect: no identity is returned to the
    -- caller except through the existing participant response.
    select count(*), min(p.id::text)::uuid
    into v_matching_profile_count, v_profile_id
    from auth.users u
    join public.accounts a
      on a.auth_user_id = u.id
     and a.account_type = 'personal'
    join public.profiles p on p.account_id = a.id
    where u.email_confirmed_at is not null
      and lower(btrim(coalesce(u.email, ''))) = v_primary_email;

    if v_matching_profile_count <> 1 then
      v_profile_id := null;
    else
      -- Both unique constraints on contact_profile_links are intentionally handled:
      -- a concurrent/other Contact link simply leaves this Contact unlinked.
      insert into public.contact_profile_links (
        contact_id,
        owner_account_id,
        profile_id,
        linked_via
      )
      values (
        p_contact_id,
        v_scope.owner_account_id,
        v_profile_id,
        'verified'
      )
      on conflict do nothing;

      select l.profile_id into v_profile_id
      from public.contact_profile_links l
      where l.contact_id = p_contact_id;
    end if;
  end if;

  -- Do not fail or reveal another Contact's identity if this Profile is already a
  -- participant for the same event under a different Contact.
  if v_profile_id is not null and exists (
    select 1
    from public.event_participants ep
    where ep.event_id = p_event_id
      and ep.profile_id = v_profile_id
      and ep.contact_id <> p_contact_id
  ) then
    v_profile_id := null;
  end if;

  insert into public.event_participants (
    event_id,
    contact_id,
    profile_id,
    status,
    added_via,
    added_by_account_id
  )
  values (
    p_event_id,
    p_contact_id,
    v_profile_id,
    'active',
    'direct',
    public.require_current_account()
  )
  on conflict (event_id, contact_id) do update
  set status = 'active',
      profile_id = coalesce(event_participants.profile_id, excluded.profile_id),
      updated_at = now();

  return jsonb_build_object(
    'event_id', p_event_id,
    'contact_id', p_contact_id
  );
end;
$$;

revoke all on function public.add_event_participant(uuid, uuid) from public, anon;
grant execute on function public.add_event_participant(uuid, uuid) to authenticated;
alter function public.add_event_participant(uuid, uuid) owner to postgres;

-- Profile identities are internal implementation data.  The event-management UI
-- uses Contact identifiers exclusively, so do not return a matched Profile through
-- its read or mutation RPCs.
create or replace function public.get_event_participants(p_event_id uuid)
returns setof jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_scope record;
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);

  return query
  select jsonb_build_object(
    'contact_id', c.id,
    'first_name', c.first_name,
    'last_name', c.last_name,
    'status', ep.status,
    'added_via', ep.added_via
  )
  from public.event_participants ep
  join public.contacts c on c.id = ep.contact_id
  where ep.event_id = p_event_id
    and ep.status = 'active'
  order by lower(c.first_name), lower(coalesce(c.last_name, ''));
end;
$$;

create or replace function public.get_my_contacts_for_event(p_event_id uuid)
returns setof jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_scope record;
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);

  return query
  select jsonb_build_object(
    'contact_id', c.id,
    'first_name', c.first_name,
    'last_name', c.last_name,
    'is_active_participant', exists (
      select 1
      from public.event_participants ep
      where ep.event_id = p_event_id
        and ep.contact_id = c.id
        and ep.status = 'active'
    )
  )
  from public.contacts c
  where c.owner_account_id = v_scope.owner_account_id
  order by lower(c.first_name), lower(coalesce(c.last_name, ''));
end;
$$;

revoke all on function public.get_event_participants(uuid) from public, anon;
revoke all on function public.get_my_contacts_for_event(uuid) from public, anon;
grant execute on function public.get_event_participants(uuid) to authenticated;
grant execute on function public.get_my_contacts_for_event(uuid) to authenticated;
alter function public.get_event_participants(uuid) owner to postgres;
alter function public.get_my_contacts_for_event(uuid) owner to postgres;
