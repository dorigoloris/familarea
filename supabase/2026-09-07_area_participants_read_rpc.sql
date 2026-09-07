-- FamilArea — elenco sicuro dei partecipanti Area con origine privata non esposta.
-- Migration incrementale: non eseguire automaticamente dal client.

begin;

create function public.get_area_participants(p_area_id uuid)
returns table(
  profile_id uuid,
  first_name text,
  last_name text,
  birth_date date,
  role text,
  is_personal_contact_participant boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_profile_id uuid;
begin
  select p.id into v_caller_profile_id
  from public.profiles p
  where p.user_id = auth.uid();

  if v_caller_profile_id is null then
    raise exception 'Profilo non trovato per l''utente corrente';
  end if;

  if not exists (
    select 1
    from public.area_memberships am
    where am.area_id = p_area_id
      and am.profile_id = v_caller_profile_id
      and am.role in ('admin', 'member')
  ) then
    raise exception 'permission denied: partecipante non autorizzato per questa Area';
  end if;

  return query
  select
    am.profile_id,
    p.first_name,
    p.last_name,
    p.birth_date,
    am.role,
    exists (
      select 1
      from public.contact_participant_profiles cpp
      where cpp.profile_id = am.profile_id
    )
  from public.area_memberships am
  join public.profiles p on p.id = am.profile_id
  where am.area_id = p_area_id
  order by lower(p.first_name), lower(coalesce(p.last_name, '')), am.profile_id;
end;
$$;

revoke all on function public.get_area_participants(uuid) from public;
grant execute on function public.get_area_participants(uuid) to authenticated;

commit;
