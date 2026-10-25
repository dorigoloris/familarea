-- FamilArea V2 -- expose the current collaboration state in owner email-invite management.
-- The invitation remains historical; no invitation or collaboration state is changed here.

begin;

create or replace function public.get_memory_share_invitation_management(
  p_memory_id uuid
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid := public.require_current_account();
begin
  if not exists (
    select 1
    from public.memories m
    where m.id = p_memory_id
      and m.owner_account_id = v_owner
  ) then
    raise exception 'permission denied';
  end if;

  return query
  select jsonb_build_object(
    'invitation_id', i.id,
    'contact_id', i.recipient_contact_id,
    'recipient_email', i.recipient_email,
    'status', i.status,
    'collaboration_status', mc.status,
    'delivery_status', i.delivery_status,
    'created_at', i.created_at,
    'expires_at', i.expires_at,
    'accepted_at', i.accepted_at,
    'declined_at', i.declined_at,
    'cancelled_at', i.cancelled_at,
    'revoked_at', i.revoked_at,
    'expired_at', i.expired_at
  )
  from public.memory_share_invitations i
  left join public.memory_collaborations mc
    on mc.id = i.accepted_collaboration_id
  where i.memory_id = p_memory_id
  order by i.created_at desc, i.id;
end;
$$;

alter function public.get_memory_share_invitation_management(uuid) owner to postgres;

revoke all on function public.get_memory_share_invitation_management(uuid)
  from public, anon;
grant execute on function public.get_memory_share_invitation_management(uuid)
  to authenticated;

commit;