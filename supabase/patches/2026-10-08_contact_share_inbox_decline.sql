-- FamilArea — complete contact-share inbox transitions for verified account recipients.
-- Prerequisite: 2026-10-07_contact_share_inbox.sql.
-- A share is still sent by a personal Profile; recipients may be verified personal
-- or organization Accounts. The legacy token flow keeps its existing signatures.

begin;

alter table public.contact_shares
  add column if not exists completed_by_account_id uuid references public.accounts(id) on delete set null,
  add column if not exists declined_at timestamptz,
  add column if not exists declined_by_account_id uuid references public.accounts(id) on delete set null;

-- Preserve the audit identity of historical personal acceptances before replacing
-- the profile-only completion invariant with its account-level equivalent.
update public.contact_shares cs
set completed_by_account_id = p.account_id
from public.profiles p
where cs.status = 'completed'
  and cs.completed_by_account_id is null
  and cs.completed_by_profile_id = p.id;

do $$
declare
  v_constraint_name text;
begin
  -- Historical contact_shares checks encode the old state list and the
  -- profile-only completion audit. Drop only checks that concern status.
  for v_constraint_name in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.contact_shares'::regclass
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%status%'
  loop
    execute format('alter table public.contact_shares drop constraint %I', v_constraint_name);
  end loop;
end
$$;

alter table public.contact_shares
  add constraint contact_shares_status_check
    check (status in ('pending', 'completed', 'declined', 'revoked', 'expired')),
  add constraint contact_shares_completed_audit_check
    check (
      (status = 'completed') =
      (completed_at is not null and completed_by_account_id is not null)
    ),
  add constraint contact_shares_declined_audit_check
    check (
      (status = 'declined') =
      (declined_at is not null and declined_by_account_id is not null)
    ),
  add constraint contact_shares_revoked_audit_check
    check ((status = 'revoked') = (revoked_at is not null));

-- This identity is deliberately separate from contact_share_recipient_identity().
-- The legacy helper remains personal/profile-only for unrelated invitation flows.
create or replace function public.contact_share_inbox_recipient_identity()
returns table(account_id uuid, profile_id uuid, account_type text, email text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  select
    a.id,
    p.id,
    a.account_type::text,
    public.normalize_contact_email(u.email)
  into account_id, profile_id, account_type, email
  from auth.users u
  join public.accounts a on a.auth_user_id = u.id
  left join public.profiles p on p.account_id = a.id
  where u.id = auth.uid()
    and u.email_confirmed_at is not null
    and a.account_type in ('personal', 'organization');

  if account_id is null or email is null then
    raise exception 'verified account required';
  end if;

  return next;
end;
$$;

create or replace function public.get_contact_share_for_recipient(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_share public.contact_shares%rowtype;
  v_sender_email text;
  v_first text;
  v_last text;
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();
  select * into v_share
  from public.contact_shares
  where token_hash = public.hash_contact_share_token(p_token)
  for update;
  if not found then raise exception 'contact share unavailable'; end if;

  if v_share.status = 'pending' and v_share.expires_at <= now() then
    update public.contact_shares set status = 'expired' where id = v_share.id;
    v_share.status := 'expired';
  end if;
  if v_share.status <> 'pending' then raise exception 'contact share unavailable'; end if;
  if v_share.recipient_email <> v_recipient.email then
    raise exception 'contact share recipient mismatch';
  end if;

  select p.first_name, p.last_name, public.normalize_contact_email(u.email)
  into v_first, v_last, v_sender_email
  from public.profiles p
  join public.accounts a on a.id = p.account_id
  join auth.users u on u.id = a.auth_user_id
  where p.id = v_share.sender_profile_id
    and u.email_confirmed_at is not null;
  if v_sender_email is null then raise exception 'contact share unavailable'; end if;

  return jsonb_build_object(
    'first_name', v_first,
    'last_name', v_last,
    'email', v_sender_email,
    'expires_at', v_share.expires_at
  );
end;
$$;

create or replace function public.accept_contact_share_by_id_impl(
  p_share_id uuid,
  p_existing_contact_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_share public.contact_shares%rowtype;
  v_sender_email text;
  v_first text;
  v_last text;
  v_contact uuid;
  v_link_profile uuid;
  v_count integer;
  v_has_email boolean;
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();
  select * into v_share from public.contact_shares where id = p_share_id for update;
  if not found then raise exception 'contact share unavailable'; end if;
  if v_share.status <> 'pending'
     or v_share.expires_at <= now()
     or v_share.recipient_email <> v_recipient.email then
    raise exception 'contact share unavailable';
  end if;

  select p.first_name, p.last_name, public.normalize_contact_email(u.email)
  into v_first, v_last, v_sender_email
  from public.profiles p
  join public.accounts a on a.id = p.account_id
  join auth.users u on u.id = a.auth_user_id
  where p.id = v_share.sender_profile_id
    and u.email_confirmed_at is not null;
  if v_sender_email is null then raise exception 'contact share unavailable'; end if;

  select contact_id into v_contact
  from public.contact_profile_links
  where owner_account_id = v_recipient.account_id
    and profile_id = v_share.sender_profile_id;

  if p_existing_contact_id is not null then
    if v_contact is not null and v_contact <> p_existing_contact_id then
      raise exception 'contact share conflict';
    end if;
    if not exists (
      select 1 from public.contacts c
      where c.id = p_existing_contact_id
        and c.owner_account_id = v_recipient.account_id
    ) then
      raise exception 'selected contact unavailable';
    end if;
    select l.profile_id into v_link_profile
    from public.contact_profile_links l
    where l.contact_id = p_existing_contact_id
      and l.owner_account_id = v_recipient.account_id;
    if v_link_profile is not null and v_link_profile <> v_share.sender_profile_id then
      raise exception 'contact share conflict';
    end if;
    v_contact := p_existing_contact_id;
  elsif v_contact is null then
    select count(distinct c.id), min(c.id::text)::uuid
    into v_count, v_contact
    from public.contacts c
    join public.contact_methods m on m.contact_id = c.id
    where c.owner_account_id = v_recipient.account_id
      and m.method_type = 'email'
      and lower(btrim(m.value)) = v_sender_email;
    if v_count > 1 then raise exception 'contact share conflict'; end if;
    if v_contact is null then
      insert into public.contacts(owner_account_id, first_name, last_name)
      values (v_recipient.account_id, v_first, nullif(v_last, ''))
      returning id into v_contact;
    else
      select l.profile_id into v_link_profile
      from public.contact_profile_links l
      where l.contact_id = v_contact;
      if v_link_profile is not null and v_link_profile <> v_share.sender_profile_id then
        raise exception 'contact share conflict';
      end if;
    end if;
  end if;

  select exists (
    select 1 from public.contact_methods
    where contact_id = v_contact
      and method_type = 'email'
      and lower(btrim(value)) = v_sender_email
  ) into v_has_email;
  if not v_has_email then
    insert into public.contact_methods(contact_id, method_type, value, is_primary)
    values (
      v_contact,
      'email',
      v_sender_email,
      not exists (
        select 1 from public.contact_methods
        where contact_id = v_contact and method_type = 'email'
      )
    );
  end if;

  insert into public.contact_profile_links(contact_id, owner_account_id, profile_id, linked_via)
  values (v_contact, v_recipient.account_id, v_share.sender_profile_id, 'contact_share')
  on conflict do nothing;
  if not exists (
    select 1 from public.contact_profile_links
    where contact_id = v_contact
      and owner_account_id = v_recipient.account_id
      and profile_id = v_share.sender_profile_id
  ) then
    raise exception 'contact share conflict';
  end if;

  update public.contact_shares
  set status = 'completed',
      completed_at = now(),
      completed_by_profile_id = v_recipient.profile_id,
      completed_by_account_id = v_recipient.account_id
  where id = v_share.id;

  return jsonb_build_object('contact_id', v_contact);
end;
$$;

create or replace function public.accept_contact_share_impl(
  p_token text,
  p_existing_contact_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_share_id uuid;
begin
  select id into v_share_id
  from public.contact_shares
  where token_hash = public.hash_contact_share_token(p_token);
  if v_share_id is null then raise exception 'contact share unavailable'; end if;
  return public.accept_contact_share_by_id_impl(v_share_id, p_existing_contact_id);
end;
$$;

create or replace function public.accept_contact_share(p_token text)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.accept_contact_share_impl(p_token, null)
$$;

create or replace function public.accept_contact_share(
  p_token text,
  p_existing_contact_id uuid
)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.accept_contact_share_impl(p_token, p_existing_contact_id)
$$;

create or replace function public.get_my_contact_share_invites()
returns setof jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();

  update public.contact_shares
  set status = 'expired'
  where recipient_email = v_recipient.email
    and status = 'pending'
    and expires_at <= now();

  return query
  select jsonb_build_object(
    'share_id', cs.id,
    'sender_first_name', p.first_name,
    'sender_last_name', p.last_name,
    'sender_display_name', nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), ''),
    'sender_email', public.normalize_contact_email(u.email),
    'status', cs.status,
    'created_at', cs.created_at,
    'expires_at', cs.expires_at
  )
  from public.contact_shares cs
  join public.profiles p on p.id = cs.sender_profile_id
  join public.accounts a on a.id = p.account_id
  join auth.users u on u.id = a.auth_user_id
  where cs.recipient_email = v_recipient.email
    and cs.status = 'pending'
    and cs.expires_at > now()
    and u.email_confirmed_at is not null
  order by cs.created_at desc, cs.id;
end;
$$;

create or replace function public.accept_my_contact_share(
  p_share_id uuid,
  p_existing_contact_id uuid default null
)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.accept_contact_share_by_id_impl(p_share_id, p_existing_contact_id)
$$;

create or replace function public.decline_my_contact_share(p_share_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
  v_share public.contact_shares%rowtype;
begin
  select * into v_recipient from public.contact_share_inbox_recipient_identity();
  select * into v_share from public.contact_shares where id = p_share_id for update;
  if not found
     or v_share.status <> 'pending'
     or v_share.expires_at <= now()
     or v_share.recipient_email <> v_recipient.email then
    raise exception 'contact share unavailable';
  end if;

  update public.contact_shares
  set status = 'declined',
      declined_at = now(),
      declined_by_account_id = v_recipient.account_id
  where id = v_share.id;
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

  -- An organization inbox currently supports Contact Shares only. Do not
  -- advertise email-addressed personal invitation types that it cannot open.
  if v_recipient.account_type = 'organization' then
    return (
      select count(*)
      from public.contact_shares cs
      where cs.recipient_email = v_recipient.email
        and cs.status = 'pending'
        and cs.expires_at > now()
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

alter function public.contact_share_inbox_recipient_identity() owner to postgres;
alter function public.get_contact_share_for_recipient(text) owner to postgres;
alter function public.accept_contact_share_by_id_impl(uuid, uuid) owner to postgres;
alter function public.accept_contact_share_impl(text, uuid) owner to postgres;
alter function public.accept_contact_share(text) owner to postgres;
alter function public.accept_contact_share(text, uuid) owner to postgres;
alter function public.get_my_contact_share_invites() owner to postgres;
alter function public.accept_my_contact_share(uuid, uuid) owner to postgres;
alter function public.decline_my_contact_share(uuid) owner to postgres;

revoke all on function public.contact_share_inbox_recipient_identity() from public, anon, authenticated;
revoke all on function public.accept_contact_share_by_id_impl(uuid, uuid) from public, anon, authenticated;
revoke all on function public.accept_contact_share_impl(text, uuid) from public, anon, authenticated;
revoke all on function public.get_my_contact_share_invites() from public, anon, authenticated;
revoke all on function public.accept_my_contact_share(uuid, uuid) from public, anon, authenticated;
revoke all on function public.decline_my_contact_share(uuid) from public, anon, authenticated;
grant execute on function public.get_contact_share_for_recipient(text), public.accept_contact_share(text), public.accept_contact_share(text, uuid) to authenticated;
grant execute on function public.get_my_contact_share_invites(), public.accept_my_contact_share(uuid, uuid), public.decline_my_contact_share(uuid) to authenticated;

revoke all on function public.get_my_pending_invites_count() from public, anon;
grant execute on function public.get_my_pending_invites_count() to authenticated;

commit;
