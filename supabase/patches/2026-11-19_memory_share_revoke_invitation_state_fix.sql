-- FamilArea V2 -- keep the acceptance audit immutable when an owner revokes
-- an email-based Album share. The collaboration is the access grant; its
-- revoked state is already the source of truth for owner-facing management.

begin;

create or replace function public.revoke_memory_share_invitation(
  p_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_invitation public.memory_share_invitations%rowtype;
begin
  select * into v_invitation
  from public.memory_share_invitations i
  where i.id = p_id
    and i.owner_account_id = v_owner_account_id
    and i.status = 'accepted'
  for update;

  if not found then
    raise exception 'memory share invitation not found or not revocable';
  end if;

  update public.memory_collaborations
  set status = 'revoked',
      revoked_at = now(),
      revoked_by_account_id = v_owner_account_id
  where id = v_invitation.accepted_collaboration_id
    and owner_account_id = v_owner_account_id
    and status = 'accepted';

  if not found then
    raise exception 'memory share invitation collaboration unavailable';
  end if;

  -- Do not change the invitation row: status = accepted must retain its
  -- acceptance audit and the link to the collaboration. The collaboration's
  -- revoked state is the access revocation and is rendered as such by
  -- get_memory_share_management().
end;
$$;

commit;
