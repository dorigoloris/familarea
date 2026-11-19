-- FamilArea V2 -- recipient-bound metadata and cover access before Album acceptance.
-- The invitation token is never sufficient on its own: both functions require
-- the authenticated account whose verified email is the invitation recipient.

begin;

create or replace function public.get_memory_share_invitation_context(
  p_token text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_current_account();
  v_recipient_email text;
  v_context jsonb;
begin
  select public.normalize_contact_email(u.email)
  into v_recipient_email
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  where a.id = v_account_id
    and a.auth_user_id = auth.uid()
    and a.account_type in ('personal', 'organization')
    and u.email_confirmed_at is not null;

  if v_recipient_email is null then
    raise exception 'verified recipient email required';
  end if;

  select jsonb_build_object(
    'recipient_email', i.recipient_email,
    'expires_at', i.expires_at,
    'album_title', m.title,
    'sender_name', coalesce(
      o.name,
      nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), ''),
      'Un utente FamilArea'
    ),
    'has_cover', cover.id is not null,
    'cover_mime_type', cover.mime_type
  )
  into v_context
  from public.memory_share_invitations i
  join public.memories m
    on m.id = i.memory_id
   and m.owner_account_id = i.owner_account_id
  left join public.organizations o on o.account_id = i.owner_account_id
  left join public.profiles p on p.account_id = i.owner_account_id
  left join public.attachments cover
    on cover.id = m.cover_attachment_id
   and cover.owner_account_id = m.owner_account_id
   and cover.target_type = 'memory'
   and cover.target_id = m.id
   and cover.mime_type in ('image/jpeg', 'image/png', 'image/webp')
  where i.token_hash = public.hash_memory_share_invitation_token(p_token)
    and i.status = 'pending'
    and i.expires_at > now()
    and i.recipient_email = v_recipient_email;

  if v_context is null then
    raise exception 'memory share invitation unavailable';
  end if;

  return v_context;
end;
$$;

-- Service-only: invoked by the image Edge Function after it derived the caller
-- account from the JWT. It returns the exact private object only after the same
-- recipient-email and pending-invitation checks as the browser-facing context.
create or replace function public.get_memory_share_invitation_cover_context_for_service(
  p_recipient_account_id uuid,
  p_token text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_email text;
  v_context jsonb;
begin
  if p_recipient_account_id is null then
    raise exception 'memory share invitation unavailable';
  end if;

  select public.normalize_contact_email(u.email)
  into v_recipient_email
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  where a.id = p_recipient_account_id
    and a.account_type in ('personal', 'organization')
    and u.email_confirmed_at is not null;

  if v_recipient_email is null then
    raise exception 'memory share invitation unavailable';
  end if;

  select jsonb_build_object(
    'attachment_id', cover.id,
    'storage_path', cover.storage_path,
    'mime_type', cover.mime_type
  )
  into v_context
  from public.memory_share_invitations i
  join public.memories m
    on m.id = i.memory_id
   and m.owner_account_id = i.owner_account_id
  join public.attachments cover
    on cover.id = m.cover_attachment_id
   and cover.owner_account_id = m.owner_account_id
   and cover.target_type = 'memory'
   and cover.target_id = m.id
   and cover.mime_type in ('image/jpeg', 'image/png', 'image/webp')
  where i.token_hash = public.hash_memory_share_invitation_token(p_token)
    and i.status = 'pending'
    and i.expires_at > now()
    and i.recipient_email = v_recipient_email;

  if v_context is null then
    raise exception 'memory share invitation unavailable';
  end if;

  return v_context;
end;
$$;

alter function public.get_memory_share_invitation_context(text) owner to postgres;
alter function public.get_memory_share_invitation_cover_context_for_service(uuid, text) owner to postgres;

-- The old anonymous grant would disclose Album metadata to anyone holding a
-- forwarded token. The page already obtains a session before calling the RPC.
revoke all on function public.get_memory_share_invitation_context(text) from public, anon;
revoke all on function public.get_memory_share_invitation_cover_context_for_service(uuid, text) from public, anon, authenticated;
grant execute on function public.get_memory_share_invitation_context(text) to authenticated;
grant execute on function public.get_memory_share_invitation_cover_context_for_service(uuid, text) to service_role;

commit;
