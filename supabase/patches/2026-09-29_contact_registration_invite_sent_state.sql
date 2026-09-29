-- FamilArea — Stato persistente dell'invito email di registrazione per Contact.

begin;

alter table public.contacts
  add column if not exists registration_invited_at timestamptz null;

create or replace function public.get_my_contact_invitation_delivery(p_contact_id uuid)
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
    and c.registration_invited_at is null
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

create or replace function public.mark_contact_registration_invite_sent(p_contact_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'permission denied';
  end if;

  update public.contacts c
  set registration_invited_at = now()
  where c.id = p_contact_id
    and c.registration_invited_at is null
    and exists (
      select 1
      from public.contact_methods cm
      where cm.contact_id = c.id
        and cm.method_type = 'email'
        and public.normalize_contact_email(cm.value) is not null
    );

  if not found then
    raise exception 'contact invitation unavailable';
  end if;
end;
$$;

revoke all on function public.mark_contact_registration_invite_sent(uuid)
  from public, anon, authenticated;
grant execute on function public.mark_contact_registration_invite_sent(uuid)
  to service_role;
alter function public.mark_contact_registration_invite_sent(uuid) owner to postgres;

commit;
