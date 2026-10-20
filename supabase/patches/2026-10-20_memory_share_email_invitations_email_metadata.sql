-- FamilArea — metadata server-side per l'email degli inviti Album.
-- Applicare prima di distribuire la Edge Function che richiede memory_title.
-- Non modifica inviti o collaborazioni esistenti e non concede privilegi.

begin;

create or replace function public.create_memory_share_invitation(
  p_memory_id uuid,
  p_contact_id uuid,
  p_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid := public.require_current_account();
  v_email text;
  v_owner_email text;
  v_sender text;
  v_memory_title text;
  v public.memory_share_invitations%rowtype;
begin
  if p_memory_id is null or p_contact_id is null or coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'memory share invitation unavailable';
  end if;

  if (
    select count(*)
    from public.memory_share_invitations i
    where i.owner_account_id = v_owner
      and i.created_at > now() - interval '1 hour'
  ) >= 20 then
    raise exception 'memory share invitation rate limit exceeded';
  end if;

  select m.title into v_memory_title
  from public.memories m
  where m.id = p_memory_id and m.owner_account_id = v_owner
  for update;
  if not found then
    raise exception 'permission denied';
  end if;

  select public.normalize_contact_email(cm.value) into v_email
  from public.contacts c
  join public.contact_methods cm on cm.contact_id = c.id and cm.method_type = 'email'
  where c.id = p_contact_id
    and c.owner_account_id = v_owner
    and public.normalize_contact_email(cm.value) ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  order by cm.is_primary desc, cm.id
  limit 1
  for update of c;
  if v_email is null then
    raise exception 'memory share invitation email unavailable';
  end if;

  select public.normalize_contact_email(u.email) into v_owner_email
  from public.accounts a
  join auth.users u on u.id = a.auth_user_id
  where a.id = v_owner and u.email_confirmed_at is not null;
  if v_owner_email is null then
    raise exception 'verified sender email required';
  end if;
  if v_email = v_owner_email then
    raise exception 'cannot invite memory owner';
  end if;

  if exists (
    select 1
    from public.memory_collaborations mc
    join public.accounts a on a.id = mc.recipient_account_id
    join auth.users u on u.id = a.auth_user_id
    where mc.memory_id = p_memory_id
      and mc.status in ('pending', 'accepted')
      and u.email_confirmed_at is not null
      and public.normalize_contact_email(u.email) = v_email
  ) then
    raise exception 'active memory collaboration already exists';
  end if;

  insert into public.memory_share_invitations (
    memory_id, owner_account_id, recipient_contact_id, recipient_email, token_hash
  ) values (
    p_memory_id, v_owner, p_contact_id, v_email, p_token_hash
  ) returning * into v;

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
    'recipient_email', v.recipient_email,
    'sender_name', v_sender,
    'memory_title', v_memory_title,
    'expires_at', v.expires_at
  );
exception
  when unique_violation then
    raise exception 'pending memory share invitation already exists';
end;
$$;

alter function public.create_memory_share_invitation(uuid, uuid, text) owner to postgres;
revoke all on function public.create_memory_share_invitation(uuid, uuid, text)
from public, anon, authenticated;

commit;
