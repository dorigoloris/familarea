-- FamilArea — create a pending EventInvite from an organiser-owned Contact.

create or replace function public.create_event_invite_for_contact(
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
  v_first_name text;
  v_last_name text;
  v_email text;
  v_result jsonb;
begin
  select * into v_scope
  from public.require_event_manage_scope(p_event_id);

  select c.first_name, c.last_name
  into v_first_name, v_last_name
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_account_id = v_scope.owner_account_id;

  if not found then
    raise exception 'contact unavailable';
  end if;

  select cm.value
  into v_email
  from public.contact_methods cm
  where cm.contact_id = p_contact_id
    and cm.method_type = 'email'
  order by cm.is_primary desc, cm.id
  limit 1;

  if v_email is null then
    raise exception 'contact has no usable email';
  end if;

  -- Validates the selected primary email before delegating creation to the
  -- existing EventInvite flow, which preserves pending/active safeguards.
  v_email := public.normalize_contact_email(v_email);
  v_result := public.create_event_invite(p_event_id, v_email, v_first_name, v_last_name);

  if (v_result->>'contact_id')::uuid <> p_contact_id then
    raise exception 'contact email identity conflict';
  end if;

  return v_result;
end;
$$;

revoke all on function public.create_event_invite_for_contact(uuid, uuid) from public, anon;
grant execute on function public.create_event_invite_for_contact(uuid, uuid) to authenticated;
alter function public.create_event_invite_for_contact(uuid, uuid) owner to postgres;
