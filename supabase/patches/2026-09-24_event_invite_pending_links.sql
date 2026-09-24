-- FamilArea — Pending EventInvite list and secure link regeneration.
-- Apply after 2026-09-24_contact_first_event_participants.sql.

create or replace function public.create_event_invite(
  p_event_id uuid,
  p_recipient_email text,
  p_first_name text,
  p_last_name text default null
) returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_scope record;
  v_email text;
  v_contact uuid;
  v_existing_contacts integer;
  v_invite_id uuid;
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

  insert into public.contact_email_identities (owner_account_id, normalized_email, contact_id)
  values (v_scope.owner_account_id, v_email, v_contact)
  on conflict (owner_account_id, normalized_email) do nothing;

  if exists (select 1 from public.event_participants where event_id = p_event_id and contact_id = v_contact and status = 'active') then
    raise exception 'contact already participates in this event';
  end if;

  if exists (select 1 from public.event_invites where event_id = p_event_id and recipient_email = v_email and status = 'pending') then
    raise exception 'pending event invite already exists';
  end if;

  insert into public.event_invites (
    event_id, owner_account_id, contact_id, recipient_email,
    token_hash, expires_at, invited_by_account_id
  )
  values (
    p_event_id, v_scope.owner_account_id, v_contact, v_email,
    public.hash_event_invite_token(v_token), now() + interval '14 days',
    public.require_current_account()
  )
  returning id into v_invite_id;

  return jsonb_build_object('token', v_token, 'contact_id', v_contact, 'invite_id', v_invite_id);
end;
$$;

create or replace function public.get_pending_event_invites(p_event_id uuid)
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
    'invite_id', ei.id,
    'first_name', c.first_name,
    'last_name', c.last_name,
    'recipient_email', ei.recipient_email,
    'status', ei.status
  )
  from public.event_invites ei
  join public.contacts c on c.id = ei.contact_id
  where ei.event_id = p_event_id
    and ei.status = 'pending'
    and ei.expires_at > now()
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), ei.created_at;
end;
$$;

create or replace function public.regenerate_event_invite_link(p_event_invite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_invite public.event_invites%rowtype;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  select * into v_invite
  from public.event_invites
  where id = p_event_invite_id
  for update;

  if not found then
    raise exception 'event invite not found';
  end if;

  perform 1 from public.require_event_manage_scope(v_invite.event_id);

  if v_invite.status <> 'pending' or v_invite.expires_at <= now() then
    raise exception 'event invite cannot be regenerated';
  end if;

  update public.event_invites
  set token_hash = public.hash_event_invite_token(v_token),
      expires_at = now() + interval '14 days'
  where id = v_invite.id;

  return jsonb_build_object('invite_id', v_invite.id, 'token', v_token);
end;
$$;

revoke all on function public.create_event_invite(uuid,text,text,text) from public,anon;
revoke all on function public.get_pending_event_invites(uuid) from public,anon;
revoke all on function public.regenerate_event_invite_link(uuid) from public,anon;
grant execute on function public.create_event_invite(uuid,text,text,text) to authenticated;
grant execute on function public.get_pending_event_invites(uuid) to authenticated;
grant execute on function public.regenerate_event_invite_link(uuid) to authenticated;
alter function public.create_event_invite(uuid,text,text,text) owner to postgres;
alter function public.get_pending_event_invites(uuid) owner to postgres;
alter function public.regenerate_event_invite_link(uuid) owner to postgres;
