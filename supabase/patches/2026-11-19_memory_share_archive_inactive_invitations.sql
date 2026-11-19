-- FamilArea V2 -- hide inactive email Album shares from the owner list.
-- This extends the existing owner_archived_at mechanism without deleting
-- invitations, collaborations, albums, attachments or audit history.

begin;

create or replace function public.archive_abandoned_memory_share_invitation(
  p_invitation_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid := public.require_current_account();
  v_invitation public.memory_share_invitations%rowtype;
  v_collaboration_status text;
begin
  if p_invitation_id is null then
    raise exception 'memory share invitation unavailable';
  end if;

  select * into v_invitation
  from public.memory_share_invitations i
  where i.id = p_invitation_id
    and i.owner_account_id = v_owner_account_id
  for update;

  if not found then
    raise exception 'memory share invitation unavailable';
  end if;

  if v_invitation.owner_archived_at is not null then
    return false;
  end if;

  select mc.status
  into v_collaboration_status
  from public.memory_collaborations mc
  where mc.id = v_invitation.accepted_collaboration_id
    and mc.memory_id = v_invitation.memory_id
    and mc.owner_account_id = v_owner_account_id
  for key share;

  -- The invitation stays accepted as immutable acceptance history. It may be
  -- hidden only after its linked access grant is revoked, whether revoked by
  -- the owner or abandoned by the recipient.
  if v_invitation.status <> 'accepted'
    or v_collaboration_status <> 'revoked' then
    raise exception 'memory share invitation is not inactive';
  end if;

  update public.memory_share_invitations
  set owner_archived_at = now()
  where id = v_invitation.id;

  return true;
end;
$$;

commit;
