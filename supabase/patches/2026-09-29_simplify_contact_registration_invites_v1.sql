-- FamilArea — V1 semplice: invito email a registrarsi, senza onboarding token.
-- Questa patch forward rimuove esclusivamente il sistema applicato e mai usato.

begin;

do $$
begin
  if exists (select 1 from public.contact_registration_invites) then
    raise exception 'cannot simplify contact registration invites while rows exist';
  end if;

  if exists (
    select 1
    from public.contact_profile_links
    where linked_via = 'contact_registration_invite'
  ) then
    raise exception 'cannot simplify contact registration invites while links exist';
  end if;
end;
$$;

drop function public.revoke_contact_registration_invite(uuid);
drop function public.consume_contact_registration_invite(text);
drop function public.get_contact_registration_invite_context(text);
drop function public.create_contact_registration_invite(uuid, text);
drop function public.contact_registration_invite_requires_verified_email();
drop function public.hash_contact_registration_invite_token(text);
drop table public.contact_registration_invites;

alter table public.contact_profile_links
  drop constraint contact_profile_links_linked_via_check;

alter table public.contact_profile_links
  add constraint contact_profile_links_linked_via_check
  check (linked_via in (
    'event_invite',
    'verified',
    'contact_share',
    'family_invite',
    'contact_suggestion'
  ));

create function public.get_my_contact_invitation_delivery(p_contact_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account_id uuid := public.require_personal_account();
  v_recipient_email text;
  v_sender_name text;
begin
  select public.normalize_contact_email(cm.value)
  into v_recipient_email
  from public.contacts c
  join public.contact_methods cm
    on cm.contact_id = c.id
   and cm.method_type = 'email'
  where c.id = p_contact_id
    and c.owner_account_id = v_account_id
  order by cm.is_primary desc, cm.id
  limit 1;

  if v_recipient_email is null then
    raise exception 'contact invitation unavailable';
  end if;

  select nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), '')
  into v_sender_name
  from public.profiles p
  where p.account_id = v_account_id;

  if v_sender_name is null then
    raise exception 'contact invitation unavailable';
  end if;

  return jsonb_build_object(
    'recipient_email', v_recipient_email,
    'sender_name', v_sender_name
  );
end;
$$;

revoke all on function public.get_my_contact_invitation_delivery(uuid)
  from public, anon;
grant execute on function public.get_my_contact_invitation_delivery(uuid)
  to authenticated;
alter function public.get_my_contact_invitation_delivery(uuid) owner to postgres;

commit;
