-- FamilArea — enable invitation-only participants for personal generic Events.
--
-- This patch intentionally leaves Area Events on their existing management
-- model.  A personal Event is managed only by events.owner_account_id;
-- commitments are never an inviteable Event type.

begin;

-- Shared management scope used by the existing participant and invite RPCs.
-- The return value remains the address-book owner expected by those RPCs.
create or replace function public.require_event_manage_scope(p_event_id uuid)
returns table(owner_account_id uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event public.events%rowtype;
  v_area_owner_account_id uuid;
begin
  select *
  into v_event
  from public.events
  where id = p_event_id;

  if not found or v_event.event_kind = 'commitment' then
    raise exception 'permission denied';
  end if;

  if v_event.area_id is null then
    if v_event.owner_account_id is null
       or v_event.owner_account_id is distinct from public.require_current_account() then
      raise exception 'permission denied';
    end if;

    return query select v_event.owner_account_id;
    return;
  end if;

  select a.owner_account_id
  into v_area_owner_account_id
  from public.areas a
  where a.id = v_event.area_id;

  if v_area_owner_account_id is null
     or not public.can_manage_area(v_event.area_id) then
    raise exception 'permission denied';
  end if;

  return query select v_area_owner_account_id;
end;
$$;

-- The participant trigger is the integrity boundary for every write path,
-- including token acceptance.  A Contact must belong to the personal owner for
-- personal Events, or to the Area owner for existing Area Events.
create or replace function public.assert_event_participant_contact_scope()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_area_id uuid;
  v_personal_owner_account_id uuid;
  v_area_owner_account_id uuid;
  v_event_kind text;
  v_contact_owner_account_id uuid;
begin
  select e.area_id,
         e.owner_account_id,
         a.owner_account_id,
         e.event_kind
  into v_area_id,
       v_personal_owner_account_id,
       v_area_owner_account_id,
       v_event_kind
  from public.events e
  left join public.areas a on a.id = e.area_id
  where e.id = new.event_id;

  if not found or v_event_kind = 'commitment' then
    raise exception 'event participants are unavailable for commitments';
  end if;

  if new.contact_id is null then
    return new;
  end if;

  v_contact_owner_account_id := case
    when v_area_id is null then v_personal_owner_account_id
    else v_area_owner_account_id
  end;

  if v_contact_owner_account_id is null or not exists (
    select 1
    from public.contacts c
    where c.id = new.contact_id
      and c.owner_account_id = v_contact_owner_account_id
  ) then
    raise exception 'event participant contact is outside event owner address book';
  end if;

  if new.profile_id is not null and not exists (
    select 1
    from public.contact_profile_links l
    where l.contact_id = new.contact_id
      and l.profile_id = new.profile_id
  ) then
    raise exception 'participant profile is not linked to contact';
  end if;

  return new;
end;
$$;

-- These direct-participant RPCs are retained for existing Area Events only.
-- Personal Events must use the pending invitation flow so the recipient's
-- verified-email acceptance remains mandatory.
create or replace function public.add_event_participant(
  p_event_id uuid,
  p_contact_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope record;
  v_primary_email text;
  v_primary_email_count integer;
  v_profile_id uuid;
  v_matching_profile_count integer;
begin
  select * into v_scope
  from public.require_event_manage_scope(p_event_id);

  if exists (
    select 1
    from public.events e
    where e.id = p_event_id
      and e.area_id is null
  ) then
    raise exception 'personal event participants must accept an event invite';
  end if;

  if not exists (
    select 1
    from public.contacts c
    where c.id = p_contact_id
      and c.owner_account_id = v_scope.owner_account_id
  ) then
    raise exception 'contact is outside event owner address book';
  end if;

  select
    count(*) filter (where cm.method_type = 'email' and cm.is_primary),
    min(lower(btrim(cm.value))) filter (where cm.method_type = 'email' and cm.is_primary)
  into v_primary_email_count, v_primary_email
  from public.contacts c
  left join public.contact_methods cm on cm.contact_id = c.id
  where c.id = p_contact_id
    and c.owner_account_id = v_scope.owner_account_id;

  select l.profile_id into v_profile_id
  from public.contact_profile_links l
  where l.contact_id = p_contact_id;

  if v_profile_id is null
     and v_primary_email_count = 1
     and nullif(v_primary_email, '') is not null then
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

create or replace function public.set_event_participants(
  p_event_id uuid,
  p_profile_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope record;
  v_profile_ids uuid[] := coalesce(p_profile_ids, '{}');
begin
  select * into v_scope
  from public.require_event_manage_scope(p_event_id);

  if exists (
    select 1
    from public.events e
    where e.id = p_event_id
      and e.area_id is null
  ) then
    raise exception 'personal event participants must accept an event invite';
  end if;

  if array_position(v_profile_ids, null) is not null then
    raise exception 'invalid participant';
  end if;

  if exists (
    select 1
    from (select distinct unnest(v_profile_ids) as profile_id) selected
    where not exists (
      select 1
      from public.contact_profile_links l
      join public.contacts c on c.id = l.contact_id
      where l.owner_account_id = v_scope.owner_account_id
        and l.profile_id = selected.profile_id
        and c.owner_account_id = v_scope.owner_account_id
    )
  ) then
    raise exception 'participant must be linked to an Event owner Contact';
  end if;

  update public.event_participants ep
  set status = 'removed',
      updated_at = now()
  where ep.event_id = p_event_id
    and ep.status = 'active'
    and ep.added_via = 'direct'
    and ep.profile_id is not null
    and exists (
      select 1
      from public.contact_profile_links l
      where l.owner_account_id = v_scope.owner_account_id
        and l.profile_id = ep.profile_id
    )
    and not (ep.profile_id = any(v_profile_ids));

  insert into public.event_participants (
    event_id,
    contact_id,
    profile_id,
    status,
    added_via,
    added_by_account_id
  )
  select p_event_id,
         l.contact_id,
         l.profile_id,
         'active',
         'direct',
         public.require_current_account()
  from (select distinct unnest(v_profile_ids) as profile_id) selected
  join public.contact_profile_links l
    on l.profile_id = selected.profile_id
   and l.owner_account_id = v_scope.owner_account_id
  join public.contacts c
    on c.id = l.contact_id
   and c.owner_account_id = v_scope.owner_account_id
  on conflict (event_id, contact_id) do update
    set profile_id = excluded.profile_id,
        status = 'active',
        added_via = 'direct',
        added_by_account_id = excluded.added_by_account_id,
        updated_at = now();
end;
$$;

-- A commitment must remain private even if historical participant rows appear
-- later. Owners and creators retain their existing commitment visibility.
create or replace function public.event_personal_source(
  p_event_id uuid,
  p_account_id uuid
)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when p_account_id is null then null
    when e.owner_account_id = p_account_id then 'owner'
    when e.area_id is null and e.created_by_account_id = p_account_id then 'creator'
    when e.event_kind is distinct from 'commitment'
      and exists (
        select 1
        from public.event_participants ep
        where ep.event_id = e.id
          and ep.status = 'active'
          and (
            exists (
              select 1
              from public.profiles p
              where p.id = ep.profile_id
                and p.account_id = p_account_id
            )
            or exists (
              select 1
              from public.contact_profile_links l
              join public.profiles p on p.id = l.profile_id
              where l.contact_id = ep.contact_id
                and p.account_id = p_account_id
            )
          )
      ) then 'participant'
    else null
  end
  from public.events e
  where e.id = p_event_id;
$$;

commit;

-- Manual verification after authorised deployment (run separately, never as
-- application data migration):
--
-- 1) As the personal Event owner, create_event_invite_for_contact succeeds.
-- 2) As another account, all management RPCs above fail with permission denied.
-- 3) As the recipient before acceptance, get_event(event_id) fails.
-- 4) After accept_event_invite(token), get_event(event_id) succeeds with
--    visibility_source = 'participant' and can_manage = false.
-- 5) As the participant, update_event/delete_event and every management RPC fail.
-- 6) For an Event with event_kind = 'commitment', every participant/invite RPC
--    above fails; the owner still reads and edits the commitment normally.
-- 7) Existing Area-event direct participant and invite flows remain unchanged.
