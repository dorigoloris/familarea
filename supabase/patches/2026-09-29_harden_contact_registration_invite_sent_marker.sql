-- FamilArea — Hardening del marcatore server-side dell'invito Contact.

begin;

create or replace function public.mark_contact_registration_invite_sent(p_contact_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
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
