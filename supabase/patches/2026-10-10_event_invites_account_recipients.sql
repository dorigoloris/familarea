-- FamilArea — account-based recipients for invitations to non-Area Events.
--
-- Keeps the existing personal/profile acceptance flow intact while allowing a
-- verified Organization account already linked to the owner's Contact to
-- accept through Condivisioni. Area Events and commitments are untouched.

begin;

-- A profile cannot identify an Organization recipient. Preserve the historic
-- profile reference, add an account-level audit reference and backfill it
-- before replacing the accepted-state invariant.
alter table public.event_invites
  add column if not exists accepted_by_account_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.event_invites'::regclass
      and conname = 'event_invites_accepted_by_account_id_fkey'
  ) then
    alter table public.event_invites
      add constraint event_invites_accepted_by_account_id_fkey
      foreign key (accepted_by_account_id)
      references public.accounts(id)
      on delete set null;
  end if;
end;
$$;

update public.event_invites ei
set accepted_by_account_id = p.account_id
from public.profiles p
where ei.status = 'accepted'
  and ei.accepted_by_account_id is null
  and p.id = ei.accepted_by_profile_id;

do $$
begin
  if exists (
    select 1
    from public.event_invites
    where status = 'accepted'
      and accepted_by_account_id is null
  ) then
    raise exception 'cannot add account recipient invariant: accepted Event invite without a resolvable account';
  end if;
end;
$$;

alter table public.event_invites
  drop constraint if exists event_invites_check1;

alter table public.event_invites
  drop constraint if exists event_invites_accepted_account_state_check;

alter table public.event_invites
  add constraint event_invites_accepted_account_state_check
  check ((status = 'accepted') = (accepted_by_account_id is not null));

-- The existing token route remains personal/profile-based. It also records
-- the corresponding account now required by the accepted-state constraint.
create or replace function public.accept_event_invite(p_token text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invite public.event_invites%rowtype;
  v_email text;
  v_profile uuid;
  v_account uuid;
begin
  select public.normalize_contact_email(u.email), p.id, a.id
  into v_email, v_profile, v_account
  from auth.users u
  join public.accounts a on a.auth_user_id = u.id
  join public.profiles p on p.account_id = a.id
  where u.id = auth.uid()
    and u.email_confirmed_at is not null;

  if v_profile is null or v_account is null then
    raise exception 'verified personal profile required';
  end if;

  select * into v_invite
  from public.event_invites
  where token_hash = public.hash_event_invite_token(p_token)
  for update;

  if not found
     or v_invite.status <> 'pending'
     or v_invite.expires_at <= now()
     or v_invite.recipient_email <> v_email then
    raise exception 'event invite cannot be accepted';
  end if;

  if v_invite.contact_id is not null then
    if exists (
      select 1
      from public.contact_profile_links
      where contact_id = v_invite.contact_id
        and profile_id <> v_profile
    ) or exists (
      select 1
      from public.contact_profile_links
      where owner_account_id = v_invite.owner_account_id
        and profile_id = v_profile
        and contact_id <> v_invite.contact_id
    ) then
      raise exception 'contact/profile link conflict';
    end if;

    insert into public.contact_profile_links(contact_id, owner_account_id, profile_id, linked_via)
    values(v_invite.contact_id, v_invite.owner_account_id, v_profile, 'event_invite')
    on conflict(contact_id) do nothing;
  end if;

  insert into public.event_participants(
    event_id, contact_id, profile_id, participant_first_name,
    participant_last_name, status, accepted_at, added_via, added_by_account_id
  ) values (
    v_invite.event_id, v_invite.contact_id, v_profile,
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
      accepted_by_profile_id = v_profile,
      accepted_by_account_id = v_account,
      responded_at = now()
  where id = v_invite.id;
end;
$$;

-- Inbox acceptance is account-based. Personal recipients retain exactly the
-- established profile-link path. Organization recipients must already be the
-- account explicitly linked to the selected Contact; the event invite never
-- creates a relationship merely from a matching email address.
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
  select * into v_recipient from public.contact_share_inbox_recipient_identity();

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

  if v_invite.contact_id is null then
    raise exception 'event invite contact unavailable';
  end if;

  if v_recipient.account_type = 'personal' then
    if v_recipient.profile_id is null then
      raise exception 'verified personal profile required';
    end if;

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
  elsif v_recipient.account_type = 'organization' then
    if not exists (
      select 1
      from public.contact_account_links l
      where l.contact_id = v_invite.contact_id
        and l.owner_account_id = v_invite.owner_account_id
        and l.linked_account_id = v_recipient.account_id
    ) then
      raise exception 'event invite recipient is not linked to the selected contact';
    end if;
  else
    raise exception 'unsupported event invite recipient';
  end if;

  insert into public.event_participants(
    event_id, contact_id, profile_id, participant_first_name,
    participant_last_name, status, accepted_at, added_via, added_by_account_id
  ) values (
    v_invite.event_id, v_invite.contact_id,
    case when v_recipient.account_type = 'personal' then v_recipient.profile_id else null end,
    v_invite.recipient_first_name, v_invite.recipient_last_name,
    'active', now(), 'event_invite', v_invite.invited_by_account_id
  ) on conflict(event_id, contact_id) do update
  set profile_id = coalesce(event_participants.profile_id, excluded.profile_id),
      status = 'active',
      accepted_at = excluded.accepted_at,
      added_via = 'event_invite',
      updated_at = now();

  update public.event_invites
  set status = 'accepted',
      accepted_by_profile_id = case when v_recipient.account_type = 'personal' then v_recipient.profile_id else null end,
      accepted_by_account_id = v_recipient.account_id,
      responded_at = now()
  where id = v_invite.id;
end;
$$;

-- Participant visibility stays explicit. A linked Organization account gains
-- read-only visibility only through an active event_participants row.
create or replace function public.event_personal_source(p_event_id uuid, p_account_id uuid)
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
            or (
              e.area_id is null
              and exists (
                select 1
                from public.contact_account_links l
                where l.contact_id = ep.contact_id
                  and l.linked_account_id = p_account_id
              )
            )
          )
      ) then 'participant'
    else null
  end
  from public.events e
  where e.id = p_event_id;
$$;

-- Keep the personal count unchanged; extend only the Organization branch.
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
       from public.event_invites ei
       where ei.recipient_email = v_recipient.email
         and ei.status = 'pending'
         and ei.expires_at > now())
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

alter function public.accept_event_invite(text) owner to postgres;
alter function public.accept_my_event_invite(uuid) owner to postgres;
alter function public.event_personal_source(uuid, uuid) owner to postgres;
alter function public.get_my_pending_invites_count() owner to postgres;

revoke all on function public.accept_event_invite(text),
  public.accept_my_event_invite(uuid),
  public.get_my_pending_invites_count() from public, anon;

grant execute on function public.accept_event_invite(text),
  public.accept_my_event_invite(uuid),
  public.get_my_pending_invites_count() to authenticated;

commit;
