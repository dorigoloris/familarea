-- FamilArea: il badge Contatti considera solo inviti ancora ricevibili
-- sull'indirizzo email attuale del Contatto.

begin;

create or replace function public.get_my_contacts()
returns table(
  id uuid,
  first_name text,
  last_name text,
  birth_date date,
  created_at timestamptz,
  updated_at timestamptz,
  pending_invites_count bigint,
  primary_email text,
  primary_phone text,
  show_birthday_in_calendar boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_profile_id uuid;
begin
  select p.id
  into v_owner_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_owner_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  return query
  select
    c.id,
    c.first_name,
    c.last_name,
    c.birth_date,
    c.created_at,
    c.updated_at,
    (
      select count(ai.id)::bigint
      from public.area_invites ai
      where ai.source_contact_id = c.id
        and ai.created_by_profile_id = v_owner_profile_id
        and ai.status = 'pending'
        and ai.expires_at > now()
        and exists (
          select 1
          from public.contact_methods cm
          where cm.contact_id = c.id
            and cm.type = 'email'
            and lower(btrim(cm.value)) = lower(btrim(ai.recipient_email))
        )
    ) as pending_invites_count,
    (
      select cm.value
      from public.contact_methods cm
      where cm.contact_id = c.id
        and cm.type = 'email'
      order by cm.is_primary desc, cm.created_at, cm.id
      limit 1
    ) as primary_email,
    (
      select cm.value
      from public.contact_methods cm
      where cm.contact_id = c.id
        and cm.type = 'phone'
      order by cm.is_primary desc, cm.created_at, cm.id
      limit 1
    ) as primary_phone,
    c.show_birthday_in_calendar
  from public.contacts c
  where c.owner_profile_id = v_owner_profile_id
  order by lower(c.first_name), lower(coalesce(c.last_name, '')), c.id;
end;
$$;

revoke all on function public.get_my_contacts() from public;
grant execute on function public.get_my_contacts() to authenticated;

commit;
