-- FamilArea V2 -- a recipient can leave an accepted selective photo share.
-- The share row is retained for history; no album, attachment or photo is deleted.

begin;

create function public.leave_my_memory_photo_share(
  p_share_id uuid
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
  if p_share_id is null then
    raise exception 'memory photo share unavailable';
  end if;

  select s.status
  into v_status
  from public.memory_photo_shares s
  where s.id = p_share_id
    and s.recipient_account_id = v_recipient_account_id
  for update;

  if not found or v_status <> 'accepted' then
    raise exception 'memory photo share unavailable';
  end if;

  update public.memory_photo_shares
  set status = 'revoked',
      revoked_at = now()
  where id = p_share_id
    and recipient_account_id = v_recipient_account_id
    and status = 'accepted';

  if not found then
    raise exception 'memory photo share unavailable';
  end if;

  return true;
end;
$$;

alter function public.leave_my_memory_photo_share(uuid) owner to postgres;

revoke all on function public.leave_my_memory_photo_share(uuid)
  from public, anon, authenticated;
grant execute on function public.leave_my_memory_photo_share(uuid)
  to authenticated;

commit;
