-- FamilArea V2 -- rotation and re-delivery of an existing pending Album invitation.
-- This keeps the existing invitation and collaboration model unchanged.

begin;

create function public.resend_memory_share_invitation(
  p_invitation_id uuid,
  p_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid := public.require_current_account();
  v_owner_email text;
  v_sender text;
  v_memory_title text;
  v public.memory_share_invitations%rowtype;
begin
  if p_invitation_id is null
    or coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'memory share invitation unavailable';
  end if;

  select * into v
  from public.memory_share_invitations i
  where i.id = p_invitation_id
    and i.owner_account_id = v_owner
  for update;

  if not found
    or v.status <> 'pending'
    or v.expires_at <= now() then
    raise exception 'memory share invitation unavailable';
  end if;

  -- Reserve delivery before returning a token: concurrent clicks cannot
  -- rotate the token and send two invitations.
  if v.delivery_attempted_at is not null
    and v.delivery_attempted_at > now() - interval '60 seconds' then
    raise exception 'memory share invitation resend already in progress';
  end if;

  select public.normalize_contact_email(u.email) into v_owner_email
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  where a.id = v_owner
    and u.email_confirmed_at is not null;

  if v_owner_email is null
    or v.recipient_email = v_owner_email then
    raise exception 'memory share invitation unavailable';
  end if;

  select m.title into v_memory_title
  from public.memories m
  where m.id = v.memory_id
    and m.owner_account_id = v_owner;

  if not found then
    raise exception 'memory share invitation unavailable';
  end if;

  update public.memory_share_invitations
  set token_hash = p_token_hash,
      delivery_status = 'pending',
      delivery_attempted_at = now(),
      delivery_error_code = null
  where id = v.id;

  select coalesce(
    o.name,
    nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), ''),
    'Un utente FamilArea'
  ) into v_sender
  from public.accounts a
  left join public.organizations o on o.account_id = a.id
  left join public.profiles p on p.account_id = a.id
  where a.id = v_owner;

  return jsonb_build_object(
    'invitation_id', v.id,
    'memory_id', v.memory_id,
    'recipient_email', v.recipient_email,
    'sender_name', v_sender,
    'memory_title', v_memory_title,
    'expires_at', v.expires_at
  );
end;
$$;

alter function public.resend_memory_share_invitation(uuid, text) owner to postgres;
revoke all on function public.resend_memory_share_invitation(uuid, text)
from public, anon, authenticated;
grant execute on function public.resend_memory_share_invitation(uuid, text)
to authenticated;

commit;