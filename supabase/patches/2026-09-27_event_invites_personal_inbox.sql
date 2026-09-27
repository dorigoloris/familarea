-- FamilArea — authenticated personal inbox actions for pending EventInvites.

create or replace function public.get_my_event_invites()
returns table(
  invite_id uuid,
  status text,
  created_at timestamptz,
  expires_at timestamptz,
  event_id uuid,
  event_title text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_all_day boolean,
  event_status text,
  area_name text,
  organizer_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
begin
  select * into v_recipient from public.contact_share_recipient_identity();

  update public.event_invites
  set status = 'expired'
  where recipient_email = v_recipient.email
    and status = 'pending'
    and expires_at <= now();

  return query
  select
    ei.id,
    ei.status,
    ei.created_at,
    ei.expires_at,
    e.id,
    e.title,
    e.starts_at,
    e.ends_at,
    e.is_all_day,
    e.status,
    a.name,
    coalesce(
      o.name,
      nullif(btrim(concat_ws(' ', inviter.first_name, inviter.last_name)), ''),
      'Organizzatore FamilArea'
    )
  from public.event_invites ei
  join public.events e on e.id = ei.event_id
  left join public.areas a on a.id = e.area_id
  left join public.organizations o on o.account_id = ei.owner_account_id
  left join public.profiles inviter on inviter.account_id = ei.invited_by_account_id
  where ei.recipient_email = v_recipient.email
    and ei.status = 'pending'
    and ei.expires_at > now()
  order by ei.created_at desc, ei.id;
end;
$$;

create or replace function public.accept_my_event_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_invite public.event_invites%rowtype;
begin
  select * into v_recipient from public.contact_share_recipient_identity();

  select * into v_invite
  from public.event_invites
  where id = p_invite_id
  for update;

  if not found
     or v_invite.recipient_email <> v_recipient.email
     or v_invite.status <> 'pending'
     or v_invite.expires_at <= now() then
    raise exception 'event invite unavailable';
  end if;

  if v_invite.contact_id is not null then
    if exists (
      select 1
      from public.contact_profile_links
      where contact_id = v_invite.contact_id
        and profile_id <> v_recipient.profile_id
    ) or exists (
      select 1
      from public.contact_profile_links
      where owner_account_id = v_invite.owner_account_id
        and profile_id = v_recipient.profile_id
        and contact_id <> v_invite.contact_id
    ) then
      raise exception 'contact/profile link conflict';
    end if;

    insert into public.contact_profile_links(contact_id, owner_account_id, profile_id, linked_via)
    values(v_invite.contact_id, v_invite.owner_account_id, v_recipient.profile_id, 'event_invite')
    on conflict(contact_id) do nothing;
  end if;

  insert into public.event_participants(
    event_id, contact_id, profile_id, participant_first_name,
    participant_last_name, status, accepted_at, added_via, added_by_account_id
  ) values (
    v_invite.event_id, v_invite.contact_id, v_recipient.profile_id,
    v_invite.recipient_first_name, v_invite.recipient_last_name,
    'active', now(), 'event_invite', v_invite.invited_by_account_id
  ) on conflict(event_id, contact_id) do update
  set profile_id = excluded.profile_id,
      status = 'active',
      accepted_at = excluded.accepted_at,
      added_via = 'event_invite',
      updated_at = now();

  update public.event_invites
  set status = 'accepted',
      accepted_by_profile_id = v_recipient.profile_id,
      responded_at = now()
  where id = v_invite.id;
end;
$$;

create or replace function public.decline_my_event_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_invite public.event_invites%rowtype;
begin
  select * into v_recipient from public.contact_share_recipient_identity();

  select * into v_invite
  from public.event_invites
  where id = p_invite_id
  for update;

  if not found
     or v_invite.recipient_email <> v_recipient.email
     or v_invite.status <> 'pending'
     or v_invite.expires_at <= now() then
    raise exception 'event invite unavailable';
  end if;

  update public.event_invites
  set status = 'declined',
      responded_at = now()
  where id = v_invite.id;
end;
$$;

revoke all on function public.get_my_event_invites() from public, anon;
revoke all on function public.accept_my_event_invite(uuid) from public, anon;
revoke all on function public.decline_my_event_invite(uuid) from public, anon;
grant execute on function public.get_my_event_invites() to authenticated;
grant execute on function public.accept_my_event_invite(uuid) to authenticated;
grant execute on function public.decline_my_event_invite(uuid) to authenticated;
alter function public.get_my_event_invites() owner to postgres;
alter function public.accept_my_event_invite(uuid) owner to postgres;
alter function public.decline_my_event_invite(uuid) owner to postgres;
