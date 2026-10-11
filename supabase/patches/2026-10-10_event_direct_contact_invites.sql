-- FamilArea — verified account-linked Contact selection for non-Area Events.
--
-- Area Event behaviour remains unchanged. For an Event with no area_id,
-- invitation creation is permitted only for a Contact explicitly linked to
-- exactly one verified Personal or Organization account whose verified email
-- is the Contact email used for the invitation.

begin;

-- Internal, account-safe identity projection. It deliberately returns no
-- profile id and no extra Contact data: callers only need the account target,
-- its type and the verified matching email.
create or replace function public.event_invite_verified_recipient_for_contact(
  p_owner_account_id uuid,
  p_contact_id uuid
)
returns table(
  recipient_account_id uuid,
  recipient_account_type text,
  recipient_email text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with primary_contact_email as (
    select lower(btrim(coalesce(cm.value, ''))) as raw_email
    from public.contact_methods cm
    where cm.contact_id = p_contact_id
      and cm.method_type = 'email'
    order by cm.is_primary desc, cm.id
    limit 1
  ), contact_email as (
    -- This is the same normalization and validity rule as
    -- normalize_contact_email(), expressed only with non-throwing operators.
    -- The helper must silently exclude malformed historical Contact data.
    select pce.raw_email as email
    from primary_contact_email pce
    where pce.raw_email <> ''
      and position('@' in pce.raw_email) >= 2
      and position('.' in split_part(pce.raw_email, '@', 2)) > 0
  ), linked_accounts as (
    select p.account_id
    from public.contact_profile_links cpl
    join public.profiles p on p.id = cpl.profile_id
    join public.accounts a on a.id = p.account_id
    where cpl.contact_id = p_contact_id
      and cpl.owner_account_id = p_owner_account_id
      and a.account_type = 'personal'

    union

    select cal.linked_account_id
    from public.contact_account_links cal
    join public.accounts a on a.id = cal.linked_account_id
    where cal.contact_id = p_contact_id
      and cal.owner_account_id = p_owner_account_id
      and a.account_type = 'organization'
  )
  select
    a.id,
    a.account_type::text,
    ce.email
  from linked_accounts la
  join public.accounts a on a.id = la.account_id
  join auth.users u on u.id = a.auth_user_id
  cross join contact_email ce
  where u.email_confirmed_at is not null
    and lower(btrim(coalesce(u.email, ''))) = ce.email;
$$;

-- Preserve the existing signature and Area projection. Non-Area Events expose
-- only directly invitable, verified account-linked Contacts.
create or replace function public.get_my_contacts_for_event(p_event_id uuid)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope record;
  v_area_id uuid;
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);

  select e.area_id into v_area_id
  from public.events e
  where e.id = p_event_id;

  if v_area_id is not null then
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
    return;
  end if;

  return query
  with linked_contacts as (
    select
      c.id as contact_id,
      c.first_name,
      c.last_name,
      count(recipient.recipient_account_id) as recipient_count,
      min(recipient.recipient_account_id::text)::uuid as recipient_account_id,
      min(recipient.recipient_account_type) as recipient_account_type
    from public.contacts c
    cross join lateral public.event_invite_verified_recipient_for_contact(
      v_scope.owner_account_id,
      c.id
    ) recipient
    where c.owner_account_id = v_scope.owner_account_id
      and recipient.recipient_account_id <> v_scope.owner_account_id
    group by c.id, c.first_name, c.last_name
  )
  select jsonb_build_object(
    'contact_id', lc.contact_id,
    'first_name', lc.first_name,
    'last_name', lc.last_name,
    'recipient_account_id', lc.recipient_account_id,
    'recipient_account_type', lc.recipient_account_type,
    'is_active_participant', exists (
      select 1
      from public.event_participants ep
      where ep.event_id = p_event_id
        and ep.contact_id = lc.contact_id
        and ep.status = 'active'
    )
  )
  from linked_contacts lc
  where lc.recipient_count = 1
    and not exists (
      select 1
      from public.event_invites ei
      where ei.event_id = p_event_id
        and ei.contact_id = lc.contact_id
        and ei.status = 'pending'
        and ei.expires_at > now()
    )
  order by lower(lc.first_name), lower(coalesce(lc.last_name, ''));
end;
$$;

-- Keep the legacy email route for Area Events. For non-Area Events this
-- server-side guard is authoritative, including against manual RPC calls.
create or replace function public.create_event_invite(
  p_event_id uuid,
  p_recipient_email text,
  p_first_name text,
  p_last_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_scope record;
  v_area_id uuid;
  v_email text;
  v_contact uuid;
  v_existing_contacts integer;
  v_invite_id uuid;
  v_contact_first_name text;
  v_contact_last_name text;
  v_recipient_count integer;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);

  select e.area_id into v_area_id
  from public.events e
  where e.id = p_event_id;

  v_email := public.normalize_contact_email(p_recipient_email);

  update public.event_invites
  set status = 'expired'
  where event_id = p_event_id
    and recipient_email = v_email
    and status = 'pending'
    and expires_at <= now();

  select contact_id into v_contact
  from public.contact_email_identities
  where owner_account_id = v_scope.owner_account_id
    and normalized_email = v_email;

  if v_contact is null then
    select count(distinct c.id), min(c.id::text)::uuid
    into v_existing_contacts, v_contact
    from public.contacts c
    join public.contact_methods cm on cm.contact_id = c.id
    where c.owner_account_id = v_scope.owner_account_id
      and cm.method_type = 'email'
      and lower(btrim(cm.value)) = v_email;

    if v_existing_contacts > 1 then
      raise exception 'ambiguous contact email';
    end if;
  end if;

  if v_contact is null then
    if nullif(btrim(coalesce(p_first_name, '')), '') is null then
      raise exception 'first name is required';
    end if;

    insert into public.contacts (owner_account_id, first_name, last_name)
    values (v_scope.owner_account_id, btrim(p_first_name), nullif(btrim(coalesce(p_last_name, '')), ''))
    returning id into v_contact;
  end if;

  select first_name, last_name
  into v_contact_first_name, v_contact_last_name
  from public.contacts
  where id = v_contact;

  insert into public.contact_email_identities (owner_account_id, normalized_email, contact_id)
  values (v_scope.owner_account_id, v_email, v_contact)
  on conflict (owner_account_id, normalized_email) do nothing;

  if v_area_id is null then
    select count(*) into v_recipient_count
    from public.event_invite_verified_recipient_for_contact(
      v_scope.owner_account_id,
      v_contact
    ) recipient
    where recipient.recipient_account_id <> v_scope.owner_account_id
      and recipient.recipient_email = v_email;

    if v_recipient_count <> 1 then
      raise exception 'event invite contact is not linked to exactly one verified recipient account';
    end if;

    -- The selectable-contact query applies the same rule. Match it here so
    -- an email change cannot create a second live invitation for one Contact.
    -- Serialise concurrent requests for this Event/Contact pair as well.
    perform pg_advisory_xact_lock(hashtext(p_event_id::text || ':' || v_contact::text));

    if exists (
      select 1
      from public.event_invites ei
      where ei.event_id = p_event_id
        and ei.contact_id = v_contact
        and ei.status = 'pending'
        and ei.expires_at > now()
    ) then
      raise exception 'pending event invite already exists';
    end if;
  end if;

  if exists (
    select 1
    from public.event_participants
    where event_id = p_event_id and contact_id = v_contact and status = 'active'
  ) then
    raise exception 'contact already participates in this event';
  end if;

  if exists (
    select 1
    from public.event_invites
    where event_id = p_event_id and recipient_email = v_email and status = 'pending'
  ) then
    raise exception 'pending event invite already exists';
  end if;

  insert into public.event_invites (
    event_id, owner_account_id, contact_id, recipient_email,
    recipient_first_name, recipient_last_name, token_hash, expires_at,
    invited_by_account_id
  ) values (
    p_event_id, v_scope.owner_account_id, v_contact, v_email,
    v_contact_first_name, v_contact_last_name, public.hash_event_invite_token(v_token),
    now() + interval '14 days', public.require_current_account()
  ) returning id into v_invite_id;

  return jsonb_build_object('token', v_token, 'contact_id', v_contact, 'invite_id', v_invite_id);
end;
$$;

alter function public.event_invite_verified_recipient_for_contact(uuid, uuid) owner to postgres;
alter function public.get_my_contacts_for_event(uuid) owner to postgres;
alter function public.create_event_invite(uuid, text, text, text) owner to postgres;

revoke all on function public.event_invite_verified_recipient_for_contact(uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_my_contacts_for_event(uuid),
  public.create_event_invite(uuid, text, text, text) from public, anon;

grant execute on function public.get_my_contacts_for_event(uuid),
  public.create_event_invite(uuid, text, text, text) to authenticated;

commit;
