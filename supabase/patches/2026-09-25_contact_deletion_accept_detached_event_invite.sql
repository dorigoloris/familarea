-- FamilArea — accept an EventInvite whose private Contact was deleted.
-- Apply after 2026-09-25_contact_deletion_preserve_history.sql.

create or replace function public.accept_event_invite(p_token text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invite public.event_invites%rowtype;
  v_email text;
  v_profile uuid;
begin
  select public.normalize_contact_email(u.email), p.id
  into v_email, v_profile
  from auth.users u
  join public.profiles p on p.account_id = public.require_current_account()
  where u.id = auth.uid()
    and u.email_confirmed_at is not null;

  if v_profile is null then
    raise exception 'verified personal profile required';
  end if;

  select * into v_invite
  from public.event_invites
  where token_hash = public.hash_event_invite_token(p_token)
  for update;

  if not found
     or v_invite.status <> 'pending'
     or v_invite.expires_at <= now()
     or v_invite.recipient_email <> v_email then
    raise exception 'event invite cannot be accepted';
  end if;

  if v_invite.contact_id is not null then
    if exists (
      select 1 from public.contact_profile_links
      where contact_id = v_invite.contact_id
        and profile_id <> v_profile
    ) or exists (
      select 1 from public.contact_profile_links
      where owner_account_id = v_invite.owner_account_id
        and profile_id = v_profile
        and contact_id <> v_invite.contact_id
    ) then
      raise exception 'contact/profile link conflict';
    end if;

    insert into public.contact_profile_links(contact_id, owner_account_id, profile_id, linked_via)
    values(v_invite.contact_id, v_invite.owner_account_id, v_profile, 'event_invite')
    on conflict(contact_id) do nothing;
  end if;

  insert into public.event_participants(
    event_id, contact_id, profile_id, participant_first_name,
    participant_last_name, status, accepted_at, added_via, added_by_account_id
  ) values (
    v_invite.event_id, v_invite.contact_id, v_profile,
    v_invite.recipient_first_name, v_invite.recipient_last_name,
    'active', now(), 'event_invite', v_invite.invited_by_account_id
  ) on conflict(event_id, contact_id) do update
  set profile_id = excluded.profile_id,
      status = 'active',
      accepted_at = excluded.accepted_at,
      added_via = 'event_invite',
      updated_at = now();

  update public.event_invites
  set status = 'accepted',
      accepted_by_profile_id = v_profile,
      responded_at = now()
  where id = v_invite.id;
end;
$$;

revoke all on function public.accept_event_invite(text) from public, anon;
grant execute on function public.accept_event_invite(text) to authenticated;
alter function public.accept_event_invite(text) owner to postgres;
