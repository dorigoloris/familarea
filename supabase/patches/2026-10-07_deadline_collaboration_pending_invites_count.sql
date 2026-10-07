-- FamilArea — include pending deadline collaborations in the shared invite count.
-- The count remains recipient-scoped and only active pending invitations qualify.

begin;

create or replace function public.get_my_pending_invites_count()
returns integer
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare
  v_recipient record;
  v_account_id uuid := public.require_current_account();
begin
  select * into v_recipient from public.contact_share_recipient_identity();

  return (
    (select count(*)
     from public.area_invites i
     join public.areas a on a.id = i.area_id
     join auth.users u on u.id = auth.uid()
     where lower(i.invitee_email) = lower(coalesce(u.email, ''))
       and i.status = 'pending'
       and (i.expires_at is null or i.expires_at > now()))
    +
    (select count(*)
     from public.family_invites fi
     join public.families f on f.id = fi.family_id
     join public.family_members fm on fm.id = fi.family_member_id
       and fm.family_id = fi.family_id
     where fi.recipient_email = v_recipient.email
       and fi.status = 'pending'
       and (fi.expires_at is null or fi.expires_at > now()))
    +
    (select count(*)
     from public.event_invites ei
     join public.events e on e.id = ei.event_id
     where ei.recipient_email = v_recipient.email
       and ei.status = 'pending'
       and ei.expires_at > now())
    +
    (select count(*)
     from public.contact_suggestions cs
     join public.profiles suggested_profile on suggested_profile.id = cs.suggested_profile_id
     where cs.recipient_email = v_recipient.email
       and cs.status = 'pending'
       and cs.expires_at > now())
    +
    (select count(*)
     from public.list_invites li
     join public.lists l on l.id = li.list_id
     where li.recipient_account_id = v_account_id
       and li.status = 'pending'
       and l.owner_account_id is not null
       and l.area_id is null)
    +
    (select count(*)
     from public.deadline_collaborations dc
     where dc.recipient_account_id = v_account_id
       and dc.status = 'pending')
  )::integer;
end
$$;

revoke all on function public.get_my_pending_invites_count() from public, anon;
grant execute on function public.get_my_pending_invites_count() to authenticated;

commit;
