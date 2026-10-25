-- FamilArea V2 -- a recipient can leave an accepted Album share.
-- The collaboration row is retained for audit/history; the Album and its
-- attachments remain owned by the original owner and are never deleted.

begin;

create or replace function public.leave_my_memory_collaboration(
  p_collaboration_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient_account_id uuid := public.require_current_account();
  v_status text;
begin
  if p_collaboration_id is null then
    raise exception 'memory collaboration unavailable';
  end if;

  select mc.status
  into v_status
  from public.memory_collaborations mc
  where mc.id = p_collaboration_id
    and mc.recipient_account_id = v_recipient_account_id
  for update;

  if not found then
    raise exception 'memory collaboration unavailable';
  end if;

  -- A second click is harmless: the same recipient has already left.
  if v_status = 'revoked' then
    return false;
  end if;

  if v_status <> 'accepted' then
    raise exception 'memory collaboration unavailable';
  end if;

  update public.memory_collaborations
  set status = 'revoked',
      revoked_at = now()
  where id = p_collaboration_id;

  return true;
end;
$$;

alter function public.leave_my_memory_collaboration(uuid) owner to postgres;

revoke all on function public.leave_my_memory_collaboration(uuid)
  from public, anon;
grant execute on function public.leave_my_memory_collaboration(uuid)
  to authenticated;

commit;