-- FamilArea — Reuse an existing private Contact found by its normalized email.
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
    values (
      v_scope.owner_account_id,
      btrim(p_first_name),
      nullif(btrim(coalesce(p_last_name, '')), '')
    )
    returning id into v_contact;
  end if;

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
    token_hash, expires_at, invited_by_account_id
  )
  values (
    p_event_id, v_scope.owner_account_id, v_contact, v_email,
    public.hash_event_invite_token(v_token), now() + interval '14 days',
    public.require_current_account()
  );

  return jsonb_build_object('token', v_token, 'contact_id', v_contact);
end;
$$;

revoke all on function public.create_event_invite(uuid,text,text,text) from public,anon;
grant execute on function public.create_event_invite(uuid,text,text,text) to authenticated;
alter function public.create_event_invite(uuid,text,text,text) owner to postgres;
