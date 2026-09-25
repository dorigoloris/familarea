-- FamilArea — cancellazione sicura di un Contact privato.
-- I recapiti e i collegamenti Contact/Profile sono dati della rubrica e
-- vengono eliminati dalle FK cascade. Le relazioni funzionali o storiche
-- devono invece essere rimosse esplicitamente prima della cancellazione.

create or replace function public.delete_contact(p_contact_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_account_id uuid;
begin
  v_owner_account_id := public.require_current_account();

  perform 1
  from public.contacts c
  where c.id = p_contact_id
    and c.owner_account_id = v_owner_account_id
  for update;

  if not found then
    raise exception 'contact not found or unavailable';
  end if;

  if exists (
    select 1 from public.event_participants ep where ep.contact_id = p_contact_id
  ) then
    raise exception 'contact has event participant history';
  end if;

  if exists (
    select 1 from public.event_invites ei where ei.contact_id = p_contact_id
  ) then
    raise exception 'contact has event invite history';
  end if;

  if exists (
    select 1 from public.family_members fm where fm.contact_id = p_contact_id
  ) then
    raise exception 'contact is linked to a family member';
  end if;

  delete from public.contacts
  where id = p_contact_id
    and owner_account_id = v_owner_account_id;
end;
$$;

revoke all on function public.delete_contact(uuid) from public, anon;
grant execute on function public.delete_contact(uuid) to authenticated;
alter function public.delete_contact(uuid) owner to postgres;
