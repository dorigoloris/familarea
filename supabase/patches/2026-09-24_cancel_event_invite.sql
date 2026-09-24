-- FamilArea — Cancel one pending EventInvite while preserving its audit history.
-- Apply after 2026-09-24_contact_first_event_participants.sql.

begin;

create or replace function public.cancel_event_invite(p_event_invite_id uuid)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_invite public.event_invites%rowtype;
begin
  select * into v_invite
  from public.event_invites
  where id = p_event_invite_id
  for update;

  if not found then
    raise exception 'event invite not found';
  end if;

  perform 1 from public.require_event_manage_scope(v_invite.event_id);

  if v_invite.status <> 'pending' or v_invite.expires_at <= now() then
    raise exception 'event invite cannot be cancelled';
  end if;

  update public.event_invites
  set status = 'revoked',
      responded_at = now()
  where id = v_invite.id;
end;
$$;

revoke all on function public.cancel_event_invite(uuid) from public,anon;
grant execute on function public.cancel_event_invite(uuid) to authenticated;
alter function public.cancel_event_invite(uuid) owner to postgres;

commit;
