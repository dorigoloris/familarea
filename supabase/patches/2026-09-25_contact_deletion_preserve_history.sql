-- FamilArea — deleting a private Contact must not delete or block history.
-- This follows 2026-09-25_safe_contact_deletion.sql, replacing its restrictive
-- guards with referentially safe unlinking and durable participant snapshots.

-- Event participants currently use (event_id, contact_id) as their primary key.
-- A stable row id is needed before contact_id can become nullable on deletion.
alter table public.event_participants
  add column if not exists id uuid;

update public.event_participants
set id = gen_random_uuid()
where id is null;

alter table public.event_participants
  alter column id set default gen_random_uuid(),
  alter column id set not null;

alter table public.event_participants
  drop constraint if exists event_participants_pkey;

alter table public.event_participants
  add constraint event_participants_pkey primary key (id);

alter table public.event_participants
  alter column contact_id drop not null;

alter table public.event_participants
  add constraint event_participants_event_contact_key unique (event_id, contact_id);

alter table public.event_participants
  add column if not exists participant_first_name text,
  add column if not exists participant_last_name text;

-- Snapshot all existing Contact-backed participants before a Contact can be
-- unlinked. Profiles remain the preferred live identity when available.
update public.event_participants ep
set participant_first_name = coalesce(ep.participant_first_name, c.first_name),
    participant_last_name = coalesce(ep.participant_last_name, c.last_name)
from public.contacts c
where c.id = ep.contact_id
  and (ep.participant_first_name is null or ep.participant_last_name is null);

create or replace function public.capture_event_participant_contact_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.contact_id is not null
     and (new.participant_first_name is null or new.participant_last_name is null) then
    select c.first_name, c.last_name
    into new.participant_first_name, new.participant_last_name
    from public.contacts c
    where c.id = new.contact_id;
  end if;

  return new;
end;
$$;

drop trigger if exists event_participants_capture_contact_snapshot on public.event_participants;
create trigger event_participants_capture_contact_snapshot
before insert or update of contact_id on public.event_participants
for each row execute function public.capture_event_participant_contact_snapshot();

-- contact_id is nullable only for a record deliberately detached from the
-- address book. Direct table access remains revoked; all writes use RPCs.
create or replace function public.assert_event_participant_contact_scope()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid;
begin
  if new.contact_id is null then
    return new;
  end if;

  select a.owner_account_id into v_owner
  from public.events e
  join public.areas a on a.id = e.area_id
  where e.id = new.event_id;

  if v_owner is null or not exists (
    select 1
    from public.contacts c
    where c.id = new.contact_id
      and c.owner_account_id = v_owner
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

-- Explicit removal of a Contact/Profile link still clears the participant
-- Profile. A cascading link deletion caused by deleting the Contact preserves
-- the already-recorded Profile identity instead.
create or replace function public.clear_participant_profile_on_contact_link_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (select 1 from public.contacts c where c.id = old.contact_id) then
    update public.event_participants
    set profile_id = null,
        updated_at = now()
    where contact_id = old.contact_id
      and profile_id = old.profile_id;
  end if;

  return old;
end;
$$;

alter table public.event_participants
  drop constraint if exists event_participants_contact_id_fkey;

alter table public.event_participants
  add constraint event_participants_contact_id_fkey
  foreign key (contact_id) references public.contacts(id) on delete set null;

alter table public.event_invites
  add column if not exists recipient_first_name text,
  add column if not exists recipient_last_name text;

update public.event_invites ei
set recipient_first_name = coalesce(ei.recipient_first_name, c.first_name),
    recipient_last_name = coalesce(ei.recipient_last_name, c.last_name)
from public.contacts c
where c.id = ei.contact_id
  and (ei.recipient_first_name is null or ei.recipient_last_name is null);

alter table public.event_invites
  alter column contact_id drop not null;

alter table public.event_invites
  drop constraint if exists event_invites_contact_id_fkey;

alter table public.event_invites
  add constraint event_invites_contact_id_fkey
  foreign key (contact_id) references public.contacts(id) on delete set null;

-- Private Contact data cascades away; event and Family records remain and their
-- foreign keys are detached rather than deleted.
create or replace function public.delete_contact(p_contact_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
begin
  v_owner_account_id := public.require_current_account();

  perform 1
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_account_id = v_owner_account_id
  for update;

  if not found then
    raise exception 'contact not found or unavailable';
  end if;

  delete from public.contacts
  where id = p_contact_id
    and owner_account_id = v_owner_account_id;
end;
$$;

-- Reader RPCs must resolve a live Profile first, then a live Contact, then the
-- immutable snapshot. No Profile identifier is disclosed to the frontend.
create or replace function public.get_event_participants(p_event_id uuid)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope record;
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);

  return query
  select jsonb_build_object(
    'contact_id', ep.contact_id,
    'first_name', coalesce(p.first_name, c.first_name, ep.participant_first_name, 'Partecipante'),
    'last_name', coalesce(p.last_name, c.last_name, ep.participant_last_name),
    'status', ep.status,
    'added_via', ep.added_via
  )
  from public.event_participants ep
  left join public.contacts c on c.id = ep.contact_id
  left join public.profiles p on p.id = ep.profile_id
  where ep.event_id = p_event_id
    and ep.status = 'active'
  order by lower(coalesce(p.first_name, c.first_name, ep.participant_first_name, 'Partecipante')),
           lower(coalesce(p.last_name, c.last_name, ep.participant_last_name, ''));
end;
$$;

create or replace function public.get_pending_event_invites(p_event_id uuid)
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope record;
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);

  return query
  select jsonb_build_object(
    'invite_id', ei.id,
    'first_name', coalesce(c.first_name, ei.recipient_first_name),
    'last_name', coalesce(c.last_name, ei.recipient_last_name),
    'recipient_email', ei.recipient_email,
    'status', ei.status
  )
  from public.event_invites ei
  left join public.contacts c on c.id = ei.contact_id
  where ei.event_id = p_event_id
    and ei.status = 'pending'
    and ei.expires_at > now()
  order by lower(coalesce(c.first_name, ei.recipient_first_name, ei.recipient_email)),
           lower(coalesce(c.last_name, ei.recipient_last_name, '')),
           ei.created_at;
end;
$$;

-- Capture the invitee name when a new invitation is created. The recipient
-- email already is a durable snapshot; these fields preserve the displayed name.
create or replace function public.create_event_invite(
  p_event_id uuid,
  p_recipient_email text,
  p_first_name text,
  p_last_name text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_scope record;
  v_email text;
  v_contact uuid;
  v_existing_contacts integer;
  v_invite_id uuid;
  v_contact_first_name text;
  v_contact_last_name text;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  select * into v_scope from public.require_event_manage_scope(p_event_id);
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

  if exists (
    select 1 from public.event_participants
    where event_id = p_event_id and contact_id = v_contact and status = 'active'
  ) then
    raise exception 'contact already participates in this event';
  end if;

  if exists (
    select 1 from public.event_invites
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

revoke all on function public.capture_event_participant_contact_snapshot() from public, anon, authenticated;
revoke all on function public.delete_contact(uuid) from public, anon;
grant execute on function public.delete_contact(uuid) to authenticated;
revoke all on function public.get_event_participants(uuid) from public, anon;
revoke all on function public.get_pending_event_invites(uuid) from public, anon;
revoke all on function public.create_event_invite(uuid, text, text, text) from public, anon;
grant execute on function public.get_event_participants(uuid) to authenticated;
grant execute on function public.get_pending_event_invites(uuid) to authenticated;
grant execute on function public.create_event_invite(uuid, text, text, text) to authenticated;
alter function public.capture_event_participant_contact_snapshot() owner to postgres;
alter function public.delete_contact(uuid) owner to postgres;
alter function public.get_event_participants(uuid) owner to postgres;
alter function public.get_pending_event_invites(uuid) owner to postgres;
alter function public.create_event_invite(uuid, text, text, text) owner to postgres;
