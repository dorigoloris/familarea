-- FamilArea — disambiguate get_my_event_invites output-column references.

create or replace function public.get_my_event_invites()
returns table(
  invite_id uuid,
  status text,
  created_at timestamptz,
  expires_at timestamptz,
  event_id uuid,
  event_title text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_all_day boolean,
  event_status text,
  area_name text,
  organizer_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient record;
begin
  select * into v_recipient from public.contact_share_recipient_identity();

  update public.event_invites as ei
  set status = 'expired'
  where ei.recipient_email = v_recipient.email
    and ei.status = 'pending'
    and ei.expires_at <= now();

  return query
  select
    ei.id,
    ei.status,
    ei.created_at,
    ei.expires_at,
    e.id,
    e.title,
    e.starts_at,
    e.ends_at,
    e.is_all_day,
    e.status,
    a.name,
    coalesce(
      o.name,
      nullif(btrim(concat_ws(' ', inviter.first_name, inviter.last_name)), ''),
      'Organizzatore FamilArea'
    )
  from public.event_invites as ei
  join public.events as e on e.id = ei.event_id
  left join public.areas as a on a.id = e.area_id
  left join public.organizations as o on o.account_id = ei.owner_account_id
  left join public.profiles as inviter on inviter.account_id = ei.invited_by_account_id
  where ei.recipient_email = v_recipient.email
    and ei.status = 'pending'
    and ei.expires_at > now()
  order by ei.created_at desc, ei.id;
end;
$$;

revoke all on function public.get_my_event_invites() from public, anon;
grant execute on function public.get_my_event_invites() to authenticated;
alter function public.get_my_event_invites() owner to postgres;
